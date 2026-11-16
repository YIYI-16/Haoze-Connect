use crate::api::account_network::{AccountHttpResponse, AccountNetworkOptions};
use hickory_proto::op::{Message, MessageType, Query, ResponseCode};
use hickory_proto::rr::rdata::svcb::SvcParamValue;
use hickory_proto::rr::{Name, RData, RecordType};
use reqwest::blocking::{Client, ClientBuilder, Response};
use reqwest::{Method, Proxy, Url};
use rustls::client::EchConfig;
use rustls::pki_types::EchConfigListBytes;
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const DNS_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_BODY: u64 = 8 * 1024 * 1024;

struct DohProvider {
    host: &'static str,
    ip: &'static str,
}

fn provider(name: &str) -> Result<DohProvider, String> {
    let (host, ip) = match name {
        "alibaba" => ("dns.alidns.com", "223.5.5.5"),
        "cloudflare" => ("cloudflare-dns.com", "1.1.1.1"),
        "google" => ("dns.google", "8.8.8.8"),
        "tencent" => ("doh.pub", "1.12.12.12"),
        _ => return Err("configuration".into()),
    };
    Ok(DohProvider { host, ip })
}

fn supported_ech(bytes: &[u8]) -> Result<Option<EchConfig>, String> {
    match EchConfig::new(
        EchConfigListBytes::from(bytes),
        rustls::crypto::aws_lc_rs::hpke::ALL_SUPPORTED_SUITES,
    ) {
        Ok(config) => Ok(Some(config)),
        Err(rustls::Error::InvalidEncryptedClientHello(
            rustls::EncryptedClientHelloError::NoCompatibleConfig,
        )) => Ok(None),
        Err(_) => Err("ech".into()),
    }
}

fn tls_config(ech: Option<EchConfig>) -> Result<rustls::ClientConfig, String> {
    let crypto = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let builder = rustls::ClientConfig::builder_with_provider(crypto);
    let builder = if let Some(ech) = ech {
        builder.with_ech(ech.into()).map_err(|_| "ech")?
    } else {
        builder
            .with_safe_default_protocol_versions()
            .map_err(|_| "tls")?
    };
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let mut config = builder.with_root_certificates(roots).with_no_client_auth();
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(config)
}

fn client_builder(
    options: &AccountNetworkOptions,
    timeout: Duration,
) -> Result<ClientBuilder, String> {
    let mut builder = Client::builder()
        .https_only(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(timeout)
        .connect_timeout(timeout.min(DNS_TIMEOUT))
        .tls_backend_preconfigured(tls_config(None)?);
    if let Some(raw) = &options.proxy_url {
        let url = Url::parse(raw).map_err(|_| "configuration")?;
        if !matches!(url.scheme(), "http" | "socks5h")
            || url.host_str().is_none()
            || url.port_or_known_default().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.path() != "/" && !url.path().is_empty()
        {
            return Err("configuration".into());
        }
        let mut proxy = Proxy::all(url).map_err(|_| "configuration")?;
        if !options.proxy_username.is_empty() || !options.proxy_password.is_empty() {
            proxy = proxy.basic_auth(&options.proxy_username, &options.proxy_password);
        }
        builder = builder.proxy(proxy);
    }
    Ok(builder)
}

fn read_limited(response: Response, limit: u64) -> Result<Vec<u8>, String> {
    if response
        .content_length()
        .is_some_and(|length| length > limit)
    {
        return Err("protocol".into());
    }
    let mut bytes = Vec::new();
    response
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "socket")?;
    if bytes.len() as u64 > limit {
        return Err("protocol".into());
    }
    Ok(bytes)
}

fn network_error(error: reqwest::Error) -> String {
    use std::error::Error;
    let mut source = error.source();
    while let Some(cause) = source {
        if let Some(tls) = cause.downcast_ref::<rustls::Error>() {
            return match tls {
                rustls::Error::InvalidCertificate(_) | rustls::Error::NoCertificatesPresented => {
                    "certificate"
                }
                _ => "tls",
            }
            .into();
        }
        source = cause.source();
    }
    if error.is_timeout() {
        "timeout"
    } else if error.is_connect() {
        "socket"
    } else {
        "tls"
    }
    .into()
}

