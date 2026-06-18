use anyhow::Result;
use serde_json::Value;
use std::sync::{Arc, OnceLock};
use wreq::Client;

pub struct NarouApi {
    client: Client,
    endpoint: String,
    runtime: Option<Arc<tokio::runtime::Runtime>>,
}

fn runtime() -> Result<&'static tokio::runtime::Runtime> {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    Ok(RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .thread_name("noveldl-api")
            .build()
            .expect("create NovelDL API runtime")
    }))
}

impl NarouApi {
    pub fn new(endpoint: impl Into<String>, user_agent: &str) -> Result<Self> {
        Ok(Self {
            client: Client::builder().user_agent(user_agent).build()?,
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
            client: Client::builder().user_agent(user_agent).build()?,
            endpoint: endpoint.into(),
            runtime: Some(runtime),
        })
    }

    pub fn fetch_json(&self, query: &[(&str, &str)]) -> Result<Value> {
        let fetch = async {
            let resp = self.client.get(&self.endpoint).query(query).send().await?;
            Ok(resp.error_for_status()?.json().await?)
        };
        if let Some(runtime) = &self.runtime {
            runtime.block_on(fetch)
        } else {
            runtime()?.block_on(fetch)
        }
    }
}
