use crate::config_manager::ConfigManager;
use anyhow::{Context, Result, anyhow};
use percent_encoding::percent_decode_str;
use regex::Regex;
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use url::Url;
use wreq::{Client, tls::CertStore};
use wreq_util::Emulation as BrowserEmulation;

const WEBNOVELS_SEARCH_ENDPOINT: &str = "https://webnovels.jp/search";
const DEFAULT_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";
const DEFAULT_LIMIT: usize = 40;
const MAX_TOTAL_LIMIT: usize = 180;
const MAX_RESULTS_PER_SITE: usize = 50;
const RESULTS_PER_PAGE: usize = 20;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WebnovelsSite {
    pub key: String,
    pub label: String,
    pub domains: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NovelSearchResult {
    pub title: String,
    pub url: String,
    pub detail_url: Option<String>,
    pub site: String,
    pub site_key: String,
    pub author: Option<String>,
    pub summary: Option<String>,
    pub tags: Vec<String>,
    pub updated: Option<String>,
    pub episode_count: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NovelSearchResponse {
    pub query: String,
    pub sites: Vec<String>,
    pub results: Vec<NovelSearchResult>,
}

pub fn supported_webnovels_sites() -> Vec<WebnovelsSite> {
    load_supported_webnovels_sites().unwrap_or_else(|_| builtin_webnovels_sites())
}

pub fn load_supported_webnovels_sites() -> Result<Vec<WebnovelsSite>> {
    ConfigManager::ensure_default_presets()?;
    let parser_sites =
        load_webnovels_sites_from_dir(ConfigManager::user_presets_dir().join("parsers"))?;
    let legacy_sites =
        load_webnovels_sites_from_dir(ConfigManager::user_presets_dir().join("webnovel"))?;
    Ok(merge_webnovels_sites(parser_sites, legacy_sites))
}

fn merge_webnovels_sites(
    primary: Vec<WebnovelsSite>,
    fallback: Vec<WebnovelsSite>,
) -> Vec<WebnovelsSite> {
    let mut grouped = primary
        .into_iter()
        .map(|site| (site.key.clone(), site))
        .collect::<BTreeMap<_, _>>();
    for fallback_site in fallback {
        let entry = grouped
            .entry(fallback_site.key.clone())
            .or_insert(WebnovelsSite {
                key: fallback_site.key.clone(),
                label: fallback_site.label.clone(),
                domains: Vec::new(),
            });
        for domain in fallback_site.domains {
            if !entry.domains.iter().any(|existing| existing == &domain) {
                entry.domains.push(domain);
            }
        }
    }

    let mut sites = grouped.into_values().collect::<Vec<_>>();
    let order = known_webnovels_order();
    sites.sort_by_key(|site| order.get(site.key.as_str()).copied().unwrap_or(usize::MAX));
    sites
}
fn load_webnovels_sites_from_dir(dir: PathBuf) -> Result<Vec<WebnovelsSite>> {
    let mut entries = fs::read_dir(&dir)
        .with_context(|| format!("read webnovels preset dir {}", dir.display()))?
        .collect::<std::io::Result<Vec<_>>>()?;
    entries.sort_by_key(|entry| entry.path());

    let mut grouped: BTreeMap<String, WebnovelsSite> = BTreeMap::new();
    for entry in entries {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("yaml") {
            continue;
        }
        let raw = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
        let raw_value: serde_yaml::Value =
            serde_yaml::from_str(&raw).with_context(|| format!("parse YAML {}", path.display()))?;
        let value = ConfigManager::resolve_parser_extends(raw_value.clone()).unwrap_or(raw_value);
        let Some(site_key) = value
            .get("webnovels_site")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let site_key = site_key.to_ascii_lowercase();
        let domain = value
            .get("domain")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .or_else(|| {
                path.file_stem()
                    .and_then(|value| value.to_str())
                    .map(str::to_string)
            })
            .ok_or_else(|| anyhow!("webnovels preset has no domain: {}", path.display()))?;
        let label = known_webnovels_label(&site_key)
            .map(str::to_string)
            .or_else(|| {
                value
                    .get("webnovels_label")
                    .or_else(|| value.get("name"))
                    .or_else(|| value.get("sitename"))
                    .and_then(|value| value.as_str())
                    .map(str::to_string)
            })
            .unwrap_or_else(|| site_key.clone());

        let entry = grouped.entry(site_key.clone()).or_insert(WebnovelsSite {
            key: site_key,
            label,
            domains: Vec::new(),
        });
        if !entry.domains.iter().any(|existing| existing == &domain) {
            entry.domains.push(domain);
        }
    }

    let mut sites = grouped.into_values().collect::<Vec<_>>();
    let order = known_webnovels_order();
    sites.sort_by_key(|site| order.get(site.key.as_str()).copied().unwrap_or(usize::MAX));
    Ok(sites)
}

fn builtin_webnovels_sites() -> Vec<WebnovelsSite> {
    vec![
        WebnovelsSite {
            key: "narou".to_string(),
            label: "小説家になろう".to_string(),
            domains: vec![
                "ncode.syosetu.com".to_string(),
                "novel18.syosetu.com".to_string(),
                "noc.syosetu.com".to_string(),
                "mnlt.syosetu.com".to_string(),
                "mid.syosetu.com".to_string(),
            ],
        },
        WebnovelsSite {
            key: "kakuyomu".to_string(),
            label: "カクヨム".to_string(),
            domains: vec!["kakuyomu.jp".to_string()],
        },
        WebnovelsSite {
            key: "hameln".to_string(),
            label: "ハーメルン".to_string(),
            domains: vec!["syosetu.org".to_string()],
        },
        WebnovelsSite {
            key: "novelup".to_string(),
            label: "ノベルアップ＋".to_string(),
            domains: vec!["novelup.plus".to_string()],
        },
        WebnovelsSite {
            key: "arcadia".to_string(),
            label: "Arcadia".to_string(),
            domains: vec!["www.mai-net.net".to_string()],
        },
        WebnovelsSite {
            key: "akatsuki".to_string(),
            label: "暁".to_string(),
            domains: vec!["www.akatsuki-novels.com".to_string()],
        },
    ]
}

fn known_webnovels_order() -> HashMap<&'static str, usize> {
    [
        "narou", "kakuyomu", "hameln", "novelup", "arcadia", "akatsuki",
    ]
    .into_iter()
    .enumerate()
    .map(|(index, key)| (key, index))
    .collect()
}

fn known_webnovels_label(site_key: &str) -> Option<&'static str> {
    match site_key {
        "narou" => Some("小説家になろう"),
        "kakuyomu" => Some("カクヨム"),
        "hameln" => Some("ハーメルン"),
        "novelup" => Some("ノベルアップ＋"),
        "arcadia" => Some("Arcadia"),
        "akatsuki" => Some("暁"),
        _ => None,
    }
}

