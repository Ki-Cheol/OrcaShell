// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use miette::{IntoDiagnostic, Result, WrapErr};

pub fn kind_cluster_name(gateway_name: &str) -> String {
    format!("orcashell-{gateway_name}")
}

pub fn kind_cluster_exists(cluster_name: &str) -> bool {
    std::process::Command::new("kind")
        .args(["get", "clusters"])
        .output()
        .map(|out| {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .any(|l| l.trim() == cluster_name)
        })
        .unwrap_or(false)
}

/// Create a kind cluster named `orcashell-{gateway_name}` using the given config file.
/// Idempotent: does nothing if the cluster already exists.
pub fn ensure_kind_cluster(gateway_name: &str, kind_config_path: &str) -> Result<()> {
    let cluster_name = kind_cluster_name(gateway_name);
    if kind_cluster_exists(&cluster_name) {
        tracing::info!("kind cluster '{cluster_name}' already exists, reusing");
        return Ok(());
    }
    tracing::info!("creating kind cluster '{cluster_name}' with config {kind_config_path}");
    let status = std::process::Command::new("kind")
        .args([
            "create",
            "cluster",
            "--name",
            &cluster_name,
            "--config",
            kind_config_path,
        ])
        .status()
        .into_diagnostic()
        .wrap_err("failed to run `kind create cluster` — is kind installed?")?;
    if !status.success() {
        return Err(miette::miette!(
            "`kind create cluster` failed with exit code {:?}",
            status.code()
        ));
    }
    Ok(())
}

/// Delete the kind cluster for this gateway. No-op if it does not exist.
pub fn destroy_kind_cluster(gateway_name: &str) -> Result<()> {
    let cluster_name = kind_cluster_name(gateway_name);
    if !kind_cluster_exists(&cluster_name) {
        return Ok(());
    }
    let status = std::process::Command::new("kind")
        .args(["delete", "cluster", "--name", &cluster_name])
        .status()
        .into_diagnostic()
        .wrap_err("failed to run `kind delete cluster`")?;
    if !status.success() {
        return Err(miette::miette!(
            "`kind delete cluster` failed with exit code {:?}",
            status.code()
        ));
    }
    Ok(())
}

/// Deploy (or upgrade) the OpenShell Gateway Helm chart on the kind cluster.
/// Runs: helm upgrade --install openshell <chart_path> -n openshell --create-namespace
pub fn deploy_helm_gateway(
    gateway_name: &str,
    chart_path: &str,
    gateway_port: u16,
    disable_tls: bool,
    disable_auth: bool,
) -> Result<()> {
    let cluster_name = kind_cluster_name(gateway_name);
    let kubeconfig = kind_kubeconfig(&cluster_name);

    let mut cmd = std::process::Command::new("helm");
    cmd.args([
        "upgrade",
        "--install",
        "openshell",
        chart_path,
        "-n",
        "openshell",
        "--create-namespace",
        // Allow scheduling on control-plane nodes (single-node kind clusters
        // have a NoSchedule taint on the control-plane by default).
        "--set",
        "tolerations[0].key=node-role.kubernetes.io/control-plane",
        "--set",
        "tolerations[0].effect=NoSchedule",
        "--set",
        "tolerations[0].operator=Exists",
    ]);
    if disable_tls {
        cmd.arg("--set").arg("tls.enabled=false");
    }
    if disable_auth {
        cmd.arg("--set").arg("auth.enabled=false");
    }
    cmd.env("KUBECONFIG", &kubeconfig);

    let status = cmd
        .status()
        .into_diagnostic()
        .wrap_err("failed to run `helm upgrade --install` — is helm installed?")?;
    if !status.success() {
        return Err(miette::miette!("`helm upgrade --install openshell` failed"));
    }
    Ok(())
}

/// Wait for the OpenShell gateway pod to reach Ready state in the kind cluster.
pub fn wait_for_kind_gateway_ready<F>(gateway_name: &str, mut on_log: F) -> Result<()>
where
    F: FnMut(String),
{
    let cluster_name = kind_cluster_name(gateway_name);
    let kubeconfig = kind_kubeconfig(&cluster_name);
    on_log("[status] Waiting for gateway pod to be ready (kind cluster)".to_string());
    let status = std::process::Command::new("kubectl")
        .args([
            "wait",
            "--for=condition=ready",
            "pod",
            "-l",
            "app.kubernetes.io/name=openshell",
            "-n",
            "openshell",
            "--timeout=300s",
        ])
        .env("KUBECONFIG", &kubeconfig)
        .status()
        .into_diagnostic()
        .wrap_err("failed to run `kubectl wait`")?;
    if !status.success() {
        return Err(miette::miette!(
            "gateway pod did not become ready within 300s in kind cluster '{cluster_name}'"
        ));
    }
    Ok(())
}

/// Returns the kubeconfig path kind writes when creating a cluster.
/// kind merges the cluster context into the default kubeconfig at $HOME/.kube/config.
pub fn kind_kubeconfig(_cluster_name: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    format!("{home}/.kube/config")
}

/// Run kubectl on the host using the kind cluster's kubeconfig.
/// Returns (stdout, stderr, exit_code) separately to avoid corrupting binary/base64 output.
pub fn run_kubectl_split(gateway_name: &str, args: &[&str]) -> Result<(String, String, i32)> {
    let cluster_name = kind_cluster_name(gateway_name);
    let kubeconfig = kind_kubeconfig(&cluster_name);
    let output = std::process::Command::new("kubectl")
        .args(args)
        .env("KUBECONFIG", &kubeconfig)
        .output()
        .into_diagnostic()
        .wrap_err("failed to run kubectl")?;
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let code = output.status.code().unwrap_or(-1);
    Ok((stdout, stderr, code))
}

