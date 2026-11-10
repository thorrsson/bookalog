use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, AeadCore, OsRng, Payload},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::Manager;
use tauri_plugin_dialog::DialogExt;

pub mod backend;
pub mod exchange;

const FIXTURE: &str = include_str!("../../../fixtures/generated/catalog.json");
const COLUMNS: [&str; 7] = [
    "id",
    "work_id",
    "title",
    "format",
    "isbn13",
    "publication_status",
    "release_date",
];
const ACCOUNT: &[u8] = b"synthetic-comparison";

#[derive(Serialize, Deserialize)]
struct Envelope {
    nonce: String,
    ciphertext: String,
}

fn encrypt(plaintext: &[u8], key: &[u8]) -> Result<String, String> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|e| e.to_string())?;
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: plaintext,
                aad: ACCOUNT,
            },
        )
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&Envelope {
        nonce: STANDARD.encode(nonce),
        ciphertext: STANDARD.encode(ciphertext),
    })
    .map_err(|e| e.to_string())
}

fn decrypt(envelope: &str, key: &[u8]) -> Result<Vec<u8>, String> {
    let value: Envelope = serde_json::from_str(envelope).map_err(|e| e.to_string())?;
    let nonce = STANDARD.decode(value.nonce).map_err(|e| e.to_string())?;
    if nonce.len() != 12 {
        return Err("Invalid cache nonce.".into());
    }
    let ciphertext = STANDARD
        .decode(value.ciphertext)
        .map_err(|e| e.to_string())?;
    Aes256Gcm::new_from_slice(key)
        .map_err(|e| e.to_string())?
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: ACCOUNT,
            },
        )
        .map_err(|e| e.to_string())
}

fn current_time() -> Result<u64, String> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs())
}

fn lease_valid(
    verified_at: u64,
    now: u64,
    last_seen: u64,
    account_matches: bool,
    revoked: bool,
) -> bool {
    account_matches
        && !revoked
        && last_seen >= verified_at
        && now >= last_seen
        && now.saturating_sub(verified_at) < 86400
}

#[cfg(any(target_os = "macos", target_os = "ios", target_os = "windows"))]
fn protected_key(create: bool) -> Result<Vec<u8>, String> {
    let entry = keyring::Entry::new("com.bookalog.spike.tauri", "synthetic-cache-key")
        .map_err(|e| e.to_string())?;
    match entry.get_secret() {
        Ok(key) => Ok(key),
        Err(keyring::Error::NoEntry) if create => {
            let key = Aes256Gcm::generate_key(&mut OsRng).to_vec();
            entry.set_secret(&key).map_err(|e| e.to_string())?;
            Ok(key)
        }
        Err(error) => Err(format!("OS-protected cache key unavailable: {error}")),
    }
}

#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "windows")))]
fn protected_key(_create: bool) -> Result<Vec<u8>, String> {
    Err(
        "This spike has no verified OS key-store adapter on this platform. Cache is disabled."
            .into(),
    )
}

#[tauri::command]
fn fixture() -> String {
    FIXTURE.into()
}

fn csv_projection(source: &str) -> Result<Vec<u8>, String> {
    let data: Value = serde_json::from_str(source).map_err(|e| e.to_string())?;
    let rows = data["editions"].as_array().ok_or("Missing editions.")?;
    let mut writer = csv::Writer::from_writer(Vec::new());
    writer.write_record(COLUMNS).map_err(|e| e.to_string())?;
    for row in rows {
        let fields = COLUMNS.map(|column| {
            let value = row[column].as_str().unwrap_or("");
            if value.trim_start().starts_with(['=', '+', '-', '@']) {
                format!("'{value}")
            } else {
                value.to_owned()
            }
        });
        writer.write_record(fields).map_err(|e| e.to_string())?;
    }
    writer.into_inner().map_err(|e| e.to_string())
}

