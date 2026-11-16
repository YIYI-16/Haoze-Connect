use crate::api::account_network::AccountNetworkOptions;
use base64::Engine;
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

pub(crate) fn system_servers(options: &AccountNetworkOptions) -> Result<Vec<SocketAddr>, String> {
    if !options.system_dns_servers.is_empty() {
        return options
            .system_dns_servers
            .iter()
            .map(|value| {
                value
                    .parse::<IpAddr>()
                    .map(|ip| SocketAddr::new(ip, 53))
                    .or_else(|_| value.parse::<SocketAddr>())
                    .map_err(|_| "dns".into())
            })
            .collect();
    }
    #[cfg(windows)]
    let servers: Vec<SocketAddr> = ipconfig::get_adapters()
        .map_err(|_| "dns")?
        .into_iter()
        .filter(|adapter| adapter.oper_status() == ipconfig::OperStatus::IfOperStatusUp)
        .flat_map(|adapter| {
            adapter
                .dns_servers()
                .iter()
                .map(|ip| match ip {
                    IpAddr::V6(ip) if ip.is_unicast_link_local() => SocketAddr::V6(
                        std::net::SocketAddrV6::new(*ip, 53, 0, adapter.ipv6_if_index()),
                    ),
                    ip => SocketAddr::new(*ip, 53),
                })
                .collect::<Vec<_>>()
        })
        .collect();
    #[cfg(all(unix, not(target_os = "android")))]
    let servers: Vec<SocketAddr> = std::fs::read_to_string("/etc/resolv.conf")
        .map_err(|_| "dns")?
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            if parts.next()? != "nameserver" {
                return None;
            }
            parts
                .next()?
                .parse::<IpAddr>()
                .ok()
                .map(|ip| SocketAddr::new(ip, 53))
        })
        .collect();
    #[cfg(not(any(windows, all(unix, not(target_os = "android")))))]
    let servers: Vec<SocketAddr> = Vec::new();
    if servers.is_empty() {
        Err("dns".into())
    } else {
        Ok(servers)
    }
}

fn budget(deadline: Instant) -> Result<Duration, String> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|value| !value.is_zero())
        .ok_or("timeout".into())
}

fn connect(address: SocketAddr, deadline: Instant) -> Result<TcpStream, String> {
    let stream = TcpStream::connect_timeout(&address, budget(deadline)?).map_err(|_| "socket")?;
    stream
        .set_read_timeout(Some(budget(deadline)?))
        .map_err(|_| "socket")?;
    stream
        .set_write_timeout(Some(budget(deadline)?))
        .map_err(|_| "socket")?;
    Ok(stream)
}

