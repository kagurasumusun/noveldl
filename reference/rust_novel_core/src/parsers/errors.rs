use thiserror::Error;

#[derive(Debug, Error)]
pub enum ParserError {
    #[error("要素が見つかりませんでした: {selector}{context}")]
    SelectorNotFound { selector: String, context: String },
    #[error(
        "全てのセレクタで要素が見つかりませんでした: {selector_key}; tried={tried_selectors:?}"
    )]
    AllSelectorsFailed {
        selector_key: String,
        tried_selectors: Vec<String>,
    },
    #[error("パーサー設定ファイル読み込みエラー: {0}")]
    ConfigLoad(String),
    #[error(
        "サイト構造が変更された可能性があります: {url}; last selector={last_successful_selector}"
    )]
    StructureChanged {
        url: String,
        last_successful_selector: String,
    },
    #[error("JSON 解析エラー: {0}")]
    JsonParse(String),
}

impl ParserError {
    pub fn selector_not_found(selector: impl Into<String>, context: Option<&str>) -> Self {
        Self::SelectorNotFound {
            selector: selector.into(),
            context: context.map(|v| format!(" ({v})")).unwrap_or_default(),
        }
    }
}