pub struct WebnovelsSearcher {
    client: Client,
    endpoint: String,
    runtime: Option<Arc<tokio::runtime::Runtime>>,
}

fn build_search_client(user_agent: &str) -> Result<Client> {
    let mut builder = Client::builder()
        .user_agent(user_agent)
        .emulation(BrowserEmulation::Chrome147)
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(30))
        .pool_idle_timeout(Duration::from_secs(120));
    let cert_store = if cfg!(target_os = "ios") {
        CertStore::default()
    } else {
        CertStore::builder()
            .set_default_paths()
            .build()
            .unwrap_or_else(|_| CertStore::default())
    };
    builder = builder.cert_store(cert_store);
    Ok(builder.build()?)
}

fn runtime() -> Result<&'static tokio::runtime::Runtime> {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    Ok(RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .thread_name("noveldl-webnovels-search")
            .build()
            .expect("create NovelDL webnovels search runtime")
    }))
}

impl WebnovelsSearcher {
    pub fn new(user_agent: &str) -> Result<Self> {
        Self::with_endpoint(WEBNOVELS_SEARCH_ENDPOINT, user_agent)
    }

    pub fn with_endpoint(endpoint: impl Into<String>, user_agent: &str) -> Result<Self> {
        Ok(Self {
            client: build_search_client(user_agent)?,
            endpoint: endpoint.into(),
            runtime: None,
        })
    }

