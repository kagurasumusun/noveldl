use aho_corasick::{AhoCorasick, AhoCorasickBuilder};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::process::Command;
use std::sync::{Arc, OnceLock, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use url::Url;
use wreq::header::{
    ACCEPT, ACCEPT_ENCODING, ACCEPT_LANGUAGE, CACHE_CONTROL, CONTENT_TYPE, COOKIE, DNT, HeaderName,
    PRAGMA, REFERER, UPGRADE_INSECURE_REQUESTS, USER_AGENT,
};
use wreq::{Client, RequestBuilder, StatusCode, tls::CertStore};
use wreq_util::Emulation as BrowserEmulation;

use crate::config_manager::ConfigManager;
use crate::downloader::errors::DownloaderError;

pub struct Downloader {
    client: Client,
    runtime: Option<Arc<tokio::runtime::Runtime>>,
}

#[derive(Debug, Clone)]
struct RequestContext {
    url: String,
    parsed: Url,
    host: String,
    access: Option<Arc<AccessSettings>>,
    profile: RequestProfile,
}

impl RequestContext {
    fn new(url: &str) -> Result<Self> {
        const REQUEST_CONTEXT_CACHE_LIMIT: usize = 512;
        let parsed = Url::parse(url).with_context(|| format!("parse URL {url}"))?;
        let cache_key = request_context_cache_key(&parsed);
        let cache = REQUEST_CONTEXT_CACHE.get_or_init(|| RwLock::new(HashMap::new()));
        if let Ok(guard) = cache.read() {
            if let Some(cached) = guard.get(&cache_key) {
                let mut ctx = cached.clone();
                ctx.url = url.to_string();
                ctx.parsed = parsed;
                return Ok(ctx);
            }
        }

        let ctx = Self::from_parsed(url.to_string(), parsed)?;
        if let Ok(mut guard) = cache.write() {
            prune_cache_to_limit(&mut guard, REQUEST_CONTEXT_CACHE_LIMIT.saturating_sub(1));
            guard.insert(cache_key, ctx.clone());
        }
        Ok(ctx)
    }

    fn from_parsed(url: String, parsed: Url) -> Result<Self> {
        let host = parsed
            .host_str()
            .map(str::to_ascii_lowercase)
            .ok_or_else(|| anyhow::anyhow!("URL has no host: {url}"))?;
        let preset = parser_preset_for_host(&host);
        let access = preset
            .as_ref()
            .map(|preset| Arc::new(AccessSettings::from_preset(preset)));
        let profile = access
            .as_ref()
            .and_then(|access| access.profile)
            .unwrap_or_else(|| profile_for_host(&host));
        Ok(Self {
            url,
            parsed,
            host,
            access,
            profile,
        })
    }
}

fn request_context_cache_key(parsed: &Url) -> String {
    let mut key = parsed.clone();
    key.set_query(None);
    key.set_fragment(None);
    key.into()
}

#[derive(Debug, Clone)]
struct AccessSettings {
    profile: Option<RequestProfile>,
    referer: Option<AccessReferer>,
    headers: Vec<(HeaderName, String)>,
    cookies: Option<String>,
    browser_fallback: bool,
}

#[derive(Debug, Clone)]
enum AccessReferer {
    TocParent,
    Static(String),
}

impl AccessSettings {
    fn from_preset(preset: &serde_yaml::Value) -> Self {
        let access = preset.get("access");
        let profile = access
            .and_then(|v| v.get("profile"))
            .and_then(|v| v.as_str())
            .map(request_profile_from_name);
        let referer = access
            .and_then(|v| v.get("referer"))
            .and_then(|v| v.as_str())
            .map(|value| {
                if value == "toc_parent" {
                    AccessReferer::TocParent
                } else {
                    AccessReferer::Static(value.to_string())
                }
            });
        let headers = access
            .and_then(|v| v.get("headers"))
            .and_then(|v| v.as_mapping())
            .map(|headers| {
                headers
                    .iter()
                    .filter_map(|(name, value)| {
                        let (Some(name), Some(value)) = (name.as_str(), value.as_str()) else {
                            return None;
                        };
                        HeaderName::from_bytes(name.as_bytes())
                            .ok()
                            .map(|name| (name, value.to_string()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let cookies = access
            .and_then(|v| v.get("cookies"))
            .and_then(|v| v.as_sequence())
            .map(|seq| {
                seq.iter()
                    .filter_map(|v| v.as_str().map(str::trim))
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("; ")
            })
            .filter(|s| !s.is_empty());
        let browser_fallback = access
            .and_then(|v| v.get("browser_fallback"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
            || access
                .and_then(|v| v.get("fallback"))
                .and_then(|v| v.get("on_challenge"))
                .and_then(|v| v.as_str())
                .is_some_and(|value| value == "browser_fetch_command");
        Self {
            profile,
            referer,
            headers,
            cookies,
            browser_fallback,
        }
    }
}

static REQUEST_CONTEXT_CACHE: OnceLock<RwLock<HashMap<String, RequestContext>>> = OnceLock::new();
static EXTRA_COOKIES: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();
#[derive(Clone)]
struct CachedCookie {
    value: Option<String>,
    expires_at: Instant,
    last_used: Instant,
}

static COOKIE_CACHE: OnceLock<RwLock<HashMap<String, CachedCookie>>> = OnceLock::new();
static PARSER_PRESET_CACHE: OnceLock<RwLock<HashMap<String, Option<Arc<serde_yaml::Value>>>>> =
    OnceLock::new();
static BROWSER_FETCH_COMMAND: OnceLock<RwLock<Option<String>>> = OnceLock::new();
static HTTP_CLIENTS: OnceLock<RwLock<HashMap<String, CachedClient>>> = OnceLock::new();
static TOKIO_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static BROWSER_FALLBACK_IN_FLIGHT: OnceLock<RwLock<HashMap<String, usize>>> = OnceLock::new();
static HOST_RETRY_AFTER: OnceLock<RwLock<HashMap<String, Instant>>> = OnceLock::new();

#[derive(Clone)]
struct CachedClient {
    client: Client,
    expires_at: Instant,
    last_used: Instant,
}

pub fn set_extra_cookie_for_domain(domain: &str, cookie: &str) {
    let map = EXTRA_COOKIES.get_or_init(|| RwLock::new(HashMap::new()));
    if let Ok(mut guard) = map.write() {
        guard.insert(
            domain.trim_matches('.').to_ascii_lowercase(),
            cookie.to_string(),
        );
    }
    clear_cookie_cache();
}

pub fn set_browser_fetch_command(command: &str) {
    let slot = BROWSER_FETCH_COMMAND.get_or_init(|| RwLock::new(None));
    if let Ok(mut guard) = slot.write() {
        let trimmed = command.trim();
        *guard = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
    }
}

pub fn clear_access_caches() {
    clear_cookie_cache();
    if let Some(cache) = PARSER_PRESET_CACHE.get() {
        if let Ok(mut guard) = cache.write() {
            guard.clear();
        }
    }
    if let Some(cache) = HTTP_CLIENTS.get() {
        if let Ok(mut guard) = cache.write() {
            guard.clear();
        }
    }
    if let Some(cache) = REQUEST_CONTEXT_CACHE.get() {
        if let Ok(mut guard) = cache.write() {
            guard.clear();
        }
    }
    if let Some(cache) = HOST_RETRY_AFTER.get() {
        if let Ok(mut guard) = cache.write() {
            guard.clear();
        }
    }
}

fn clear_cookie_cache() {
    if let Some(cache) = COOKIE_CACHE.get() {
        if let Ok(mut guard) = cache.write() {
            guard.clear();
        }
    }
}

fn runtime() -> Result<&'static tokio::runtime::Runtime> {
    Ok(TOKIO_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(runtime_worker_threads())
            .max_blocking_threads(runtime_max_blocking_threads())
            .thread_name("noveldl-net")
            .build()
            .expect("create NovelDL network runtime")
    }))
}

fn runtime_worker_threads() -> usize {
    std::env::var("NOVELDL_NET_WORKER_THREADS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(2)
        .clamp(1, 8)
}

fn runtime_max_blocking_threads() -> usize {
    std::env::var("NOVELDL_NET_MAX_BLOCKING_THREADS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(8)
        .clamp(2, 32)
}

fn shared_client(user_agent: &str) -> Result<Client> {
    shared_client_with_emulation(
        user_agent,
        configured_browser_emulation_name(),
        configured_browser_emulation(),
    )
}

fn shared_client_with_emulation(
    user_agent: &str,
    emulation_name: impl Into<String>,
    emulation: BrowserEmulation,
) -> Result<Client> {
    const HTTP_CLIENT_CACHE_LIMIT: usize = 16;
    const HTTP_CLIENT_CACHE_TTL: Duration = Duration::from_secs(60 * 60);

    let emulation_name = emulation_name.into();
    let key = client_cache_key(user_agent, &emulation_name);
    let now = Instant::now();
    let clients = HTTP_CLIENTS.get_or_init(|| RwLock::new(HashMap::new()));
    let mut guard = clients
        .write()
        .map_err(|_| anyhow::anyhow!("HTTP client cache lock poisoned"))?;
    guard.retain(|_, cached| cached.expires_at > now);
    if let Some(cached) = guard.get_mut(&key) {
        cached.last_used = now;
        return Ok(cached.client.clone());
    }
    prune_client_cache_to_limit(&mut guard, HTTP_CLIENT_CACHE_LIMIT.saturating_sub(1));

    let mut builder = Client::builder()
        .user_agent(user_agent)
        .emulation(emulation)
        .cookie_store(true)
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(30))
        .pool_idle_timeout(Duration::from_secs(300))
        .pool_max_idle_per_host(pool_max_idle_per_host())
        .pool_max_size(pool_max_size())
        .tcp_nodelay(true);
    let cert_store = if cfg!(target_os = "ios") {
        CertStore::default()
    } else {
        CertStore::builder()
            .set_default_paths()
            .build()
            .unwrap_or_else(|_| CertStore::default())
    };
    builder = builder.cert_store(cert_store);
    let client = builder.build()?;
    guard.insert(
        key,
        CachedClient {
            client: client.clone(),
            expires_at: now + HTTP_CLIENT_CACHE_TTL,
            last_used: now,
        },
    );
    Ok(client)
}

fn client_cache_key(user_agent: &str, emulation_name: &str) -> String {
    format!(
        "ua={user_agent};emu={emulation_name};idle={};pool={}",
        pool_max_idle_per_host(),
        pool_max_size()
    )
}

fn configured_browser_emulation_name() -> String {
    std::env::var("NOVELDL_WREQ_EMULATION")
        .unwrap_or_else(|_| "chrome147".to_string())
        .to_ascii_lowercase()
}

fn configured_browser_emulation() -> BrowserEmulation {
    browser_emulation_from_name(&configured_browser_emulation_name())
}

fn browser_emulation_from_name(name: &str) -> BrowserEmulation {
    match name {
        "chrome147" | "chrome_latest" | "chrome" | "default" => BrowserEmulation::Chrome147,
        "chrome146" => BrowserEmulation::Chrome146,
        "chrome145" => BrowserEmulation::Chrome145,
        "chrome144" => BrowserEmulation::Chrome144,
        "chrome143" => BrowserEmulation::Chrome143,
        "chrome142" => BrowserEmulation::Chrome142,
        "safari26_2" | "safari_latest" | "safari" => BrowserEmulation::Safari26_2,
        "safari26" => BrowserEmulation::Safari26,
        "safari_ios26_2" | "safari_ios_latest" => BrowserEmulation::SafariIos26_2,
        "safari_ios26" => BrowserEmulation::SafariIos26,
        "firefox149" | "firefox_latest" | "firefox" => BrowserEmulation::Firefox149,
        "firefox148" => BrowserEmulation::Firefox148,
        _ => BrowserEmulation::Chrome147,
    }
}

fn pool_max_idle_per_host() -> usize {
    std::env::var("NOVELDL_POOL_MAX_IDLE_PER_HOST")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(8)
        .clamp(1, 32)
}

fn pool_max_size() -> u32 {
    std::env::var("NOVELDL_POOL_MAX_SIZE")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(32)
        .clamp(4, 128)
}

fn extra_cookie_for_host(host: &str) -> Option<String> {
    let map = EXTRA_COOKIES.get_or_init(|| RwLock::new(HashMap::new()));
    let guard = map.read().ok()?;
    guard.get(host).cloned().or_else(|| {
        guard
            .iter()
            .find(|(domain, _)| domain_matches(host, domain))
            .map(|(_, cookie)| cookie.clone())
    })
}

fn domain_matches(host: &str, domain: &str) -> bool {
    let host = host.trim_matches('.');
    let domain = domain.trim_matches('.');
    if host.is_empty() || domain.is_empty() {
        return false;
    }
    host == domain
        || host.ends_with(&format!(".{domain}"))
        || domain.strip_prefix("www.").is_some_and(|apex| host == apex)
        || host.strip_prefix("www.").is_some_and(|apex| apex == domain)
}

fn prune_cache_to_limit<T>(cache: &mut HashMap<String, T>, limit: usize) {
    while cache.len() > limit {
        let Some(key) = cache.keys().next().cloned() else {
            break;
        };
        cache.remove(&key);
    }
}

fn prune_client_cache_to_limit(cache: &mut HashMap<String, CachedClient>, limit: usize) {
    while cache.len() > limit {
        let Some(key) = cache
            .iter()
            .min_by_key(|(_, cached)| cached.last_used)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        cache.remove(&key);
    }
}

fn prune_cookie_cache_to_limit(cache: &mut HashMap<String, CachedCookie>, limit: usize) {
    while cache.len() > limit {
        let Some(key) = cache
            .iter()
            .min_by_key(|(_, cached)| cached.last_used)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        cache.remove(&key);
    }
}

impl Downloader {
    pub fn new(user_agent: &str) -> Result<Self> {
        Ok(Self {
            client: shared_client(user_agent)?,
            runtime: None,
        })
    }

    pub fn with_client(client: Client) -> Self {
        Self {
            client,
            runtime: None,
        }
    }

    pub fn with_runtime(user_agent: &str, runtime: Arc<tokio::runtime::Runtime>) -> Result<Self> {
        Ok(Self {
            client: shared_client(user_agent)?,
            runtime: Some(runtime),
        })
    }

    pub fn with_client_and_runtime(client: Client, runtime: Arc<tokio::runtime::Runtime>) -> Self {
        Self {
            client,
            runtime: Some(runtime),
        }
    }

    pub fn fetch(&self, url: &str) -> Result<String> {
        self.fetch_with_retry(url, 3, Duration::from_secs(3))
    }

    pub fn fetch_with_retry(&self, url: &str, retries: usize, wait: Duration) -> Result<String> {
        if let Some(runtime) = &self.runtime {
            runtime.block_on(self.fetch_with_retry_async(url, retries, wait))
        } else {
            runtime()?.block_on(self.fetch_with_retry_async(url, retries, wait))
        }
    }

    async fn fetch_with_retry_async(
        &self,
        url: &str,
        retries: usize,
        wait: Duration,
    ) -> Result<String> {
        let ctx = RequestContext::new(url)?;
        let mut remain = retries;
        let mut attempt = 0u32;
        loop {
            wait_for_host_retry_window(&ctx.host).await;
            match self
                .fetch_once(&ctx, retry_primary_profile(ctx.profile, attempt))
                .await
            {
                Ok(text) => return Ok(text),
                Err(e) => {
                    let rate_limited = e
                        .downcast_ref::<DownloaderError>()
                        .is_some_and(|status| matches!(status, DownloaderError::RateLimited));

                    if let Some(status) = e.downcast_ref::<DownloaderError>() {
                        match status {
                            DownloaderError::NotFound | DownloaderError::JavaScriptChallenge => {
                                return Err(e);
                            }
                            DownloaderError::SuspendDownload | DownloaderError::RateLimited => {}
                            _ => {}
                        }
                    }

                    if remain == 0 {
                        return Err(e);
                    }
                    remain -= 1;
                    attempt += 1;
                    let delay = retry_delay(wait, attempt, rate_limited);
                    remember_host_retry_after(&ctx.host, delay);
                    tokio::time::sleep(delay).await;
                }
            }
        }
    }

    async fn fetch_once(&self, ctx: &RequestContext, primary: RequestProfile) -> Result<String> {
        match self.fetch_once_with_profile(ctx, primary, true).await {
            Ok(text) => Ok(text),
            Err(err) if is_challenge_error(&err) => {
                for profile in challenge_fallback_profiles(primary) {
                    match self.fetch_once_with_profile(ctx, profile, false).await {
                        Ok(text) => return Ok(text),
                        Err(next_err) if is_challenge_error(&next_err) => continue,
                        Err(next_err) => return Err(next_err),
                    }
                }
                if browser_fallback_enabled_for_context(ctx) {
                    return fetch_with_browser_fallback(&ctx.url)
                        .await
                        .with_context(|| "browser fallback after challenge".to_string());
                }
                Err(err)
            }
            Err(err) => Err(err),
        }
    }

    async fn fetch_once_with_profile(
        &self,
        ctx: &RequestContext,
        profile: RequestProfile,
        allow_yaml_profile: bool,
    ) -> Result<String> {
        let client = self.client_for_profile(ctx, profile)?;
        let mut request = client.get(ctx.url.as_str());
        request = apply_browser_headers(request);
        request = apply_site_headers(request, ctx);
        request = apply_profile_headers(request, profile);
        request = apply_yaml_access_headers(request, ctx, allow_yaml_profile);
        if let Some(cookie) = cookie_for_context(ctx) {
            request = request.header(COOKIE, cookie);
        }
        let resp = request
            .send()
            .await
            .with_context(|| format!("GET {}", ctx.url))?;
        let status = resp.status();
        if status == StatusCode::TOO_MANY_REQUESTS {
            return Err(DownloaderError::RateLimited.into());
        }
        if status == StatusCode::SERVICE_UNAVAILABLE {
            return Err(DownloaderError::SuspendDownload.into());
        }
        if status == StatusCode::NOT_FOUND {
            return Err(DownloaderError::NotFound.into());
        }
        let content_type = resp
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .map(str::to_string);
        let bytes = resp.bytes().await?;
        let challenge_body = is_challenge_bytes(&bytes);
        if challenge_body {
            return Err(DownloaderError::JavaScriptChallenge.into());
        }
        if status.is_success() {
            return bytes_to_string(&bytes, content_type.as_deref());
        }
        if status == StatusCode::FORBIDDEN {
            if browser_fallback_enabled_for_context(ctx) || is_forbidden_challenge_bytes(&bytes) {
                return Err(DownloaderError::JavaScriptChallenge.into());
            }
            return Err(anyhow::anyhow!("forbidden response status={}", status));
        }
        Err(anyhow::anyhow!("invalid response status={}", status))
    }

    fn client_for_profile(&self, _ctx: &RequestContext, profile: RequestProfile) -> Result<Client> {
        shared_client_for_profile(profile).or_else(|_| Ok(self.client.clone()))
    }
}

async fn wait_for_host_retry_window(host: &str) {
    let Some(until) = HOST_RETRY_AFTER
        .get_or_init(|| RwLock::new(HashMap::new()))
        .read()
        .ok()
        .and_then(|guard| guard.get(host).copied())
    else {
        return;
    };
    let now = Instant::now();
    if until > now {
        tokio::time::sleep(until - now).await;
    }
}

fn remember_host_retry_after(host: &str, delay: Duration) {
    let until = Instant::now() + delay;
    let map = HOST_RETRY_AFTER.get_or_init(|| RwLock::new(HashMap::new()));
    if let Ok(mut guard) = map.write() {
        guard.retain(|_, current| *current > Instant::now());
        guard.insert(host.to_string(), until);
    }
}

fn shared_client_for_profile(profile: RequestProfile) -> Result<Client> {
    let (name, emulation) = match profile {
        RequestProfile::ChromeDesktop => ("chrome147".to_string(), BrowserEmulation::Chrome147),
        RequestProfile::SafariDesktop => ("safari26_2".to_string(), BrowserEmulation::Safari26_2),
        RequestProfile::SafariMobile => (
            "safari_ios26_2".to_string(),
            BrowserEmulation::SafariIos26_2,
        ),
    };
    shared_client_with_emulation(profile.user_agent(), name, emulation)
}

fn retry_delay(base: Duration, attempt: u32, rate_limited: bool) -> Duration {
    let exponent = attempt.saturating_sub(1).min(5);
    let multiplier = 1u32 << exponent;
    let floor = if rate_limited {
        base.max(Duration::from_secs(10))
    } else {
        base
    };
    floor
        .saturating_mul(multiplier)
        .saturating_add(retry_jitter())
        .min(Duration::from_secs(60))
}

fn retry_jitter() -> Duration {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| (duration.subsec_millis() % 750) as u64)
        .unwrap_or(0);
    Duration::from_millis(millis)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RequestProfile {
    ChromeDesktop,
    SafariDesktop,
    SafariMobile,
}

impl RequestProfile {
    fn user_agent(self) -> &'static str {
        match self {
            RequestProfile::ChromeDesktop => {
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
            }
            RequestProfile::SafariDesktop => {
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 26_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
            }
            RequestProfile::SafariMobile => {
                "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
            }
        }
    }
}

fn apply_browser_headers(request: RequestBuilder) -> RequestBuilder {
    request
        .header(
            ACCEPT,
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
        )
        .header(ACCEPT_LANGUAGE, "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7")
        .header(ACCEPT_ENCODING, "gzip, deflate, br")
        .header(CACHE_CONTROL, "max-age=0")
        .header(PRAGMA, "no-cache")
        .header(DNT, "1")
        .header(UPGRADE_INSECURE_REQUESTS, "1")
        .header(header_name("sec-fetch-site"), "none")
        .header(header_name("sec-fetch-mode"), "navigate")
        .header(header_name("sec-fetch-user"), "?1")
        .header(header_name("sec-fetch-dest"), "document")
}

fn apply_profile_headers(request: RequestBuilder, profile: RequestProfile) -> RequestBuilder {
    let request = request.header(USER_AGENT, profile.user_agent());

    match profile {
        RequestProfile::ChromeDesktop => request
            .header(
                header_name("sec-ch-ua"),
                r#""Google Chrome";v="147", "Chromium";v="147", "Not.A/Brand";v="24""#,
            )
            .header(header_name("sec-ch-ua-mobile"), "?0")
            .header(header_name("sec-ch-ua-platform"), r#""macOS""#),
        RequestProfile::SafariDesktop | RequestProfile::SafariMobile => request,
    }
}

fn header_name(name: &'static str) -> HeaderName {
    HeaderName::from_static(name)
}

fn challenge_matcher() -> &'static AhoCorasick {
    static MATCHER: OnceLock<AhoCorasick> = OnceLock::new();
    MATCHER.get_or_init(|| {
        let mut patterns = vec![
            "just a moment".to_string(),
            "cf_chl".to_string(),
            "cf-ray".to_string(),
            "enable javascript and cookies".to_string(),
            "checking your browser".to_string(),
            "<h1>403 forbidden</h1>".to_string(),
            "<h1>403 error</h1>".to_string(),
            "error: the request could not be satisfied".to_string(),
            "generated by cloudfront".to_string(),
            "please enable cookies".to_string(),
            "datadome".to_string(),
        ];
        if let Ok(extra) = std::env::var("NOVELDL_CHALLENGE_PATTERNS") {
            patterns.extend(
                extra
                    .split('|')
                    .map(str::trim)
                    .filter(|pattern| !pattern.is_empty())
                    .map(str::to_string),
            );
        }
        AhoCorasickBuilder::new()
            .ascii_case_insensitive(true)
            .build(patterns)
            .expect("valid challenge patterns")
    })
}

fn is_challenge_bytes(bytes: &[u8]) -> bool {
    with_challenge_sample(bytes, |sample| {
        challenge_matcher().is_match(sample) || challenge_heuristic(sample)
    })
}

fn is_forbidden_challenge_bytes(bytes: &[u8]) -> bool {
    with_challenge_sample(bytes, |sample| {
        challenge_matcher().is_match(sample)
            || challenge_heuristic(sample)
            || has_ascii_ci(sample, b"forbidden") && has_ascii_ci(sample, b"captcha")
    })
}

fn with_challenge_sample(bytes: &[u8], detect: impl Fn(&[u8]) -> bool) -> bool {
    const PREFIX_LIMIT: usize = 256 * 1024;
    const SUFFIX_LIMIT: usize = 16 * 1024;
    if bytes.len() <= PREFIX_LIMIT + SUFFIX_LIMIT {
        return detect(bytes);
    }
    detect(&bytes[..PREFIX_LIMIT]) || detect(&bytes[bytes.len() - SUFFIX_LIMIT..])
}

fn challenge_heuristic(bytes: &[u8]) -> bool {
    (has_ascii_ci(bytes, b"cloudflare") && has_ascii_ci(bytes, b"challenge"))
        || (has_ascii_ci(bytes, b"akamai") && has_ascii_ci(bytes, b"access denied"))
        || (has_ascii_ci(bytes, b"datadome") && has_ascii_ci(bytes, b"captcha"))
        || (has_ascii_ci(bytes, b"bot manager") && has_ascii_ci(bytes, b"akamai"))
}

fn is_challenge_html(text: &str) -> bool {
    is_challenge_bytes(text.as_bytes())
}

fn has_ascii_ci(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window.eq_ignore_ascii_case(needle))
}

fn base_cookie_for_host(host: &str) -> Option<&'static str> {
    match host {
        "novel18.syosetu.com" | "noc.syosetu.com" | "mid.syosetu.com" | "mnlt.syosetu.com" => {
            Some("over18=yes")
        }
        "syosetu.org" => Some("over18=off; _ga=1"),
        "www.akatsuki-novels.com" => Some("CakeCookie[ALLOWED_ADULT_NOVEL]=on"),
        _ => None,
    }
}

fn parser_preset_for_host(host: &str) -> Option<Arc<serde_yaml::Value>> {
    const PARSER_PRESET_CACHE_LIMIT: usize = 128;
    let cache_key = canonical_preset_host(host).to_string();
    let cache = PARSER_PRESET_CACHE.get_or_init(|| RwLock::new(HashMap::new()));
    if let Ok(guard) = cache.read() {
        if let Some(cached) = guard.get(&cache_key) {
            return cached.clone();
        }
    }

    let loaded = ConfigManager::load_parser_preset(host).ok().or_else(|| {
        let canonical = canonical_preset_host(host);
        if canonical == host {
            None
        } else {
            ConfigManager::load_parser_preset(canonical).ok()
        }
    });
    let loaded = loaded.map(Arc::new);
    if let Ok(mut guard) = cache.write() {
        prune_cache_to_limit(&mut guard, PARSER_PRESET_CACHE_LIMIT.saturating_sub(1));
        guard.insert(cache_key, loaded.clone());
    }
    loaded
}

fn canonical_preset_host(host: &str) -> &str {
    match host {
        "www.novelup.plus" => "novelup.plus",
        "www.kakuyomu.jp" => "kakuyomu.jp",
        _ => host,
    }
}

fn yaml_cookie_for_context(ctx: &RequestContext) -> Option<String> {
    ctx.access.as_ref()?.cookies.clone()
}

fn apply_yaml_access_headers(
    mut request: RequestBuilder,
    ctx: &RequestContext,
    allow_profile: bool,
) -> RequestBuilder {
    let Some(access) = ctx.access.as_ref() else {
        return request;
    };
    if allow_profile {
        if let Some(profile) = access.profile {
            request = apply_profile_headers(request, profile);
        }
    }
    if let Some(referer) = access.referer.as_ref() {
        let value = match referer {
            AccessReferer::TocParent => {
                syosetu_referer(&ctx.parsed).unwrap_or_else(|| ctx.url.clone())
            }
            AccessReferer::Static(value) => value.clone(),
        };
        request = request.header(REFERER, value);
    }
    for (name, value) in &access.headers {
        request = request.header(name.clone(), value.clone());
    }
    request
}

fn request_profile_from_name(name: &str) -> RequestProfile {
    match name.to_ascii_lowercase().as_str() {
        "chrome_desktop" | "chrome" => RequestProfile::ChromeDesktop,
        "safari_desktop" | "safari" => RequestProfile::SafariDesktop,
        "safari_mobile" | "mobile_safari" | "ios" | "iphone" => RequestProfile::SafariMobile,
        _ => RequestProfile::SafariDesktop,
    }
}

fn is_challenge_error(err: &anyhow::Error) -> bool {
    err.downcast_ref::<DownloaderError>()
        .is_some_and(|status| matches!(status, DownloaderError::JavaScriptChallenge))
}

fn retry_primary_profile(primary: RequestProfile, attempt: u32) -> RequestProfile {
    let profiles = [
        primary,
        RequestProfile::ChromeDesktop,
        RequestProfile::SafariDesktop,
        RequestProfile::SafariMobile,
    ];
    profiles[(attempt as usize) % profiles.len()]
}

fn challenge_fallback_profiles(primary: RequestProfile) -> impl Iterator<Item = RequestProfile> {
    [
        RequestProfile::ChromeDesktop,
        RequestProfile::SafariDesktop,
        RequestProfile::SafariMobile,
    ]
    .into_iter()
    .filter(move |profile| *profile != primary)
}

fn browser_fallback_enabled_for_context(ctx: &RequestContext) -> bool {
    browser_fetch_command(&ctx.url).is_some()
        || ctx
            .access
            .as_ref()
            .is_some_and(|access| access.browser_fallback)
}

#[cfg(test)]
fn browser_fallback_enabled_for_url(url: &str) -> bool {
    RequestContext::new(url)
        .map(|ctx| browser_fallback_enabled_for_context(&ctx))
        .unwrap_or(false)
}

fn cookie_for_context(ctx: &RequestContext) -> Option<String> {
    const COOKIE_CACHE_LIMIT: usize = 256;
    const COOKIE_CACHE_TTL: Duration = Duration::from_secs(10 * 60);
    let now = Instant::now();
    let key = cookie_cache_key(ctx);
    let cache = COOKIE_CACHE.get_or_init(|| RwLock::new(HashMap::new()));
    if let Ok(guard) = cache.read() {
        if let Some(cached) = guard.get(&key) {
            if cached.expires_at > now {
                return cached.value.clone();
            }
        }
    }

    let cookie = merge_cookies([
        base_cookie_for_host(&ctx.host),
        extra_cookie_for_host(&ctx.host).as_deref(),
        yaml_cookie_for_context(ctx).as_deref(),
    ]);
    if let Ok(mut guard) = cache.write() {
        guard.retain(|_, cached| cached.expires_at > now);
        prune_cookie_cache_to_limit(&mut guard, COOKIE_CACHE_LIMIT.saturating_sub(1));
        guard.insert(
            key,
            CachedCookie {
                value: cookie.clone(),
                expires_at: now + COOKIE_CACHE_TTL,
                last_used: now,
            },
        );
    }
    cookie
}

fn cookie_cache_key(ctx: &RequestContext) -> String {
    format!(
        "{}://{}",
        ctx.parsed.scheme(),
        canonical_cookie_host(&ctx.host)
    )
}

fn canonical_cookie_host(host: &str) -> &str {
    host.strip_prefix("www.").unwrap_or(host)
}

async fn fetch_with_browser_fallback(url: &str) -> Result<String> {
    let Some(mut parts) = browser_fetch_command(url) else {
        return Err(DownloaderError::JavaScriptChallenge.into());
    };
    let host = Url::parse(url)
        .ok()
        .and_then(|url| url.host_str().map(str::to_ascii_lowercase))
        .unwrap_or_else(|| "unknown".to_string());
    let _slot = acquire_browser_fallback_slot(host)?;
    let url = url.to_string();
    tokio::task::spawn_blocking(move || {
        let program = parts.remove(0);
        let output = Command::new(&program)
            .args(parts)
            .output()
            .with_context(|| format!("run browser fetch command {program}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!(
                "browser fetch command failed status={} stderr={}",
                output.status,
                stderr.trim()
            ));
        }
        let html = bytes_to_string(output.stdout, None).context("decode browser fetch output")?;
        if html.trim().is_empty() || is_challenge_html(&html) {
            return Err(DownloaderError::JavaScriptChallenge.into());
        }
        Ok(html)
    })
    .await
    .with_context(|| format!("join browser fallback for {url}"))?
}

struct BrowserFallbackSlot {
    host: String,
}

impl Drop for BrowserFallbackSlot {
    fn drop(&mut self) {
        if let Some(map) = BROWSER_FALLBACK_IN_FLIGHT.get() {
            if let Ok(mut guard) = map.write() {
                if let Some(count) = guard.get_mut(&self.host) {
                    *count = count.saturating_sub(1);
                    if *count == 0 {
                        guard.remove(&self.host);
                    }
                }
            }
        }
    }
}

fn acquire_browser_fallback_slot(host: String) -> Result<BrowserFallbackSlot> {
    let limit = browser_fallback_limit_per_host();
    let map = BROWSER_FALLBACK_IN_FLIGHT.get_or_init(|| RwLock::new(HashMap::new()));
    let mut guard = map
        .write()
        .map_err(|_| anyhow::anyhow!("browser fallback limiter lock poisoned"))?;
    let count = guard.entry(host.clone()).or_insert(0);
    if *count >= limit {
        return Err(anyhow::anyhow!(
            "browser fallback limit reached for {host} ({limit})"
        ));
    }
    *count += 1;
    Ok(BrowserFallbackSlot { host })
}

fn browser_fallback_limit_per_host() -> usize {
    std::env::var("NOVELDL_BROWSER_FALLBACK_LIMIT_PER_HOST")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(2)
        .clamp(1, 8)
}

fn browser_fetch_command(url: &str) -> Option<Vec<String>> {
    let configured = BROWSER_FETCH_COMMAND
        .get_or_init(|| RwLock::new(None))
        .read()
        .ok()
        .and_then(|guard| guard.clone());
    let command = configured.or_else(|| std::env::var("NOVELDL_BROWSER_FETCH_CMD").ok())?;
    let parts = command_with_url(&command, url)?;
    command_is_executable(parts.first()?).then_some(parts)
}

fn command_is_executable(program: &str) -> bool {
    let path = std::path::Path::new(program);
    if path.components().count() > 1 {
        return path.is_file();
    }
    std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|dir| dir.join(program))
                .find(|candidate| candidate.is_file())
        })
        .is_some()
}