/// Run kubectl on the host using the kind cluster's kubeconfig.
/// Returns (stdout+stderr combined, exit_code). Use run_kubectl_split when output must be clean.
pub fn run_kubectl(gateway_name: &str, args: &[&str]) -> Result<(String, i32)> {
    let (stdout, stderr, code) = run_kubectl_split(gateway_name, args)?;
    Ok((format!("{stdout}{stderr}"), code))
}

/// Check whether the openshell StatefulSet or Deployment exists in the kind cluster.
pub fn kind_workload_exists(gateway_name: &str) -> bool {
    let (_, ss_code) = run_kubectl(
        gateway_name,
        &[
            "get", "statefulset/openshell", "-n", "openshell",
            "-o", "name", "--ignore-not-found",
        ],
    )
    .unwrap_or_default();
    if ss_code == 0 {
        return true;
    }
    let (_, dep_code) = run_kubectl(
        gateway_name,
        &[
            "get", "deployment/openshell", "-n", "openshell",
            "-o", "name", "--ignore-not-found",
        ],
    )
    .unwrap_or_default();
    dep_code == 0
}

/// Wait up to `timeout_secs` for a namespace to exist in the kind cluster.
pub fn kind_wait_for_namespace(
    gateway_name: &str,
    namespace: &str,
    timeout_secs: u64,
) -> Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
    loop {
        let (_, code) = run_kubectl(
            gateway_name,
            &["get", "namespace", namespace, "--ignore-not-found"],
        )?;
        if code == 0 {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err(miette::miette!(
                "timed out waiting for namespace '{namespace}' in kind cluster"
            ));
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
}

/// Apply a k8s manifest (JSON string) via `kubectl apply -f -` in the kind cluster.
pub fn kind_apply_manifest(gateway_name: &str, manifest_json: &str) -> Result<()> {
    let cluster_name = kind_cluster_name(gateway_name);
    let kubeconfig = kind_kubeconfig(&cluster_name);
    let mut child = std::process::Command::new("kubectl")
        .args(["apply", "-f", "-"])
        .env("KUBECONFIG", &kubeconfig)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .into_diagnostic()
        .wrap_err("failed to spawn kubectl apply")?;
    if let Some(stdin) = child.stdin.take() {
        use std::io::Write;
        let mut stdin = stdin;
        stdin
            .write_all(manifest_json.as_bytes())
            .into_diagnostic()
            .wrap_err("failed to write manifest to kubectl stdin")?;
    }
    let output = child
        .wait_with_output()
        .into_diagnostic()
        .wrap_err("kubectl apply failed")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(miette::miette!("kubectl apply failed: {stderr}"));
    }
    Ok(())
}

/// Read a single key from a k8s Secret (base64-decoded) in the kind cluster.
/// Returns an error string if the secret or key is missing.
pub fn kind_get_secret_key(
    gateway_name: &str,
    secret_name: &str,
    namespace: &str,
    key: &str,
) -> std::result::Result<String, String> {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    let jsonpath = format!("{{.data.{}}}", key.replace('.', "\\."));
    // Use split stdout/stderr so kubectl warnings don't corrupt the base64 output.
    let (stdout, _stderr, code) = run_kubectl_split(
        gateway_name,
        &[
            "get", "secret", secret_name,
            "-n", namespace,
            "-o", &format!("jsonpath={jsonpath}"),
        ],
    )
    .map_err(|e| format!("kubectl exec failed: {e}"))?;
    if code != 0 || stdout.trim().is_empty() {
        return Err(format!("secret {secret_name} key {key} not found"));
    }
    let decoded = STANDARD
        .decode(stdout.trim())
        .map_err(|e| format!("base64 decode error for {secret_name}/{key}: {e}"))?;
    String::from_utf8(decoded)
        .map_err(|e| format!("non-UTF8 data in {secret_name}/{key}: {e}"))
}

/// Restart the openshell workload (StatefulSet or Deployment) in the kind cluster.
pub fn kind_restart_workload(gateway_name: &str, workload_ref: &str) -> Result<()> {
    let (_, code) =
        run_kubectl(gateway_name, &["rollout", "restart", workload_ref, "-n", "openshell"])?;
    if code != 0 {
        return Err(miette::miette!(
            "kubectl rollout restart {workload_ref} failed (exit {code})"
        ));
    }
    let (_, wait_code) = run_kubectl(
        gateway_name,
        &[
            "rollout", "status", workload_ref,
            "-n", "openshell",
            "--timeout=180s",
        ],
    )?;
    if wait_code != 0 {
        return Err(miette::miette!(
            "kubectl rollout status {workload_ref} timed out"
        ));
    }
    Ok(())
}

/// Load a local Docker image into the kind cluster via `kind load docker-image`.
pub fn kind_load_image(gateway_name: &str, image_ref: &str) -> Result<()> {
    let cluster_name = kind_cluster_name(gateway_name);
    tracing::info!("loading image '{image_ref}' into kind cluster '{cluster_name}'");
    let status = std::process::Command::new("kind")
        .args(["load", "docker-image", image_ref, "--name", &cluster_name])
        .status()
        .into_diagnostic()
        .wrap_err("failed to run `kind load docker-image`")?;
    if !status.success() {
        return Err(miette::miette!(
            "`kind load docker-image {image_ref}` failed with exit code {:?}",
            status.code()
        ));
    }
    Ok(())
}