    pub fn with_runtime(
        endpoint: impl Into<String>,
        user_agent: &str,
        runtime: Arc<tokio::runtime::Runtime>,
    ) -> Result<Self> {
        Ok(Self {
            client: build_search_client(user_agent)?,
            endpoint: endpoint.into(),
            runtime: Some(runtime),
        })
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<NovelSearchResponse> {
        let site_definitions = load_supported_webnovels_sites()?;
        let site_keys = site_definitions
            .iter()
            .map(|site| site.key.clone())
            .collect::<Vec<_>>();
        let cleaned_query = strip_site_filters(&normalize_search_query_input(query));
        let limit = normalize_limit(limit);
        let per_site_limit = per_site_limit(limit, site_keys.len());
        let fetch = async {
            let mut all_results = Vec::new();
            let mut failures = Vec::new();
            for site in &site_keys {
                match self
                    .search_one_site(&cleaned_query, site, per_site_limit)
                    .await
                {
                    Ok(site_results) => all_results.extend(site_results),
                    Err(error) => failures.push(format!("{site}: {error:#}")),
                }
            }
            if all_results.is_empty() && failures.len() == site_keys.len() && !failures.is_empty() {
                return Err(anyhow!(
                    "webnovels.jp search failed for all sites: {}",
                    failures.join("; ")
                ));
            }
            all_results.truncate(limit);
            Ok(NovelSearchResponse {
                query: cleaned_query,
                sites: site_keys,
                results: all_results,
            })
        };
        if let Some(runtime) = &self.runtime {
            runtime.block_on(fetch)
        } else {
            runtime()?.block_on(fetch)
        }
    }

    async fn search_one_site(
        &self,
        query: &str,
        site: &str,
        limit: usize,
    ) -> Result<Vec<NovelSearchResult>> {
        let mut results = Vec::new();
        let page_count = limit.div_ceil(RESULTS_PER_PAGE).max(1);
        let webnovels_query = site_scoped_query(query, site);

        for page in 1..=page_count {
            let url = build_search_url(&self.endpoint, &webnovels_query, page)?;
            let resp = self.client.get(url.as_str()).send().await?;
            let html = resp
                .error_for_status()
                .with_context(|| format!("request webnovels.jp search: {url}"))?
                .text()
                .await?;
            let mut page_results = parse_search_results(&html, Some(site));
            if page_results.is_empty() {
                break;
            }
            results.append(&mut page_results);
            if results.len() >= limit {
                results.truncate(limit);
                break;
            }
        }

        Ok(results)
    }
}

pub fn search_webnovels(query: &str, limit: usize) -> Result<NovelSearchResponse> {
    WebnovelsSearcher::new(DEFAULT_USER_AGENT)?.search(query, limit)
}

pub fn resolve_sites(site: &str) -> Result<Vec<String>> {
    let supported = supported_webnovels_sites();
    let trimmed = site.trim().trim_start_matches("site:");
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("all") {
        return Ok(supported.into_iter().map(|site| site.key).collect());
    }

    let normalized = normalize_site_key(trimmed);
    supported
        .into_iter()
        .find(|site| site.key == normalized)
        .map(|site| vec![site.key])
        .ok_or_else(|| anyhow!("unsupported site flag: {site}"))
}

fn normalize_limit(limit: usize) -> usize {
    if limit == 0 {
        DEFAULT_LIMIT
    } else {
        limit.min(MAX_TOTAL_LIMIT)
    }
}

fn per_site_limit(total_limit: usize, site_count: usize) -> usize {
    if site_count == 0 {
        return 0;
    }
    total_limit
        .div_ceil(site_count)
        .clamp(1, MAX_RESULTS_PER_SITE)
}

fn normalize_site_key(site: &str) -> String {
    site.trim()
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_start_matches("www.")
        .trim_end_matches('/')
        .to_ascii_lowercase()
}

fn site_scoped_query(query: &str, site: &str) -> String {
    let query = query.trim();
    if query.is_empty() {
        format!("site:{site}")
    } else {
        format!("{query} site:{site}")
    }
}

fn normalize_search_query_input(query: &str) -> String {
    let trimmed = query.trim();
    if !trimmed.contains('%') {
        return trimmed.to_string();
    }

    let form_like = trimmed.replace('+', " ");
    percent_decode_str(&form_like)
        .decode_utf8_lossy()
        .trim()
        .to_string()
}

fn build_search_url(endpoint: &str, query: &str, page: usize) -> Result<Url> {
    let mut url =
        Url::parse(endpoint).with_context(|| format!("parse search endpoint: {endpoint}"))?;
    {
        let mut pairs = url.query_pairs_mut();
        pairs.append_pair("q", query);
        pairs.append_pair("type", "all");
        if page > 1 {
            pairs.append_pair("p", &page.to_string());
        }
    }
    Ok(url)
}

fn strip_site_filters(query: &str) -> String {
    static SITE_RE: OnceLock<Regex> = OnceLock::new();
    SITE_RE
        .get_or_init(|| Regex::new(r"(?:^|\s)site:[^\s]+").expect("valid site regex"))
        .replace_all(query, " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn parse_search_results(html: &str, expected_site: Option<&str>) -> Vec<NovelSearchResult> {
    let document = Html::parse_document(html);
    let row_selector = selector("div.list div.row, article.row, li.row");
    let title_selector = selector("div.row-title a, .row-title a, h2 a, h3 a");
    let detail_selector = selector(
        "a.row-link-detail, a[href^='/narou/'], a[href^='/kakuyomu/'], a[href^='/hameln/'], a[href^='/novelup/'], a[href^='/arcadia/'], a[href^='/akatsuki/']",
    );
    let summary_selector = selector("div.row-summary, .row-summary, .summary");
    let tag_selector = selector("div.row-tag a, .row-tag a, .tags a");
    let site_selector = selector("span.row-site a, .row-site a");
    let author_selector = selector("span.row-author a, .row-author a");
    let update_selector = selector("div.row-update, .row-update");

    document
        .select(&row_selector)
        .filter_map(|row| {
            let title_link = row.select(&title_selector).next()?;
            let title = normalized_text(title_link.text());
            let url = normalize_result_url(&attr(&title_link, "href")?);
            let detail_url = row
                .select(&detail_selector)
                .next()
                .and_then(|node| attr(&node, "href"))
                .map(|href| normalize_result_url(&href));
            let site_node = row.select(&site_selector).next();
            let site_label = site_node
                .as_ref()
                .map(|node| normalized_text(node.text()))
                .unwrap_or_default();
            let site_key = detail_url
                .as_deref()
                .and_then(site_key_from_webnovels_url)
                .or_else(|| {
                    site_node
                        .as_ref()
                        .and_then(|node| attr(node, "href"))
                        .as_deref()
                        .and_then(site_key_from_webnovels_url)
                })
                .or_else(|| expected_site.map(str::to_string))
                .unwrap_or_default();

            if let Some(expected) = expected_site {
                if !site_key.is_empty() && site_key != expected {
                    return None;
                }
            }

            let summary = row
                .select(&summary_selector)
                .next()
                .map(|node| normalized_text(node.text()))
                .filter(|value| !value.is_empty());
            let author = row
                .select(&author_selector)
                .next()
                .map(|node| normalized_text(node.text()))
                .filter(|value| !value.is_empty());
            let tags = row
                .select(&tag_selector)
                .map(|node| normalized_text(node.text()))
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>();
            let updated = row
                .select(&update_selector)
                .next()
                .map(|node| {
                    normalized_text(node.text())
                        .trim_start_matches("更新:")
                        .trim()
                        .to_string()
                })
                .filter(|value| !value.is_empty());
            let episode_count = updated.as_deref().and_then(extract_episode_count);

            Some(NovelSearchResult {
                title,
                url,
                detail_url,
                site: site_label,
                site_key,
                author,
                summary,
                tags,
                updated,
                episode_count,
            })
        })
        .collect()
}

fn selector(css: &str) -> Selector {
    Selector::parse(css).expect("valid static CSS selector")
}

fn attr(node: &scraper::ElementRef<'_>, name: &str) -> Option<String> {
    node.value()
        .attr(name)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn normalized_text<'a>(text: impl Iterator<Item = &'a str>) -> String {
    text.collect::<Vec<_>>()
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn normalize_result_url(href: &str) -> String {
    if href.starts_with('/') {
        format!("https://webnovels.jp{href}")
    } else {
        href.to_string()
    }
}

fn site_key_from_webnovels_url(href: &str) -> Option<String> {
    let path = if href.starts_with('/') {
        href.to_string()
    } else {
        let url = Url::parse(href).ok()?;
        if url.host_str()? != "webnovels.jp" {
            return None;
        }
        url.path().to_string()
    };
    path.trim_start_matches('/')
        .split('/')
        .next()
        .map(str::to_string)
        .filter(|value| !value.is_empty() && value != "search")
}

fn extract_episode_count(text: &str) -> Option<u32> {
    static EPISODE_RE: OnceLock<Regex> = OnceLock::new();
    EPISODE_RE
        .get_or_init(|| Regex::new(r"(\d+)\s*(?:話|部分)").expect("valid episode regex"))
        .captures(text)
        .and_then(|captures| captures.get(1))
        .and_then(|value| value.as_str().parse::<u32>().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_supported_site_aliases() {
        assert_eq!(resolve_sites("site:kakuyomu").unwrap(), vec!["kakuyomu"]);
        assert_eq!(resolve_sites("narou").unwrap(), vec!["narou"]);
        assert!(resolve_sites("ncode.syosetu.com").is_err());
        assert!(resolve_sites("unsupported").is_err());
    }

    #[test]
    fn loads_builtin_webnovels_site_flags() {
        let sites = load_webnovels_sites_from_dir(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("presets/parsers"),
        )
        .expect("builtin parser presets are valid YAML");
        let narou = sites
            .iter()
            .find(|site| site.key == "narou")
            .expect("narou site flag is present");
        assert!(
            narou
                .domains
                .iter()
                .any(|domain| domain == "ncode.syosetu.com")
        );
        assert!(
            sites
                .iter()
                .any(|site| site.key == "kakuyomu" && site.domains == ["kakuyomu.jp"])
        );
    }

    #[test]
    fn strips_site_filters_from_query() {
        assert_eq!(
            strip_site_filters("魔法 site:kakuyomu 異世界"),
            "魔法 異世界"
        );
        assert_eq!(site_scoped_query("魔法", "narou"), "魔法 site:narou");
    }

    #[test]
    fn normalizes_preencoded_query_before_scoping() {
        let normalized = normalize_search_query_input(
            "%E3%83%AC%E3%82%B8%E3%82%A7%E3%83%B3%E3%83%89+site%3Anarou",
        );
        assert_eq!(normalized, "レジェンド site:narou");
        assert_eq!(strip_site_filters(&normalized), "レジェンド");
    }

    #[test]
    fn all_builtin_site_flags_are_used_by_name_not_domain() {
        for site in builtin_webnovels_sites() {
            let scoped_query = site_scoped_query("魔法", &site.key);
            assert_eq!(scoped_query, format!("魔法 site:{}", site.key));
            for domain in site.domains {
                assert!(!scoped_query.contains(&domain));
            }
        }
    }

    #[test]
    fn all_bundled_yaml_site_flags_are_used_by_name_not_domain() {
        let preset_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("presets");
        let sites = load_webnovels_sites_from_dir(preset_root.join("parsers"))
            .expect("builtin parser presets are valid YAML");
        for site in sites {
            let scoped_query = site_scoped_query("魔法", &site.key);
            assert_eq!(scoped_query, format!("魔法 site:{}", site.key));
            for domain in site.domains {
                assert!(!scoped_query.contains(&domain));
            }
        }
    }

    #[test]
    fn builds_search_url_with_single_percent_encoding() {
        let url = build_search_url("https://webnovels.jp/search", "レジェンド site:narou", 2)
            .unwrap()
            .to_string();
        assert!(url.contains("q=%E3%83%AC%E3%82%B8%E3%82%A7%E3%83%B3%E3%83%89+site%3Anarou"));
        assert!(url.contains("type=all"));
        assert!(url.contains("p=2"));
        assert!(!url.contains("site%253A"));
    }

    #[test]
    fn parses_relative_webnovels_detail_links() {
        let html = r#"
        <div class="list">
          <div class="row">
            <div class="row-right-block"><a href="/kakuyomu/168" class="row-link-detail">作品詳細</a></div>
            <div class="row-title"><a href="https://kakuyomu.jp/works/168">相対リンク作品</a></div>
            <div class="row-info"><span class="row-site"><a href="/kakuyomu">カクヨム</a></span></div>
          </div>
        </div>
        "#;
        let results = parse_search_results(html, Some("kakuyomu"));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].site_key, "kakuyomu");
        assert_eq!(
            results[0].detail_url.as_deref(),
            Some("https://webnovels.jp/kakuyomu/168")
        );
    }

    #[test]
    fn parses_webnovels_search_rows() {
        let html = r#"
        <div class="list">
          <div class="row">
            <div class="row-right-block">
              <a href="https://webnovels.jp/kakuyomu/168" class="row-link-detail">作品詳細</a>
            </div>
            <div class="row-title"><a href="https://kakuyomu.jp/works/168" target="_blank">タイトル</a></div>
            <div class="row-summary">概要 です</div>
            <div class="row-info">
              <div class="row-tag"><a href="https://webnovels.jp/search?q=tag%3A%E9%AD%94%E6%B3%95">魔法</a></div>
              <div class="row-detail">
                <span class="row-site">掲載: <a href="https://webnovels.jp/kakuyomu">カクヨム</a></span>
                <span class="row-author">作者: <a href="https://webnovels.jp/search?q=author%3Afoo">作者名</a></span>
              </div>
              <div class="row-update">更新: 27分前 358話 ★1</div>
            </div>
          </div>
        </div>
        "#;
        let results = parse_search_results(html, Some("kakuyomu"));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "タイトル");
        assert_eq!(results[0].site_key, "kakuyomu");
        assert_eq!(results[0].author.as_deref(), Some("作者名"));
        assert_eq!(results[0].episode_count, Some(358));
        assert_eq!(results[0].tags, vec!["魔法"]);
    }

    #[test]
    fn parses_narou_legend_episode_parts() {
        let html = r#"
        <div class="list">
          <div class="row">
            <div class="row-right-block"><a href="https://webnovels.jp/narou/n3726bt" class="row-link-detail">作品詳細</a></div>
            <div class="row-title"><a href="https://ncode.syosetu.com/n3726bt/">レジェンド</a></div>
            <div class="row-summary">東北の田舎町に住んでいた佐伯玲二は夏休み中に事故によりその命を散らす。</div>
            <div class="row-info">
              <div class="row-detail">
                <span class="row-site">掲載: <a href="https://webnovels.jp/narou">小説家になろう</a></span>
                <span class="row-author">作者: <a href="https://webnovels.jp/search?q=author%3Afoo">神無月　紅</a></span>
              </div>
              <div class="row-update">更新: 22時間前 全4147部分 <span class="row-mylists">★19</span></div>
            </div>
          </div>
        </div>
        "#;
        let results = parse_search_results(html, Some("narou"));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "レジェンド");
        assert_eq!(results[0].site, "小説家になろう");
        assert_eq!(results[0].author.as_deref(), Some("神無月 紅"));
        assert!(
            results[0]
                .summary
                .as_deref()
                .unwrap_or_default()
                .contains("佐伯玲二")
        );
        assert_eq!(results[0].episode_count, Some(4147));
    }