fn command_with_url(command: &str, url: &str) -> Option<Vec<String>> {
    let mut parts = split_command_words(command);
    if parts.is_empty() {
        return None;
    }
    let mut replaced = false;
    for part in &mut parts {
        if part.contains("{url}") {
            *part = part.replace("{url}", url);
            replaced = true;
        }
    }
    if !replaced {
        parts.push(url.to_string());
    }
    Some(parts)
}

fn split_command_words(command: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut chars = command.chars().peekable();
    let mut quote = None;
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => {
                if let Some(next) = chars.next() {
                    current.push(next);
                }
            }
            '\'' | '"' if quote == Some(ch) => quote = None,
            '\'' | '"' if quote.is_none() => quote = Some(ch),
            c if c.is_whitespace() && quote.is_none() => {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
            }
            c => current.push(c),
        }
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

fn bytes_to_string(bytes: impl AsRef<[u8]>, content_type: Option<&str>) -> Result<String> {
    let bytes = bytes.as_ref();
    let encoding = content_type
        .and_then(charset_from_content_type)
        .or_else(|| charset_from_html_prefix(bytes));
    if let Some(encoding) = encoding {
        let (decoded, _, _) = encoding.decode(bytes);
        return Ok(decoded.into_owned());
    }
    match std::str::from_utf8(bytes) {
        Ok(text) => Ok(text.to_owned()),
        Err(_) => {
            let (decoded, _, had_errors) = encoding_rs::SHIFT_JIS.decode(bytes);
            if had_errors {
                Ok(String::from_utf8_lossy(bytes).into_owned())
            } else {
                Ok(decoded.into_owned())
            }
        }
    }
}

