use thiserror::Error;

#[derive(Debug, Error)]
pub enum DownloaderError {
    #[error("invalid target")]
    InvalidTarget,
    #[error("download suspended")]
    SuspendDownload,
    #[error("rate limited")]
    RateLimited,
    #[error("404 not found")]
    NotFound,
    #[error("force redirect")]
    ForceRedirect,
    #[error("javascript challenge detected")]
    JavaScriptChallenge,
}
