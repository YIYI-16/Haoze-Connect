use std::collections::HashMap;

#[derive(Clone)]
pub struct AccountNetworkOptions {
    pub doh_provider: String,
    pub ech_enabled: bool,
    pub proxy_url: Option<String>,
    pub proxy_username: String,
    pub proxy_password: String,
}

pub struct AccountHttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
    pub ech_used: bool,
}

pub fn account_http_request(
    options: AccountNetworkOptions,
    method: String,
    url: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
) -> Result<AccountHttpResponse, String> {
    crate::account_network::request(options, &method, &url, headers, body)
}

pub fn account_doh_latency(options: AccountNetworkOptions) -> Result<u32, String> {
    crate::account_network::latency(options)
}
