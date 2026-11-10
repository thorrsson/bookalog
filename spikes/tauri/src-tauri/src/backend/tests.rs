use super::*;
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::Mutex,
    thread,
    time::Instant,
};

static HTTP_STUB_LOCK: Mutex<()> = Mutex::new(());

fn config(url: &str) -> BackendConfig {
    BackendConfig {
        provider: Provider::Postgrest,
        base_url: url.into(),
        access_token: "test-token".into(),
        api_key: None,
    }
}

fn load_responses(responses: Vec<(u16, Value)>) -> Result<Catalog, BackendError> {
    let _guard = HTTP_STUB_LOCK.lock().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    listener.set_nonblocking(true).unwrap();
    let server = thread::spawn(move || {
        for (status, response) in responses {
            let start = Instant::now();
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(
                            start.elapsed() < Duration::from_secs(5),
                            "Client stopped requesting expected pages"
                        );
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("Test server failed: {error}"),
                }
            };
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut header = Vec::new();
            let mut byte = [0];
            while !header.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                header.push(byte[0]);
                assert!(header.len() < 8192);
            }
            let body = response.to_string();
            write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        }
    });
    let result =
        tauri::async_runtime::block_on(async { Backend::new(config(&url)).unwrap().load().await });
    server.join().unwrap();
    result
}

fn row(id: &str) -> Value {
    json!({ "record": { "id": id, "title": "Synthetic", "revision": 1 } })
}

#[test]
fn credentials_and_transport_are_validated() {
    for url in [
        "http://catalog.invalid",
        "https://user:pass@catalog.invalid",
        "https://catalog.invalid?x=1",
    ] {
        assert!(Backend::new(config(url)).is_err());
    }
    let mut empty = config("https://catalog.invalid");
    empty.access_token.clear();
    assert_eq!(Backend::new(empty).err().unwrap().status, 401);
    assert!(Backend::new(config("http://[::1]:8000")).is_ok());
}

#[test]
fn short_pages_are_followed_until_empty() {
    let result = load_responses(vec![
        (200, json!("viewer")),
        (200, json!([row("first")])),
        (200, json!([row("second")])),
        (200, json!([])),
        (200, json!("viewer")),
    ])
    .unwrap();
    assert_eq!(result.editions.len(), 2);
}

#[test]
fn failures_and_redirects_do_not_return_partial_catalogs() {
    for status in [503, 307] {
        let result = load_responses(vec![
            (200, json!("viewer")),
            (200, json!([row("first")])),
            (status, json!({})),
        ]);
        assert_eq!(result.err().unwrap().status, status);
    }
}

#[test]
fn duplicate_pages_are_rejected_immediately() {
    let result = load_responses(vec![
        (200, json!("viewer")),
        (200, json!([row("first")])),
        (200, json!([row("first")])),
    ]);
    assert!(result.err().unwrap().message.contains("Duplicate"));
}

#[test]
fn revocation_during_pagination_discards_results() {
    let result = load_responses(vec![
        (200, json!("viewer")),
        (200, json!([])),
        (200, Value::Null),
    ]);
    assert_eq!(result.err().unwrap().status, 403);
}