fn charset_from_content_type(content_type: &str) -> Option<&'static encoding_rs::Encoding> {
    content_type
        .split(';')
        .find_map(|part| part.trim().strip_prefix("charset="))
        .and_then(|charset| {
            encoding_rs::Encoding::for_label(trim_charset_label(charset).as_bytes())
        })
}

fn charset_from_html_prefix(bytes: &[u8]) -> Option<&'static encoding_rs::Encoding> {
    let prefix = &bytes[..bytes.len().min(64 * 1024)];
    let text = String::from_utf8_lossy(prefix).to_ascii_lowercase();
    let marker = "charset=";
    let index = text.find(marker)? + marker.len();
    let label = text[index..]
        .split(|ch: char| ch == '"' || ch == '\'' || ch == '>' || ch.is_whitespace() || ch == ';')
        .next()?;
    encoding_rs::Encoding::for_label(trim_charset_label(label).as_bytes())
}

fn trim_charset_label(label: &str) -> &str {
    label
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .trim_end_matches('/')
}

#[cfg(test)]
fn cookie_for_url(url: &str) -> Option<String> {
    RequestContext::new(url)
        .ok()
        .and_then(|ctx| cookie_for_context(&ctx))
}

fn merge_cookies<'a>(sources: impl IntoIterator<Item = Option<&'a str>>) -> Option<String> {
    let mut merged: Vec<(String, String)> = Vec::new();
    for cookie in sources
        .into_iter()
        .flatten()
        .flat_map(|cookies| cookies.split(';'))
        .map(str::trim)
        .filter(|cookie| !cookie.is_empty())
    {
        let name = cookie
            .split_once('=')
            .map(|(name, _)| name.trim())
            .unwrap_or(cookie);
        if name.is_empty() {
            continue;
        }
        if let Some((_, existing)) = merged.iter_mut().find(|(existing, _)| existing == name) {
            *existing = cookie.to_string();
        } else {
            merged.push((name.to_string(), cookie.to_string()));
        }
    }
    if merged.is_empty() {
        None
    } else {
        Some(
            merged
                .into_iter()
                .map(|(_, cookie)| cookie)
                .collect::<Vec<_>>()
                .join("; "),
        )
    }
}