fn remaining(deadline: Instant) -> Result<Duration, String> {
    deadline
        .checked_duration_since(Instant::now())
        .ok_or("timeout".into())
}

enum DnsTransport {
    Doh {
        client: Client,
        endpoint: String,
    },
    System {
        options: AccountNetworkOptions,
        servers: Vec<SocketAddr>,
    },
}

struct Resolver {
    transport: DnsTransport,
    deadline: Instant,
}

impl Resolver {
    fn new(options: &AccountNetworkOptions, deadline: Instant) -> Result<Self, String> {
        if !options.doh_enabled {
            let servers = if options.proxy_url.is_some() {
                let ip = if options.doh_provider == "tencent" {
                    "119.29.29.29"
                } else {
                    provider(&options.doh_provider)?.ip
                };
                vec![SocketAddr::new(
                    ip.parse().map_err(|_| "configuration")?,
                    53,
                )]
            } else {
                crate::account_dns::system_servers(options)?
            };
            return Ok(Self {
                transport: DnsTransport::System {
                    options: options.clone(),
                    servers,
                },
                deadline,
            });
        }
        let provider = provider(&options.doh_provider)?;
        let address = SocketAddr::new(provider.ip.parse().map_err(|_| "configuration")?, 443);
        let client = client_builder(options, remaining(deadline)?.min(DNS_TIMEOUT))?
            .resolve(provider.host, address)
            .build()
            .map_err(network_error)?;
        Ok(Self {
            transport: DnsTransport::Doh {
                client,
                endpoint: format!("https://{}/dns-query", provider.host),
            },
            deadline,
        })
    }

    fn query(&self, host: &str, kind: RecordType) -> Result<Message, String> {
        let name = dns_name(host)?;
        let mut query = Message::query();
        query.metadata.recursion_desired = true;
        query.queries.push(Query::query(name, kind));
        let wire = query.to_vec().map_err(|_| "dns")?;
        let bytes = match &self.transport {
            DnsTransport::Doh { client, endpoint } => {
                let response = client
                    .post(endpoint)
                    .header("Content-Type", "application/dns-message")
                    .header("Accept", "application/dns-message")
                    .timeout(remaining(self.deadline)?.min(DNS_TIMEOUT))
                    .body(wire)
                    .send()
                    .map_err(network_error)?;
                if !response.status().is_success() {
                    return Err("dns".into());
                }
                read_limited(response, 65535)?
            }
            DnsTransport::System { options, servers } => crate::account_dns::query(
                options,
                servers,
                &wire,
                self.deadline.min(Instant::now() + DNS_TIMEOUT),
            )?,
        };
        let message = Message::from_vec(&bytes).map_err(|_| "dns")?;
        validate_response(&query, &message)?;
        Ok(message)
    }

    fn addresses(&self, host: &str) -> Result<Vec<SocketAddr>, String> {
        let mut addresses = Vec::new();
        for kind in [RecordType::A, RecordType::AAAA] {
            let mut current = dns_name(host)?;
            let mut visited = HashSet::new();
            for _ in 0..8 {
                if !visited.insert(current.clone()) {
                    return Err("dns".into());
                }
                let message = self.query(&current.to_ascii(), kind)?;
                let canonical = canonical_name(&message, &current)?;
                for record in &message.answers {
                    if record.name != canonical {
                        continue;
                    }
                    let ip = match &record.data {
                        RData::A(ip) if kind == RecordType::A => IpAddr::V4(ip.0),
                        RData::AAAA(ip) if kind == RecordType::AAAA => IpAddr::V6(ip.0),
                        _ => continue,
                    };
                    let address = SocketAddr::new(ip, 443);
                    if !addresses.contains(&address) {
                        addresses.push(address);
                    }
                }
                if canonical == current
                    || message
                        .answers
                        .iter()
                        .any(|record| record.name == canonical && record.data.record_type() == kind)
                {
                    break;
                }
                current = canonical;
            }
        }
        if addresses.is_empty() {
            return Err("dns".into());
        }
        Ok(addresses)
    }