fn preview_csv(bytes: &[u8]) -> Result<usize, String> {
    let mut reader = csv::Reader::from_reader(bytes);
    if reader
        .headers()
        .map_err(|e| e.to_string())?
        .iter()
        .ne(COLUMNS)
    {
        return Err("Expected the seven comparison CSV columns.".into());
    }
    reader.records().try_fold(0, |count, record| {
        record.map(|_| count + 1).map_err(|e| e.to_string())
    })
}

#[tauri::command]
async fn preview_file(app: tauri::AppHandle) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(file) = app
            .dialog()
            .file()
            .add_filter("Comparison exchange", &["csv", "xlsx", "xml"])
            .blocking_pick_file()
        else {
            return Ok("File selection canceled.".into());
        };
        let path = file
            .into_path()
            .map_err(|_| "This file-provider URI needs a platform adapter; no data was read.")?;
        if std::fs::metadata(&path).map_err(|e| e.to_string())?.len() > 8 * 1024 * 1024 {
            return Err("The spike accepts files up to 8 MiB.".into());
        }
        let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
        let extension = path.extension().and_then(|value| value.to_str()).unwrap_or("").to_ascii_lowercase();
        let count = match extension.as_str() {
            "csv" => preview_csv(&bytes)?,
            "xlsx" => exchange::preview_xlsx(&bytes)?,
            "xml" => exchange::preview_onix(&bytes)?,
            _ => return Err("Choose a CSV, XLSX, or illustrative ONIX XML file.".into()),
        };
        Ok(format!(
            "{count} {extension} records previewed. No catalog changes applied; comparison profile only."
        ))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn export_file(app: tauri::AppHandle, format: Option<String>) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let format = format.as_deref().unwrap_or("csv");
        let data: Value = serde_json::from_str(FIXTURE).map_err(|error| error.to_string())?;
        let rows = data["editions"].as_array().ok_or("Missing editions.")?;
        let bytes = match format {
            "csv" => csv_projection(FIXTURE)?,
            "xlsx" => exchange::xlsx_projection(rows)?,
            "xml" => exchange::onix_projection(rows)?,
            _ => return Err("Unsupported comparison export format.".into()),
        };
        let Some(file) = app
            .dialog()
            .file()
            .set_file_name(format!("synthetic-catalog.{format}"))
            .blocking_save_file()
        else {
            return Ok("Export canceled.".into());
        };
        let path = file
            .into_path()
            .map_err(|_| "This export URI needs a platform save/share adapter.")?;
        std::fs::write(path, bytes).map_err(|e| e.to_string())?;
        Ok(format!("Exported the synthetic {format} projection. Not a complete catalog interchange or recipient-certified ONIX feed."))
    })
    .await
    .map_err(|e| e.to_string())?
}

fn write_cache_file(file: &std::path::Path, value: &str) -> Result<(), String> {
    let temporary = file.with_extension("tmp");
    std::fs::write(&temporary, value).map_err(|e| e.to_string())?;
    std::fs::rename(temporary, file).map_err(|e| e.to_string())
}

#[tauri::command]
async fn save_cache(app: tauri::AppHandle) -> Result<String, String> {
    let directory = app.path().app_data_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let now = current_time()?;
    let value = serde_json::json!({ "savedAt": now, "lastSeenAt": now, "catalog": FIXTURE });
    let encrypted = encrypt(value.to_string().as_bytes(), &protected_key(true)?)?;
    write_cache_file(&directory.join("synthetic-cache.enc"), &encrypted)?;
    Ok("Encrypted synthetic snapshot saved with an OS-protected key. No membership verification performed.".into())
}