fn apply_site_headers(request: RequestBuilder, ctx: &RequestContext) -> RequestBuilder {
    match ctx.host.as_str() {
        "syosetu.org" => {
            let referer =
                syosetu_referer(&ctx.parsed).unwrap_or_else(|| "https://syosetu.org/".to_string());
            request.header(REFERER, referer)
        }
        "novelup.plus" | "www.novelup.plus" => request.header(REFERER, "https://novelup.plus/"),
        _ => request,
    }
}

fn syosetu_referer(url: &Url) -> Option<String> {
    let mut segments = url.path_segments()?;
    let first = segments.next()?;
    let second = segments.next()?;
    if first != "novel" || second.is_empty() {
        return None;
    }
    Some(format!("https://syosetu.org/novel/{second}/"))
}

fn profile_for_host(host: &str) -> RequestProfile {
    match host {
        "syosetu.org" => RequestProfile::ChromeDesktop,
        "kakuyomu.jp" | "www.kakuyomu.jp" => RequestProfile::SafariDesktop,
        "novelup.plus" | "www.novelup.plus" => RequestProfile::ChromeDesktop,
        _ => RequestProfile::SafariDesktop,
    }
}

#[cfg(test)]
fn profile_for_url(url: &str) -> RequestProfile {
    RequestContext::new(url)
        .map(|ctx| ctx.profile)
        .unwrap_or(RequestProfile::ChromeDesktop)
}

