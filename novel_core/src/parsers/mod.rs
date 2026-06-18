pub mod base;
pub mod errors;
pub mod hameln;
pub mod kakuyomu;
pub mod legacy_compat;
pub mod narou;
pub mod nokogiri_compat;
pub mod novelupplus;

pub use base::{Chapter, ParsedSection, ParsedToc, WebNovelParser};
