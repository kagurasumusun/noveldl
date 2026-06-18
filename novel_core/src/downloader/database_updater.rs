use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Record {
    pub id: String,
    pub author: String,
    pub title: String,
    pub file_title: String,
    pub toc_url: String,
    pub sitename: String,
    pub novel_type: String,
    pub end: Option<bool>,
    pub last_update: DateTime<Utc>,
    pub new_arrivals_date: Option<DateTime<Utc>>,
    pub use_subdirectory: bool,
    pub general_firstup: Option<String>,
    pub novelupdated_at: Option<String>,
    pub general_lastup: Option<String>,
    pub length: Option<String>,
    pub suspend: bool,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InMemoryDatabase {
    pub records: BTreeMap<String, Record>,
}

impl InMemoryDatabase {
    pub fn update_record(&mut self, record: Record) {
        self.records.insert(record.id.clone(), record);
    }
    pub fn get_record(&self, id: &str) -> Option<&Record> {
        self.records.get(id)
    }
}