#[cfg(test)]
mod tests {
    use super::{
        RequestProfile, browser_fallback_enabled_for_url, bytes_to_string, command_with_url,
        cookie_for_url, domain_matches, extra_cookie_for_host, is_challenge_html,
        parser_preset_for_host, profile_for_url, set_extra_cookie_for_domain, syosetu_referer,
    };
    use url::Url;

    #[test]
    fn syosetu_referer_points_to_toc() {
        let u = Url::parse("https://syosetu.org/novel/404429/1.html").unwrap();
        assert_eq!(
            syosetu_referer(&u).as_deref(),
            Some("https://syosetu.org/novel/404429/")
        );
    }

    #[test]
    fn domain_matches_www_and_apex_for_clearance_cookies() {
        assert!(domain_matches("novelup.plus", "www.novelup.plus"));
        assert!(domain_matches("www.novelup.plus", "novelup.plus"));
        assert!(domain_matches("sub.novelup.plus", "novelup.plus"));
        assert!(!domain_matches("evilnovelup.plus", "novelup.plus"));
    }

    #[test]
    fn extra_cookie_matches_subdomains() {
        set_extra_cookie_for_domain("novelup.plus", "session=abc");
        assert_eq!(
            extra_cookie_for_host("www.novelup.plus").as_deref(),
            Some("session=abc")
        );
    }

