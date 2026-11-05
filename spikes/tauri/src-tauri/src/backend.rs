use reqwest::{Client, Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::HashSet, time::Duration};

#[cfg(test)]
mod tests;

#[derive(Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Postgrest,
    Gateway,
}

#[derive(Clone, Deserialize)]
pub struct BackendConfig {
    pub provider: Provider,
    pub base_url: String,
    pub access_token: String,
    pub api_key: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct BackendError {
    pub status: u16,
    pub message: String,
}

impl BackendError {
    fn new(status: u16, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}

#[derive(Serialize)]
pub struct Catalog {
    pub role: String,
    pub editions: Vec<Value>,
}

pub struct Backend {
    config: BackendConfig,
    base: Url,
    client: Client,
}

impl Backend {
    pub fn new(config: BackendConfig) -> Result<Self, BackendError> {
        let mut base = Url::parse(&config.base_url)
            .map_err(|_| BackendError::new(0, "Invalid backend URL."))?;
        let local = matches!(base.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
        if !(base.scheme() == "https" || base.scheme() == "http" && local)
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
        {
            return Err(BackendError::new(
                0,
                "Use HTTPS, or HTTP on localhost, without embedded credentials or query parameters.",
            ));
        }
        if config.access_token.trim().is_empty() {
            return Err(BackendError::new(401, "An access token is required."));
        }
        let path = format!("{}/", base.path().trim_end_matches('/'));
        base.set_path(&path);
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| BackendError::new(0, "Could not initialize the HTTP client."))?;
        Ok(Self {
            config,
            base,
            client,
        })
    }

    async fn request(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, BackendError> {
        let url = self
            .base
            .join(path)
            .map_err(|_| BackendError::new(0, "Invalid operation URL."))?;
        let mut request = self
            .client
            .request(method, url)
            .bearer_auth(&self.config.access_token);
        if let Some(key) = &self.config.api_key {
            request = request.header("apikey", key);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        let mut response = request.send().await.map_err(|_| {
            BackendError::new(
                0,
                "The backend could not be reached. Check the URL and connection.",
            )
        })?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            let message = match status {
                401 => "Authentication failed. Obtain a fresh test access token.",
                403 => "The account or role is not permitted to perform this operation.",
                409 => "This edition changed. Reload and compare your draft.",
                _ => "The backend rejected the operation.",
            };
            return Err(BackendError::new(status, message));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| BackendError::new(0, "The backend response was interrupted."))?
        {
            if bytes.len() + chunk.len() > 16 * 1024 * 1024 {
                return Err(BackendError::new(
                    0,
                    "The response exceeds the comparison's 16 MiB limit.",
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| BackendError::new(0, "The backend returned invalid JSON."))
    }

    async fn membership(&self) -> Result<String, BackendError> {
        let value = match self.config.provider {
            Provider::Postgrest => {
                self.request(Method::GET, "rpc/current_catalog_role", None)
                    .await?
            }
            Provider::Gateway => {
                self.request(Method::GET, "membership", None).await?["role"].clone()
            }
        };
        match value.as_str() {
            Some(role @ ("viewer" | "editor" | "administrator")) => Ok(role.to_owned()),
            _ => Err(BackendError::new(
                403,
                "An active catalog membership is required.",
            )),
        }
    }

    pub async fn load(&self) -> Result<Catalog, BackendError> {
        let started = std::time::Instant::now();
        self.membership().await?;
        let mut editions = Vec::new();
        let mut page_ids = HashSet::new();
        match self.config.provider {
            Provider::Gateway => {
                let value = self.request(Method::GET, "editions", None).await?;
                editions = value["editions"]
                    .as_array()
                    .ok_or_else(|| BackendError::new(0, "Missing editions array."))?
                    .clone();
            }
            Provider::Postgrest => loop {
                if started.elapsed() > Duration::from_secs(60) {
                    return Err(BackendError::new(
                        0,
                        "Catalog pagination took too long. Reconnect and retry.",
                    ));
                }
                let value = self
                    .request(
                        Method::GET,
                        &format!(
                            "editions?select=record&order=id&offset={}&limit=500",
                            editions.len()
                        ),
                        None,
                    )
                    .await?;
                let page = value
                    .as_array()
                    .ok_or_else(|| BackendError::new(0, "Invalid catalog page."))?;
                if page.is_empty() {
                    break;
                }
                for row in page {
                    let record = row
                        .get("record")
                        .ok_or_else(|| BackendError::new(0, "Missing edition record."))?;
                    let id = record["id"]
                        .as_str()
                        .ok_or_else(|| BackendError::new(0, "Invalid edition identifier."))?;
                    if !page_ids.insert(id.to_owned()) {
                        return Err(BackendError::new(
                            0,
                            "Duplicate records across pages. Reload the catalog.",
                        ));
                    }
                    editions.push(record.clone());
                }
                if editions.len() > 10_000 {
                    return Err(BackendError::new(
                        0,
                        "Catalog exceeds the comparison's 10,000-record safety limit.",
                    ));
                }
            },
        }
        if editions.len() > 10_000 {
            return Err(BackendError::new(
                0,
                "Catalog exceeds the comparison record limit.",
            ));
        }
        let mut ids = HashSet::new();
        for row in &editions {
            let id = row["id"]
                .as_str()
                .ok_or_else(|| BackendError::new(0, "Invalid edition identifier."))?;
            if !ids.insert(id) {
                return Err(BackendError::new(
                    0,
                    "Duplicate records across pages. Reload the catalog.",
                ));
            }
            if row["title"].as_str().is_none() || row["revision"].as_u64().unwrap_or(0) == 0 {
                return Err(BackendError::new(0, "Invalid edition title or revision."));
            }
        }
        Ok(Catalog {
            role: self.membership().await?,
            editions,
        })
    }

    pub async fn save_title(
        &self,
        id: &str,
        revision: u64,
        title: &str,
    ) -> Result<Value, BackendError> {
        if id.len() != 36 || !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') || revision == 0
        {
            return Err(BackendError::new(
                400,
                "Invalid edition identifier or revision.",
            ));
        }
        let result = match self.config.provider {
            Provider::Postgrest => self.request(Method::POST, "rpc/update_edition_title",
                Some(json!({ "edition_id": id, "expected_revision": revision, "new_title": title }))).await?,
            Provider::Gateway => self.request(Method::PATCH, &format!("editions/{id}"),
                Some(json!({ "expected_revision": revision, "title": title }))).await?["edition"].clone(),
        };
        if result["id"] != id || result["revision"].as_u64() != revision.checked_add(1) {
            return Err(BackendError::new(
                0,
                "The save response could not be confirmed. Reload before retrying.",
            ));
        }
        Ok(result)
    }
}

#[tauri::command]
pub async fn load_backend(config: BackendConfig) -> Result<Catalog, BackendError> {
    Backend::new(config)?.load().await
}

#[tauri::command]
pub async fn save_backend_title(
    config: BackendConfig,
    id: String,
    revision: u64,
    title: String,
) -> Result<Value, BackendError> {
    Backend::new(config)?
        .save_title(&id, revision, &title)
        .await
}
