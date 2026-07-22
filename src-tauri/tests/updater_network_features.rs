use std::process::Command;

#[test]
fn updater_http_client_supports_system_proxy_discovery() {
    let output = Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--locked"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("cargo metadata should run");

    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("cargo metadata should return JSON");
    let reqwest_features = metadata["resolve"]["nodes"]
        .as_array()
        .expect("resolved dependency nodes should exist")
        .iter()
        .find(|node| {
            node["id"]
                .as_str()
                .is_some_and(|id| id.contains("reqwest@0.13."))
        })
        .and_then(|node| node["features"].as_array())
        .expect("reqwest 0.13 should be resolved");

    assert!(
        reqwest_features
            .iter()
            .any(|feature| feature.as_str() == Some("system-proxy")),
        "the updater HTTP client must keep Reqwest's system-proxy feature enabled"
    );
}