    #[test]
    fn cookie_for_url_merges_site_and_browser_cookies_for_any_domain() {
        set_extra_cookie_for_domain("syosetu.org", "cf_clearance=token");
        assert_eq!(
            cookie_for_url("https://syosetu.org/novel/404429/").as_deref(),
            Some("over18=off; _ga=1; cf_clearance=token")
        );
    }

    #[test]
    fn challenge_detection_scans_extended_prefix() {
        assert!(is_challenge_html("<html>Just a moment...</html>"));
        let within_limit = format!("{}cf-ray", "a".repeat(5000));
        assert!(is_challenge_html(&within_limit));
        let tail_challenge = format!("{}cf-ray", "a".repeat(20_000));
        assert!(is_challenge_html(&tail_challenge));
        let large_tail_challenge = format!("{}cf-ray", "a".repeat(300_000));
        assert!(is_challenge_html(&large_tail_challenge));
        let middle_only = format!("{}cf-ray{}", "a".repeat(80_000), "b".repeat(80_000));
        assert!(is_challenge_html(&middle_only));
    }

    #[test]
    fn bytes_to_string_decodes_shift_jis_charset() {
        let bytes = [0x82, 0xb1, 0x82, 0xf1, 0x82, 0xc9, 0x82, 0xbf, 0x82, 0xcd];
        assert_eq!(
            bytes_to_string(bytes, Some("text/html; charset=Shift_JIS")).unwrap(),
            "こんにちは"
        );
    }

