use serde::Deserialize;
use spikestauri_lib::backend::{Backend, BackendConfig, Provider};
use spikestauri_lib::exchange::{onix_projection, xlsx_projection};

#[derive(Deserialize)]
struct Case {
    provider: Provider,
    base_url: String,
    editor_token: String,
    viewer_token: String,
    unapproved_token: String,
}

fn main() {
    tauri::async_runtime::block_on(async {
        let cases: Vec<Case> = serde_json::from_str(
            &std::env::var("BOOKALOG_MATRIX_CASES").expect("Use script/test-matrix.sh"),
        )
        .unwrap();
        for case in cases {
            let connect = |token: &str| {
                Backend::new(BackendConfig {
                    provider: case.provider.clone(),
                    base_url: case.base_url.clone(),
                    access_token: token.to_owned(),
                    api_key: None,
                })
                .unwrap()
            };
            let viewer = connect(&case.viewer_token);
            let catalog = viewer.load().await.expect("Viewer catalog request failed");
            assert_eq!(catalog.role, "viewer");
            assert_eq!(catalog.editions.len(), 5000);
            let record = &catalog.editions[0];
            let id = record["id"].as_str().unwrap();
            let revision = record["revision"].as_u64().unwrap();
            assert_eq!(
                viewer
                    .save_title(id, revision, "Denied Rust edit")
                    .await
                    .unwrap_err()
                    .status,
                403
            );
            assert_eq!(
                connect("invalid-test-token")
                    .load()
                    .await
                    .err()
                    .unwrap()
                    .status,
                401
            );
            assert_eq!(
                connect(&case.unapproved_token)
                    .load()
                    .await
                    .err()
                    .unwrap()
                    .status,
                403
            );
            let editor = connect(&case.editor_token);
            let updated = editor
                .save_title(id, revision, "Rust matrix title")
                .await
                .unwrap();
            assert_eq!(updated["title"], "Rust matrix title");
            assert_eq!(
                editor
                    .save_title(id, revision, "Stale Rust edit")
                    .await
                    .unwrap_err()
                    .status,
                409
            );
        }
        if let Ok(directory) = std::env::var("BOOKALOG_MATRIX_OUTPUT_DIR") {
            let fixture: serde_json::Value =
                serde_json::from_str(include_str!("../../../fixtures/generated/catalog.json"))
                    .unwrap();
            let rows = fixture["editions"].as_array().unwrap();
            std::fs::write(
                std::path::Path::new(&directory).join("rust.xlsx"),
                xlsx_projection(rows).unwrap(),
            )
            .unwrap();
            std::fs::write(
                std::path::Path::new(&directory).join("rust.xml"),
                onix_projection(rows).unwrap(),
            )
            .unwrap();
        }
        println!("Rust: both backend paths passed list, membership, editing, and conflict checks.");
    });
}