fn proxy_stream(
    options: &AccountNetworkOptions,
    target: SocketAddr,
    deadline: Instant,
) -> Result<TcpStream, String> {
    let proxy = reqwest::Url::parse(options.proxy_url.as_ref().ok_or("configuration")?)
        .map_err(|_| "configuration")?;
    let host = proxy
        .host_str()
        .ok_or("configuration")?
        .trim_matches(['[', ']'])
        .to_owned();
    let port = proxy.port_or_known_default().ok_or("configuration")?;
    let addresses = if let Ok(ip) = host.parse::<IpAddr>() {
        vec![SocketAddr::new(ip, port)]
    } else {
        let (send, receive) = std::sync::mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let _ = send.send(
                (host.as_str(), port)
                    .to_socket_addrs()
                    .map(|items| items.collect::<Vec<_>>()),
            );
        });
        receive
            .recv_timeout(budget(deadline)?)
            .map_err(|_| "timeout")?
            .map_err(|_| "socket")?
    };
    let mut stream = addresses
        .into_iter()
        .find_map(|address| connect(address, deadline).ok())
        .ok_or("socket")?;
    match proxy.scheme() {
        "http" => {
            let authentication =
                if options.proxy_username.is_empty() && options.proxy_password.is_empty() {
                    String::new()
                } else {
                    let encoded = base64::engine::general_purpose::STANDARD.encode(format!(
                        "{}:{}",
                        options.proxy_username, options.proxy_password
                    ));
                    format!("Proxy-Authorization: Basic {encoded}\r\n")
                };
            stream
                .write_all(
                    format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n{authentication}\r\n")
                        .as_bytes(),
                )
                .map_err(|_| "socket")?;
            let mut header = Vec::new();
            while !header.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).map_err(|_| "socket")?;
                header.push(byte[0]);
                if header.len() > 8192 || Instant::now() >= deadline {
                    return Err("protocol".into());
                }
            }
            let line = std::str::from_utf8(&header)
                .map_err(|_| "protocol")?
                .lines()
                .next()
                .ok_or("protocol")?;
            let mut parts = line.split_whitespace();
            if !matches!(parts.next(), Some("HTTP/1.0" | "HTTP/1.1")) || parts.next() != Some("200")
            {
                return Err("socket".into());
            }
        }
        "socks5h" => {
            let auth = !options.proxy_username.is_empty() || !options.proxy_password.is_empty();
            stream
                .write_all(&[5, 1, if auth { 2 } else { 0 }])
                .map_err(|_| "socket")?;
            let mut reply = [0; 2];
            stream.read_exact(&mut reply).map_err(|_| "socket")?;
            if reply != [5, if auth { 2 } else { 0 }] {
                return Err("socket".into());
            }
            if auth {
                let user = options.proxy_username.as_bytes();
                let password = options.proxy_password.as_bytes();
                if user.len() > 255 || password.len() > 255 {
                    return Err("configuration".into());
                }
                let mut bytes = vec![1, user.len() as u8];
                bytes.extend(user);
                bytes.push(password.len() as u8);
                bytes.extend(password);
                stream.write_all(&bytes).map_err(|_| "socket")?;
                stream.read_exact(&mut reply).map_err(|_| "socket")?;
                if reply != [1, 0] {
                    return Err("socket".into());
                }
            }
            let mut bytes = vec![5, 1, 0];
            match target.ip() {
                IpAddr::V4(ip) => {
                    bytes.push(1);
                    bytes.extend(ip.octets());
                }
                IpAddr::V6(ip) => {
                    bytes.push(4);
                    bytes.extend(ip.octets());
                }
            }
            bytes.extend(target.port().to_be_bytes());
            stream.write_all(&bytes).map_err(|_| "socket")?;
            let mut header = [0; 4];
            stream.read_exact(&mut header).map_err(|_| "socket")?;
            if header[..3] != [5, 0, 0] {
                return Err("socket".into());
            }
            let size = match header[3] {
                1 => 4,
                4 => 16,
                3 => {
                    let mut byte = [0];
                    stream.read_exact(&mut byte).map_err(|_| "socket")?;
                    byte[0] as usize
                }
                _ => return Err("protocol".into()),
            };
            let mut address = vec![0; size + 2];
            stream.read_exact(&mut address).map_err(|_| "socket")?;
        }
        _ => return Err("configuration".into()),
    }
    Ok(stream)
}