#[tauri::command]
async fn read_cache(app: tauri::AppHandle) -> Result<String, String> {
    let file = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("synthetic-cache.enc");
    let key = protected_key(false)?;
    let plaintext = decrypt(
        &std::fs::read_to_string(&file).map_err(|e| e.to_string())?,
        &key,
    )?;
    let mut value: Value = serde_json::from_slice(&plaintext).map_err(|e| e.to_string())?;
    let saved = value["savedAt"]
        .as_u64()
        .ok_or("Missing cache timestamp.")?;
    let last_seen = value["lastSeenAt"].as_u64().ok_or("Missing cache clock.")?;
    let now = current_time()?;
    if !lease_valid(saved, now, last_seen, true, false) {
        return Err("The test cache expired or the clock moved backward.".into());
    }
    let source = value["catalog"]
        .as_str()
        .ok_or("Missing cached catalog.")?
        .to_owned();
    value["lastSeenAt"] = now.into();
    write_cache_file(&file, &encrypt(value.to_string().as_bytes(), &key)?)?;
    Ok(source)
}

#[tauri::command]
async fn clear_cache(app: tauri::AppHandle) -> Result<String, String> {
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "windows"))]
    {
        let entry = keyring::Entry::new("com.bookalog.spike.tauri", "synthetic-cache-key")
            .map_err(|e| e.to_string())?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => (),
            Err(error) => return Err(format!("Could not clear the OS cache key: {error}")),
        }
    }
    let directory = app.path().app_data_dir().map_err(|e| e.to_string())?;
    for name in ["synthetic-cache.enc", "synthetic-cache.tmp"] {
        match std::fs::remove_file(directory.join(name)) {
            Ok(()) => (),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(format!("Could not clear the synthetic cache: {error}")),
        }
    }
    Ok("Synthetic cache and its key cleared.".into())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            fixture,
            preview_file,
            export_file,
            save_cache,
            read_cache,
            clear_cache,
            backend::load_backend,
            backend::save_backend_title
        ])
        .run(tauri::generate_context!())
        .expect("Tauri comparison startup failed");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixtures_and_csv_preserve_records() {
        let data: Value = serde_json::from_str(FIXTURE).unwrap();
        assert_eq!(data["editions"].as_array().unwrap().len(), 5000);
        assert_eq!(data["editions"][2]["release_date"], "2030-02");
        let csv = csv_projection(FIXTURE).unwrap();
        assert_eq!(preview_csv(&csv).unwrap(), 5000);
        assert!(String::from_utf8(csv).unwrap().contains("'=Synthetic"));
        assert!(preview_csv(b"wrong,columns\nx,y").is_err());
    }
    #[test]
    fn encryption_detects_wrong_keys_and_tampering() {
        let key = Aes256Gcm::generate_key(&mut OsRng);
        let sealed = encrypt(FIXTURE.as_bytes(), &key).unwrap();
        assert!(!sealed.contains("Synthetic Atlas"));
        assert_eq!(decrypt(&sealed, &key).unwrap(), FIXTURE.as_bytes());
        assert!(decrypt(&sealed, &[0; 32]).is_err());
        let mut envelope: Envelope = serde_json::from_str(&sealed).unwrap();
        let mut ciphertext = STANDARD.decode(&envelope.ciphertext).unwrap();
        ciphertext[0] ^= 1;
        envelope.ciphertext = STANDARD.encode(ciphertext);
        assert!(decrypt(&serde_json::to_string(&envelope).unwrap(), &key).is_err());
    }
    #[test]
    fn offline_policy_is_fixed_to_verification_and_fails_closed() {
        assert!(lease_valid(100, 86499, 100, true, false));
        assert!(!lease_valid(100, 86500, 100, true, false));
        assert!(!lease_valid(100, 86501, 100, true, false));
        assert!(!lease_valid(100, 99, 100, true, false));
        assert!(!lease_valid(100, 101, 102, true, false));
        assert!(!lease_valid(100, 101, 100, false, false));
        assert!(!lease_valid(100, 101, 100, true, true));

        let last_read = 100 + 60 * 60;
        assert!(lease_valid(100, last_read, last_read, true, false));
        assert!(!lease_valid(100, 86500, last_read, true, false));
    }
}