    fn ech(&self, host: &str) -> Result<Option<EchConfig>, String> {
        let mut current = dns_name(host)?;
        let mut visited = HashSet::new();
        for _ in 0..8 {
            if !visited.insert(current.clone()) {
                return Err("dns".into());
            }
            let message = self.query(&current.to_ascii(), RecordType::HTTPS)?;
            let canonical = canonical_name(&message, &current)?;
            let mut alias = if canonical != current {
                Some(canonical.clone())
            } else {
                None
            };
            let mut services = Vec::new();
            for record in message.answers {
                if record.name != canonical {
                    continue;
                }
                match record.data {
                    RData::HTTPS(https) => {
                        if https.svc_priority == 0 {
                            alias = Some(https.target_name.clone());
                        } else {
                            services.push(https);
                        }
                    }
                    _ => {}
                }
            }
            services.sort_by_key(|record| record.svc_priority);
            for record in services {
                for (_, value) in &record.svc_params {
                    if let SvcParamValue::EchConfigList(config) = value {
                        if let Some(config) = supported_ech(&config.0)? {
                            return Ok(Some(config));
                        }
                    }
                }
            }
            match alias {
                Some(name) if name != current => current = name,
                _ => return Ok(None),
            }
        }
        Err("dns".into())
    }
}

fn canonical_name(message: &Message, host: &Name) -> Result<Name, String> {
    let mut current = host.clone();
    let mut visited = HashSet::new();
    for _ in 0..8 {
        if !visited.insert(current.clone()) {
            return Err("dns".into());
        }
        let alias = message
            .answers
            .iter()
            .find_map(|record| match &record.data {
                RData::CNAME(cname) if record.name == current => Some(cname.0.clone()),
                _ => None,
            });
        match alias {
            Some(name) => current = name,
            None => return Ok(current),
        }
    }
    Err("dns".into())
}

fn dns_name(host: &str) -> Result<Name, String> {
    let mut name = Name::from_ascii(host).map_err(|_| "dns")?;
    name.set_fqdn(true);
    Ok(name)
}

fn validate_response(query: &Message, response: &Message) -> Result<(), String> {
    if response.metadata.id != query.metadata.id
        || response.metadata.message_type != MessageType::Response
        || response.metadata.op_code != query.metadata.op_code
        || response.metadata.response_code != ResponseCode::NoError
        || response.metadata.truncation
        || response.queries != query.queries
    {
        return Err("dns".into());
    }
    Ok(())
}

pub(crate) fn request(
    options: AccountNetworkOptions,
    method: &str,
    target: &str,
    headers: HashMap<String, String>,
    body: Vec<u8>,
) -> Result<AccountHttpResponse, String> {
    let url = Url::parse(target).map_err(|_| "configuration")?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.host_str().is_none()
        || body.len() as u64 > MAX_BODY
    {
        return Err("configuration".into());
    }
    let method = Method::from_bytes(method.as_bytes()).map_err(|_| "configuration")?;
    if !matches!(
        method,
        Method::GET | Method::POST | Method::PUT | Method::DELETE | Method::PATCH
    ) {
        return Err("configuration".into());
    }
    let host = url.host_str().ok_or("configuration")?;
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut builder = client_builder(&options, REQUEST_TIMEOUT)?;
    let mut ech = None;
    if host.trim_matches(['[', ']']).parse::<IpAddr>().is_err() {
        let resolver = if options.doh_enabled || options.ech_enabled {
            Some(Resolver::new(&options, deadline)?)
        } else {
            None
        };
        if options.ech_enabled {
            ech = resolver.as_ref().ok_or("dns")?.ech(host)?;
        }
        // CONNECT and socks5h receive the original host, including its DNS lookup.
        if options.proxy_url.is_none() && options.doh_enabled {
            builder =
                builder.resolve_to_addrs(host, &resolver.as_ref().ok_or("dns")?.addresses(host)?);
        }
    }
    let ech_used = ech.is_some();
    builder = builder
        .tls_backend_preconfigured(tls_config(ech)?)
        .timeout(remaining(deadline)?);
    let client = builder.build().map_err(network_error)?;
    let mut request = client.request(method, url);
    for (name, value) in headers {
        if matches!(
            name.to_ascii_lowercase().as_str(),
            "host" | "proxy-authorization" | "connection"
        ) {
            return Err("configuration".into());
        }
        request = request.header(name, value);
    }
    if !body.is_empty() {
        request = request.body(body);
    }
    let response = request.send().map_err(network_error)?;
    let status = response.status().as_u16();
    if (300..400).contains(&status) {
        return Err("redirect".into());
    }
    Ok(AccountHttpResponse {
        status,
        body: read_limited(response, MAX_BODY)?,
        ech_used,
    })
}