pub(crate) fn query(
    options: &AccountNetworkOptions,
    servers: &[SocketAddr],
    bytes: &[u8],
    deadline: Instant,
) -> Result<Vec<u8>, String> {
    for server in servers {
        let result = (|| {
            let mut stream = if options.proxy_url.is_some() {
                proxy_stream(options, *server, deadline)?
            } else {
                connect(*server, deadline)?
            };
            stream
                .set_read_timeout(Some(budget(deadline)?))
                .map_err(|_| "socket")?;
            stream
                .set_write_timeout(Some(budget(deadline)?))
                .map_err(|_| "socket")?;
            stream
                .write_all(&(bytes.len() as u16).to_be_bytes())
                .map_err(|_| "socket")?;
            stream.write_all(bytes).map_err(|_| "socket")?;
            let mut length = [0; 2];
            stream.read_exact(&mut length).map_err(|_| "dns")?;
            let mut response = vec![0; u16::from_be_bytes(length) as usize];
            if response.is_empty() {
                return Err("dns".into());
            }
            stream.read_exact(&mut response).map_err(|_| "dns")?;
            Ok(response)
        })();
        if result.is_ok() {
            return result;
        }
        budget(deadline)?;
    }
    Err("dns".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    fn accept(listener: TcpListener) -> TcpStream {
        listener.set_nonblocking(true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(5)))
                        .unwrap();
                    return stream;
                }
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        && Instant::now() < deadline =>
                {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(error) => panic!("DNS proxy was not contacted: {error}"),
            }
        }
    }

    fn read(stream: &mut TcpStream, size: usize) -> Vec<u8> {
        let mut bytes = vec![0; size];
        stream.read_exact(&mut bytes).unwrap();
        bytes
    }

    #[test]
    fn classic_dns_uses_tcp_directly_and_through_both_authenticated_proxies() {
        for scheme in [None, Some("http"), Some("socks5h")] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let local = listener.local_addr().unwrap();
            let options = AccountNetworkOptions {
                doh_provider: "alibaba".into(),
                doh_enabled: false,
                ech_enabled: true,
                system_dns_servers: vec![local.to_string()],
                proxy_url: scheme.map(|scheme| format!("{scheme}://{local}")),
                proxy_username: "user".into(),
                proxy_password: "secret".into(),
            };
            let server = thread::spawn(move || {
                let mut stream = accept(listener);
                match scheme {
                    Some("http") => {
                        let mut bytes = Vec::new();
                        while !bytes.ends_with(b"\r\n\r\n") {
                            bytes.extend(read(&mut stream, 1));
                            assert!(bytes.len() < 4096);
                        }
                        let header = String::from_utf8(bytes).unwrap();
                        assert!(header.starts_with("CONNECT 223.5.5.5:53 HTTP/1.1\r\n"));
                        assert!(header.contains("Proxy-Authorization: Basic dXNlcjpzZWNyZXQ="));
                        stream
                            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                            .unwrap();
                    }
                    Some("socks5h") => {
                        assert_eq!(read(&mut stream, 3), [5, 1, 2]);
                        stream.write_all(&[5, 2]).unwrap();
                        assert_eq!(read(&mut stream, 2), [1, 4]);
                        assert_eq!(read(&mut stream, 4), b"user");
                        assert_eq!(read(&mut stream, 1), [6]);
                        assert_eq!(read(&mut stream, 6), b"secret");
                        stream.write_all(&[1, 0]).unwrap();
                        assert_eq!(read(&mut stream, 10), [5, 1, 0, 1, 223, 5, 5, 5, 0, 53]);
                        stream.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
                    }
                    _ => {}
                }
                assert_eq!(read(&mut stream, 2), [0, 3]);
                assert_eq!(read(&mut stream, 3), [1, 2, 3]);
                stream.write_all(&[0, 3, 4, 5, 6]).unwrap();
            });
            let target = if scheme.is_some() {
                "223.5.5.5:53".parse().unwrap()
            } else {
                local
            };
            let response = query(
                &options,
                &[target],
                &[1, 2, 3],
                Instant::now() + Duration::from_secs(5),
            )
            .unwrap();
            assert_eq!(response, [4, 5, 6]);
            server.join().unwrap();
        }
    }

    #[test]
    fn retains_ipv6_interface_scope_in_system_dns_addresses() {
        let options = AccountNetworkOptions {
            doh_provider: "alibaba".into(),
            doh_enabled: false,
            ech_enabled: true,
            system_dns_servers: vec!["[fe80::1%3]:53".into()],
            proxy_url: None,
            proxy_username: String::new(),
            proxy_password: String::new(),
        };
        let servers = system_servers(&options).unwrap();
        assert!(matches!(servers[0], SocketAddr::V6(address) if address.scope_id() == 3));
    }

    #[test]
    fn rejects_invalid_dns_server_addresses() {
        let options = AccountNetworkOptions {
            doh_provider: "alibaba".into(),
            doh_enabled: false,
            ech_enabled: true,
            system_dns_servers: vec!["https://dns.invalid".into()],
            proxy_url: None,
            proxy_username: String::new(),
            proxy_password: String::new(),
        };
        assert!(system_servers(&options).is_err());
    }
}
