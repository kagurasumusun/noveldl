use anyhow::Result;

#[derive(Debug, Clone)]
pub struct Chapter {
    pub index: String,
    pub href: String,
    pub subtitle: String,
    pub chapter: Option<String>,
    pub subupdate: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ParsedToc {
    pub title: Option<String>,
    pub author: Option<String>,
    pub story: Option<String>,
    pub chapters: Vec<Chapter>,
}

#[derive(Debug, Clone)]
pub struct ParsedSection {
    pub body: String,
    pub introduction: Option<String>,
    pub postscript: Option<String>,
}

pub trait WebNovelParser {
    fn parse_toc(&self, html: &str) -> Result<ParsedToc>;

    /// Return additional TOC page hrefs discovered from this page.
    ///
    /// Implementations may return a single next link, all numbered page links,
    /// or generated page URLs depending on site-specific YAML rules.  The
    /// downloader de-duplicates and schedules these hrefs in order.
    fn parse_toc_page_hrefs(&self, html: &str) -> Result<Vec<String>> {
        Ok(self.parse_toc_next_page_href(html)?.into_iter().collect())
    }

    fn parse_toc_next_page_href(&self, _html: &str) -> Result<Option<String>> {
        Ok(None)
    }
    fn parse_section(&self, html: &str) -> Result<ParsedSection>;
}