pub(crate) fn latency(mut options: AccountNetworkOptions) -> Result<u32, String> {
    let started = Instant::now();
    options.doh_enabled = true;
    let resolver = Resolver::new(&options, started + DNS_TIMEOUT)?;
    let message = resolver.query("www.haoze.cyou", RecordType::A)?;
    if !message
        .answers
        .iter()
        .any(|record| matches!(record.data, RData::A(_)))
    {
        return Err("dns".into());
    }
    Ok(started.elapsed().as_millis().min(u32::MAX as u128) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    fn options(proxy_url: Option<String>) -> AccountNetworkOptions {
        AccountNetworkOptions {
            doh_provider: "alibaba".into(),
            doh_enabled: true,
            system_dns_servers: Vec::new(),
            ech_enabled: false,
            proxy_url,
            proxy_username: "test-user".into(),
            proxy_password: "test-password".into(),
        }
    }

    fn read_bytes(socket: &mut impl Read, count: usize) -> Vec<u8> {
        let mut bytes = vec![0; count];
        socket.read_exact(&mut bytes).unwrap();
        bytes
    }

    #[test]
    fn http_proxy_receives_destination_domain_and_authentication() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut bytes = Vec::new();
            while !bytes.ends_with(b"\r\n\r\n") {
                bytes.extend(read_bytes(&mut socket, 1));
                assert!(bytes.len() < 4096);
            }
            socket
                .write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                .unwrap();
            String::from_utf8(bytes).unwrap()
        });
        assert!(request(
            options(Some(format!("http://{address}"))),
            "GET",
            "https://remote-dns-only.invalid/test",
            HashMap::new(),
            vec![]
        )
        .is_err());
        let connect = server.join().unwrap();
        assert!(connect.starts_with("CONNECT remote-dns-only.invalid:443 HTTP/1.1\r\n"));
        assert!(connect
            .to_ascii_lowercase()
            .contains("proxy-authorization: basic "));
    }

    #[test]
    fn socks_proxy_receives_destination_domain_with_credentials() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let greeting = read_bytes(&mut socket, 2);
            assert_eq!(greeting[0], 5);
            assert!(read_bytes(&mut socket, greeting[1] as usize).contains(&2));
            socket.write_all(&[5, 2]).unwrap();
            let auth = read_bytes(&mut socket, 2);
            assert_eq!(auth[0], 1);
            assert_eq!(read_bytes(&mut socket, auth[1] as usize), b"test-user");
            let length = read_bytes(&mut socket, 1)[0] as usize;
            assert_eq!(read_bytes(&mut socket, length), b"test-password");
            socket.write_all(&[1, 0]).unwrap();
            let header = read_bytes(&mut socket, 5);
            assert_eq!(&header[..4], &[5, 1, 0, 3]);
            let destination = read_bytes(&mut socket, header[4] as usize);
            assert_eq!(read_bytes(&mut socket, 2), [1, 187]);
            socket.write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
            destination
        });
        assert!(request(
            options(Some(format!("socks5h://{address}"))),
            "GET",
            "https://remote-dns-only.invalid/test",
            HashMap::new(),
            vec![]
        )
        .is_err());
        assert_eq!(server.join().unwrap(), b"remote-dns-only.invalid");
    }

    #[test]
    fn refuses_insecure_targets_proxy_schemes_and_invalid_ech() {
        assert!(request(
            options(None),
            "GET",
            "http://example.com",
            HashMap::new(),
            vec![]
        )
        .is_err());
        assert!(request(
            options(None),
            "GET",
            "https://user:secret@example.com",
            HashMap::new(),
            vec![]
        )
        .is_err());
        assert!(client_builder(
            &options(Some("socks5://127.0.0.1:1080".into())),
            DNS_TIMEOUT
        )
        .is_err());
        assert!(supported_ech(&[0]).is_err());
        assert!(supported_ech(&[0, 0]).unwrap().is_none());
        assert!(supported_ech(&[0, 4, 0xff, 0xff, 0, 0]).unwrap().is_none());
        assert!(provider("unknown").is_err());
        assert!(client_builder(&options(Some("http://127.0.0.1:80".into())), DNS_TIMEOUT).is_ok());
    }

    #[test]
    fn validates_dns_question_id_status_and_truncation() {
        let mut query = Message::query();
        query.queries.push(Query::query(
            dns_name("www.haoze.cyou").unwrap(),
            RecordType::HTTPS,
        ));
        let mut response = Message::from_vec(&query.to_vec().unwrap()).unwrap();
        response.metadata.message_type = MessageType::Response;
        assert!(validate_response(&query, &response).is_ok());
        response.metadata.id ^= 1;
        assert!(validate_response(&query, &response).is_err());
        response.metadata.id = query.metadata.id;
        response.metadata.truncation = true;
        assert!(validate_response(&query, &response).is_err());
        response.metadata.truncation = false;
        response.queries.clear();
        assert!(validate_response(&query, &response).is_err());
        response.queries = query.queries.clone();
        response.metadata.response_code = ResponseCode::NXDomain;
        assert!(validate_response(&query, &response).is_err());
    }

    #[test]
    fn ech_without_doh_queries_the_system_dns_server_for_https_records() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let server = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut socket = loop {
                if let Ok((socket, _)) = listener.accept() {
                    break socket;
                }
                assert!(Instant::now() < deadline);
                thread::sleep(Duration::from_millis(5));
            };
            socket.set_nonblocking(false).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let bytes = read_bytes(&mut socket, 2);
            let bytes = read_bytes(
                &mut socket,
                u16::from_be_bytes([bytes[0], bytes[1]]) as usize,
            );
            let mut message = Message::from_vec(&bytes).unwrap();
            assert_eq!(message.queries[0].query_type, RecordType::HTTPS);
            assert_eq!(message.queries[0].name, dns_name("alt.haoze.cyou").unwrap());
            message.metadata.message_type = MessageType::Response;
            let bytes = message.to_vec().unwrap();
            socket
                .write_all(&(bytes.len() as u16).to_be_bytes())
                .unwrap();
            socket.write_all(&bytes).unwrap();
        });
        let mut config = options(None);
        config.doh_enabled = false;
        config.ech_enabled = true;
        config.doh_provider = "no-doh-provider-may-be-used".into();
        config.system_dns_servers = vec![address.to_string()];
        let resolver = Resolver::new(&config, Instant::now() + Duration::from_secs(5)).unwrap();
        assert!(resolver.ech("alt.haoze.cyou").unwrap().is_none());
        server.join().unwrap();
    }

    #[test]
    #[ignore = "requires public DNS/HTTPS connectivity"]
    fn live_doh_and_opportunistic_ech() {
        let mut config = options(None);
        config.ech_enabled = true;
        latency(config.clone()).unwrap();
        let response = request(
            config.clone(),
            "GET",
            "https://www.haoze.cyou/",
            HashMap::new(),
            vec![],
        )
        .unwrap();
        assert_eq!(response.status, 200);
        let response = request(
            config,
            "GET",
            "https://sso.zhouhaoze.com/cdn-cgi/trace",
            HashMap::new(),
            vec![],
        )
        .unwrap();
        assert_eq!(response.status, 200);
        assert!(response.ech_used);
        assert!(String::from_utf8(response.body)
            .unwrap()
            .lines()
            .any(|line| line == "sni=encrypted"));
    }
}