    #[test]
    fn browser_fetch_command_appends_or_replaces_url() {
        assert_eq!(
            command_with_url("browser-fetch --html", "https://example.test").unwrap(),
            vec!["browser-fetch", "--html", "https://example.test"]
        );
        assert_eq!(
            command_with_url("browser-fetch --url {url}", "https://example.test").unwrap(),
            vec!["browser-fetch", "--url", "https://example.test"]
        );
    }

    #[test]
    fn profile_for_url_uses_host_specific_browser_profiles() {
        assert_eq!(
            profile_for_url("https://syosetu.org/novel/404429/1.html"),
            RequestProfile::ChromeDesktop
        );
        assert_eq!(
            profile_for_url("https://kakuyomu.jp/works/123"),
            RequestProfile::SafariDesktop
        );
        assert_eq!(
            profile_for_url("https://example.test/story/1"),
            RequestProfile::SafariDesktop
        );
    }

    #[test]
    fn syosetu_yaml_access_is_cached_and_external_browser_fallback_is_enabled() {
        let preset = parser_preset_for_host("syosetu.org").expect("syosetu access preset");
        let access = preset.get("access").expect("syosetu access settings");
        assert_eq!(
            access.get("browser_fallback").and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            access.get("referer").and_then(|v| v.as_str()),
            Some("toc_parent")
        );

        for url in [
            "https://syosetu.org/novel/18606/1.html",
            "https://syosetu.org/novel/404429/12.html",
            "https://syosetu.org/novel/1/1.html",
        ] {
            assert_eq!(profile_for_url(url), RequestProfile::ChromeDesktop);
            assert!(browser_fallback_enabled_for_url(url), "{url}");
        }
    }

