# OrcaShell

[![License](https://img.shields.io/badge/License-Apache_2.0-blue)](LICENSE)
[![Based On](https://img.shields.io/badge/Based_On-NVIDIA_OpenShell-76b900)](https://github.com/NVIDIA/OpenShell)
[![K8s](https://img.shields.io/badge/Kubernetes-kind_(k8s)-326CE5)](https://kind.sigs.k8s.io/)
[![Status](https://img.shields.io/badge/Status-Research_&_Learning-orange)]()

**Research & learning project built on NVIDIA OpenShell** — exploring GPU multi-tenancy, smart inference routing, and multi-agent orchestration for AI agent infrastructure.

> **This is a personal study project, not production software.**
> OrcaShell is a modified fork of [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) for educational and research purposes.

---

## Why OrcaShell?

Orca pods (groups of killer whales) coordinate, communicate, and hunt together — each member with a distinct role. In the same way, OrcaShell explores how multiple AI agents can be orchestrated within secure, GPU-aware sandboxed environments.

NVIDIA OpenShell provides a solid foundation for sandboxed AI agent execution, but several areas remain open for exploration:

- **GPU Resource Partitioning** — How can multiple agents share a single GPU safely and efficiently?
- **Smart Inference Routing** — How should requests be routed across local and cloud models based on cost, latency, and privacy?
- **Multi-Agent Orchestration** — How can agents collaborate on complex tasks within isolated environments?
- **Observability & Monitoring** — How do we track what agents are doing at scale?

OrcaShell is a space to study, experiment with, and prototype solutions for these challenges.

---

## Key Difference from OpenShell: k3s → kind (k8s)

OpenShell uses a k3s cluster inside a single Docker container — designed for single-player, single-developer mode. OrcaShell adds **kind (Kubernetes in Docker)** as an opt-in backend to explore multi-agent, multi-tenant, and GPU multi-tenancy scenarios.

| | OpenShell (upstream) | OrcaShell (this fork) |
|---|---|---|
| Orchestrator | k3s (embedded in Docker) | k3s (default) or **kind / k8s** (`--use-kind`) |
| Target | Single developer, 1 agent | **Multi-agent, GPU sharing** |
| Data store | SQLite | SQLite (k3s) / **etcd** (kind) |
| Scalability | Single node | **Multi-node capable** (kind) |
| GPU sharing | None | **GPU Device Plugin / HAMI** (kind) |
| K8s API | 100% compatible | 100% compatible |

### Why kind over k3s for GPU research?

OpenShell chose k3s for valid reasons — it runs as a single binary (~50MB), boots in seconds, and needs only 512MB RAM. For single-developer use, it is optimal.

For GPU multi-tenancy research (HAMI, device plugins) on DGX Spark, k3s has practical limitations:

- **Embedded containerd** — NVIDIA Container Runtime cannot be easily configured inside the k3s Docker container; GPU device plugins cannot reach host `/dev/nvidia*`
- **SQLite** — cannot handle concurrent writes at scale
- **Non-standard distribution** — HAMI is developed and tested against upstream k8s

kind runs standard upstream Kubernetes inside a Docker container. Because kind uses **privileged containers**, the NVIDIA runtime on the host is directly accessible inside the kind node — enabling GPU device plugins without complex nested configuration.

### Security Tradeoff: k3s vs kind

```
k3s (OpenShell default)           kind (OrcaShell --use-kind)
─────────────────────────         ──────────────────────────────
HOST                              HOST
└── Docker container              └── Docker container ⚠ privileged
    (non-privileged)                  └── k8s (upstream)
    └── k3s                               └── Sandbox Pod
        └── Sandbox Pod                       ├── GPU 사용 가능 ✓
            ├── GPU 사용 불가 ✗               └── Host 커널 접근 가능 ⚠
            └── Host 접근 불가 ✓

보안 격리: 강함 ★★★★              보안 격리: 약함 ★★★
GPU 멀티테넌시: 불가               GPU 멀티테넌시: 가능 (HAMI)
```

kind uses privileged Docker containers for its k8s nodes, meaning a pod that escapes the k8s level has broader host access than in the k3s path. The sandbox-level security layers (Landlock, seccomp, network policy) remain identical — the tradeoff is at the container infrastructure level.

> **For research on DGX Spark**, this tradeoff is acceptable. For production deployments requiring maximum isolation, use the default k3s path.

### OpenShell 6-Layer Security

OrcaShell preserves all OpenShell security layers. Only Layer 0 changes when `--use-kind` is used.

```
Layer 0: Container (k3s Pod  or  kind/k8s Pod)  ← --use-kind で切替
Layer 1: Network namespace + veth + OPA proxy
Layer 2: Filesystem isolation (Landlock LSM)
Layer 3: Syscall filtering (seccomp-bpf)
Layer 4: Privilege separation (UID/GID drop)
Layer 5: Inference routing (local vs cloud)
```

---

## Research Areas

### 1. GPU Multi-Tenancy (LD_PreLoad)
Exploring GPU resource partitioning for multi-agent environments using LD_PreLoad — CUDA API hooking via LD_PRELOAD, Kubernetes Device Plugin integration, and time-window-based GPU utilization control. Enables multiple sandboxed agents to share GPU resources without interference.

### 2. Smart Inference Routing
Investigating intelligent model routing beyond simple local-vs-cloud decisions. Factoring in data sensitivity, task complexity, model cost, latency requirements, and available GPU resources to dynamically select the optimal inference backend.

### 3. Multi-Agent Orchestration
Studying how multiple sandboxed agents can coordinate on complex workflows — such as coding, testing, and deployment pipelines — while maintaining security isolation between agents.

### 4. Observability & Telemetry
Building monitoring and audit capabilities to track AI agent 5-stage loop (Perceive/Reason/Plan/Act/Observe), GPU/CPU resource consumption, token usage, and tool call patterns across multi-agent deployments.

Includes a custom `agent_monitor` tool that correlates OpenClaw session logs with nvidia-smi GPU metrics in real-time, producing CSV data and timeline graphs for analysis.

---

## Architecture

```
Host (e.g., NVIDIA DGX Spark GB10)
  └── Docker
       └── kind cluster (full Kubernetes)
            ├── etcd                    — Distributed state store
            ├── kube-apiserver          — Kubernetes API
            ├── kube-scheduler          — Pod scheduling
            ├── kube-controller-manager — Desired state reconciliation
            │
            ├── Gateway (StatefulSet)   — Control-plane API, sandbox lifecycle
            ├── Sandbox CRD Controller  — Agent sandbox orchestration
            ├── GPU Device Plugin      — GPU multi-tenancy (planned)
            │
            └── Sandbox Pods × N        — Isolated agent environments
                 ├── Landlock LSM       — Kernel filesystem isolation
                 ├── seccomp-bpf        — Syscall filtering
                 ├── Network namespace  — OPA-enforced egress control
                 └── Agent process      — OpenClaw, Claude Code, etc.
```

Key components (Rust crates):

| Crate | Role |
|-------|------|
| `openshell-cli` | CLI entry point (`openshell` commands) |
| `openshell-server` | Gateway server (gRPC API, sandbox management) |
| `openshell-sandbox` | Sandbox creation, kernel-level isolation (Landlock, seccomp, netns) |
| `openshell-policy` | Policy engine (Rego rule evaluation, YAML parsing) |
| `openshell-router` | Privacy router (inference request interception and routing) |
| `openshell-providers` | Provider management (API keys, credential injection) |
| `openshell-bootstrap` | Initial setup (Gateway auto-provisioning) |
| `openshell-core` | Shared types, utilities, error handling |
| `openshell-tui` | Real-time terminal dashboard |

---

## Quick Start

### Prerequisites

- Docker (running)
- `kind` — [install](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- `kubectl` + `helm`
- Linux host with kernel >= 5.13 (for Landlock LSM)
- (Optional) NVIDIA GPU + drivers for GPU experiments

> **Linux inotify limits** — kind requires higher inotify limits than the kernel default. Apply once:
> ```bash
> sudo sysctl fs.inotify.max_user_watches=524288
> sudo sysctl fs.inotify.max_user_instances=512
> # Persist across reboots:
> echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.conf
> echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.conf
> ```

### Build

```bash
git clone https://github.com/<your-username>/OrcaShell.git
cd OrcaShell
cargo build -p openshell-cli
```

### Start gateway (kind mode)

```bash
# Start a kind-based gateway (creates kind cluster + deploys via Helm)
./target/debug/openshell gateway start --use-kind --name my-gateway

# Or use the environment variable (useful for NemoClaw integration)
export OPENSHELL_USE_KIND=true
./target/debug/openshell gateway start --name my-gateway
```

The bootstrap automatically:
1. Creates a kind cluster (`orcashell-{name}`)
2. Creates the `openshell` namespace
3. Generates and applies mTLS PKI secrets
4. Deploys the OpenShell Gateway via Helm
5. Waits for the gateway pod to be ready

### Create a sandbox

```bash
./target/debug/openshell sandbox create
```

### Destroy gateway

```bash
./target/debug/openshell gateway destroy --name my-gateway
```

### NemoClaw integration

```bash
# Install the built binary so NemoClaw finds it
cp ./target/debug/openshell ~/.local/bin/openshell

# Run NemoClaw with kind backend
export OPENSHELL_USE_KIND=true
nemoclaw onboard
```

---

## Agent Monitoring

OrcaShell includes custom monitoring tools for AI agent observability:

```bash
# Real-time agent loop monitoring (requires OpenClaw session)
python3 tools/agent_monitor.py

# Generate timeline graphs from CSV data
python3 tools/plot_monitor.py
```

Tracks:
- AI Agent 5-stage loop: Perceive → Reason → Plan → Act → Observe
- GPU utilization per stage (nvidia-smi)
- CPU/Memory/Disk/Network per stage (/proc)
- Tool calls: exec, write, read, web_search, cron
- Token accumulation and compaction events
- Per-stage timing (noodling/streaming duration)

---

## Project Structure

```
OrcaShell/
├── crates/              # Rust source (core logic)
├── python/              # Python SDK wrapper
├── proto/               # gRPC protocol definitions
├── architecture/        # Design documents
├── docs/                # User documentation
├── deploy/
│   ├── kind/            # kind cluster config + test sandbox YAML
│   ├── helm/            # Helm chart for OpenShell Gateway
│   ├── kube/            # Kubernetes manifests (CRDs, GPU plugins)
│   └── docker/          # Docker-related configs (legacy k3s entrypoint)
├── scripts/
│   ├── deploy-orcashell.sh    # One-click deployment
│   └── teardown-orcashell.sh  # Cluster teardown
├── tools/
│   ├── agent_monitor.py       # Real-time agent monitoring
│   └── plot_monitor.py        # Timeline graph generator
├── examples/            # Example configurations
├── e2e/                 # End-to-end tests
├── rfc/                 # Feature proposals
├── Cargo.toml           # Rust project configuration
├── pyproject.toml       # Python package configuration
└── install.sh           # One-line install script
```

---

## Verified Environment

| Component | Version |
|-----------|---------|
| Host | NVIDIA DGX Spark GB10 (aarch64, 128GB unified memory) |
| OS | Ubuntu 24.04 |
| Kernel | 6.11.0-1016-nvidia |
| Docker | 28.3.3 |
| kind | v0.32.0 |
| Kubernetes | v1.35.1 (via kind) |
| Helm | v3.20.2 |
| GPU | NVIDIA GB10 (nvidia-smi) |
| LLM (tested) | Ollama / Qwen3:8b |
| Agent (tested) | NemoClaw + OpenClaw v2026.4.5 |

### Implementation: what changed from OpenShell

The kind support is implemented as an opt-in path in `openshell-bootstrap`:

| File | Change |
|------|--------|
| `crates/openshell-bootstrap/src/kind.rs` | New module: kind cluster lifecycle, kubectl helpers, secret management |
| `crates/openshell-bootstrap/src/lib.rs` | `--use-kind` branch in `deploy_gateway_with_logs()`; kind-aware `GatewayHandle::destroy()` |
| `crates/openshell-cli/src/main.rs` | `--use-kind` / `OPENSHELL_USE_KIND` flag on `gateway start` |
| `deploy/kind/kind-config.yaml` | `extraPortMappings` (NodePort 30051 → host 8080) |

The k3s Docker path is **unchanged** — `--use-kind` is fully opt-in.

---

## Related Projects

| Project | Role | Repository |
|---------|------|------------|
| **NVIDIA OpenShell** | Base runtime (upstream) | [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) |
| **NVIDIA NemoClaw** | OpenClaw blueprint for OpenShell | [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) |
| **OpenClaw** | AI agent framework | [openclaw/openclaw](https://github.com/openclaw/openclaw) |
| **GPUPlugin** | GPU multi-tenancy Device Plugin |  |
| **NVIDIA Dynamo** | Distributed inference serving | [ai-dynamo/dynamo](https://github.com/ai-dynamo/dynamo) |

---

## References

- [OpenShell Sandbox Architecture (DeepWiki)](https://deepwiki.com/NVIDIA/OpenShell/6.1-sandbox-architecture)
- [OpenShell Security Best Practices (NVIDIA Docs)](https://docs.nvidia.com/openshell/latest/security/best-practices)
- [How NVIDIA OpenShell Sandboxes AI Agents (Dnotitia)](https://medium.com/@dnotitia/how-nvidia-openshell-sandboxes-ai-agents-why-ai-agents-need-sandboxing-part-1-e50884d8e3c2)
- [Run Autonomous Agents Safely (NVIDIA Blog)](https://developer.nvidia.com/blog/run-autonomous-self-evolving-agents-more-safely-with-nvidia-openshell/)

---

## Credits

This project is based on [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell), licensed under Apache 2.0.
Original work Copyright 2025-2026 NVIDIA CORPORATION & AFFILIATES.

OrcaShell is an independent research project and is **not affiliated with or endorsed by NVIDIA**.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

See [NOTICE](NOTICE) for attribution details.