use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NovelInfo {
    pub title: Option<String>,
    pub writer: Option<String>,
    pub story: Option<String>,
    pub novel_type: Option<String>,
    pub general_all_no: Option<String>,
    pub sitename: Option<String>,
}

impl NovelInfo {
    pub fn from_pairs(pairs: &[(String, String)]) -> Result<Self> {
        let mut info = Self::default();
        for (k, v) in pairs {
            match k.as_str() {
                "title" => info.title = Some(v.clone()),
                "writer" => info.writer = Some(v.clone()),
                "story" => info.story = Some(v.clone()),
                "novel_type" => info.novel_type = Some(v.clone()),
                "general_all_no" => info.general_all_no = Some(v.clone()),
                "sitename" => info.sitename = Some(v.clone()),
                _ => {}
            }
        }
        Ok(info)
    }
}