    #[test]
    fn novelup_yaml_access_uses_chrome_profile_with_external_browser_fallback() {
        assert_eq!(
            profile_for_url("https://www.novelup.plus/story/220474819"),
            RequestProfile::ChromeDesktop
        );
        let preset = parser_preset_for_host("www.novelup.plus").expect("canonical novelup preset");
        let access = preset.get("access").expect("novelup access settings");
        assert_eq!(
            access.get("profile").and_then(|v| v.as_str()),
            Some("chrome_desktop")
        );
        assert!(browser_fallback_enabled_for_url(
            "https://www.novelup.plus/story/220474819"
        ));
    }
}

pub mod pipeline;
pub mod state;

pub mod errors;

pub mod database_updater;
pub mod file_operations;
pub mod section_downloader;
pub mod toc_processor;

pub mod class_methods;

#[cfg(test)]
mod retry_tests {
    use super::retry_delay;
    use std::time::Duration;

    #[test]
    fn retry_delay_uses_exponential_cap() {
        let normal = retry_delay(Duration::from_secs(3), 3, false);
        assert!(normal >= Duration::from_secs(12));
        assert!(normal <= Duration::from_secs(13));

        let capped = retry_delay(Duration::from_secs(30), 5, true);
        assert_eq!(capped, Duration::from_secs(60));
    }
}