    #[test]
    #[ignore = "hits webnovels.jp"]
    fn live_webnovels_search_finds_legend_metadata() {
        let response = search_webnovels("レジェンド", 30).expect("webnovels.jp search succeeds");
        let legend = response
            .results
            .iter()
            .find(|result| result.title == "レジェンド" && result.site_key == "narou")
            .expect("レジェンド on narou is present");
        assert_eq!(legend.site, "小説家になろう");
        assert!(
            legend
                .author
                .as_deref()
                .is_some_and(|author| !author.is_empty())
        );
        assert!(
            legend
                .summary
                .as_deref()
                .is_some_and(|summary| !summary.is_empty())
        );
        assert!(legend.episode_count.is_some_and(|count| count > 0));
    }

    #[test]
    #[ignore = "hits webnovels.jp"]
    fn live_webnovels_search_hits_every_builtin_site_flag() {
        let searcher = WebnovelsSearcher::new(DEFAULT_USER_AGENT).expect("searcher builds");
        runtime().expect("runtime builds").block_on(async {
            for site in builtin_webnovels_sites() {
                let results = searcher
                    .search_one_site("", &site.key, 1)
                    .await
                    .unwrap_or_else(|error| {
                        panic!("{} flag should be searchable: {error:#}", site.key)
                    });
                assert!(
                    !results.is_empty(),
                    "{} flag should return at least one result",
                    site.key
                );
                assert!(
                    results.iter().all(|result| result.site_key == site.key),
                    "{} flag returned a different site key: {:?}",
                    site.key,
                    results
                        .iter()
                        .map(|result| result.site_key.as_str())
                        .collect::<Vec<_>>()
                );
            }
        });
    }
}
