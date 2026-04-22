# 🐋 OrcaPod

[![License](https://img.shields.io/badge/License-Apache_2.0-blue)](LICENSE)
[![Based On](https://img.shields.io/badge/Based_On-NVIDIA_OpenShell-76b900)](https://github.com/NVIDIA/OpenShell)
[![Status](https://img.shields.io/badge/Status-Research_&_Learning-orange)]()

**Research & learning project built on NVIDIA OpenShell** — exploring GPU multi-tenancy, smart inference routing, and multi-agent orchestration for AI agent infrastructure.

> ⚠️ **This is a personal study project, not production software.**
> OrcaPod is a modified fork of [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) for educational and research purposes.

---

## Why OrcaPod?

Orca pods (groups of killer whales) coordinate, communicate, and hunt together — each member with a distinct role. In the same way, OrcaPod explores how multiple AI agents can be orchestrated within secure, GPU-aware sandboxed environments.

NVIDIA OpenShell provides a solid foundation for sandboxed AI agent execution, but several areas remain open for exploration:

- **GPU Resource Partitioning** — How can multiple agents share a single GPU safely and efficiently?
- **Smart Inference Routing** — How should requests be routed across local and cloud models based on cost, latency, and privacy?
- **Multi-Agent Orchestration** — How can agents collaborate on complex tasks within isolated environments?
- **Observability & Monitoring** — How do we track what agents are doing at scale?

OrcaPod is a space to study, experiment with, and prototype solutions for these challenges.

---

## Research Areas

### 1. GPU Multi-Tenancy
Exploring GPU resource partitioning for multi-agent environments using techniques such as CUDA API hooking (LD_PRELOAD), Kubernetes Device Plugins, and memory/compute quota enforcement — enabling multiple sandboxed agents to share GPU resources without interference.

### 2. Smart Inference Routing
Investigating intelligent model routing beyond simple local-vs-cloud decisions. Factoring in data sensitivity, task complexity, model cost, latency requirements, and available GPU resources to dynamically select the optimal inference backend.

### 3. Multi-Agent Orchestration
Studying how multiple sandboxed agents can coordinate on complex workflows — such as coding, testing, and deployment pipelines — while maintaining security isolation between agents.

### 4. Observability & Telemetry
Building monitoring and audit capabilities to track agent behavior, resource consumption, API usage, and policy violations across multi-agent deployments.

---

## Architecture

OrcaPod inherits the OpenShell architecture:

```
Docker Container
  └── k3s (lightweight Kubernetes)
       ├── Gateway      — Control-plane API, sandbox lifecycle management
       ├── Policy Engine — Filesystem, network, process constraints (YAML-based)
       ├── Privacy Router — Privacy-aware LLM routing
       └── Sandbox Pods  — Isolated agent execution environments
            ├── Agent A (e.g., OpenClaw + Ollama)
            ├── Agent B (e.g., Claude Code)
            └── Agent C (e.g., Codex)
```

Key components (Rust crates):

| Crate | Role |
|-------|------|
| `openshell-cli` | CLI entry point (`openshell` commands) |
| `openshell-server` | Gateway server (k3s management, gRPC API) |
| `openshell-sandbox` | Sandbox creation, kernel-level isolation (Landlock, seccomp, netns) |
| `openshell-policy` | Policy engine (Rego rule evaluation, YAML parsing) |
| `openshell-router` | Privacy router (inference request interception and routing) |
| `openshell-providers` | Provider management (API keys, credential injection) |
| `openshell-bootstrap` | Initial setup (Gateway auto-provisioning) |
| `openshell-core` | Shared types, utilities, error handling |
| `openshell-tui` | Real-time terminal dashboard |
| `openshell-ocsf` | Security event logging (OCSF format) |

---

## Getting Started

### Prerequisites

- Docker (running)
- Rust toolchain (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`)

### Build from Source

```bash
git clone https://github.com/<your-username>/OrcaPod.git
cd OrcaPod

# Build
cargo build --release

# Install
sudo cp target/release/openshell /usr/local/bin/openshell

# Verify
openshell --version
```

### Quick Test

```bash
# Start gateway
openshell gateway start

# Create a sandbox with an agent
openshell sandbox create -- claude

# Or with OpenClaw
openshell sandbox create --from openclaw
```

---

## Project Structure

```
OrcaPod/
├── crates/              # Rust source (core logic)
├── python/              # Python SDK wrapper
├── proto/               # gRPC protocol definitions
├── architecture/        # Design documents
├── docs/                # User documentation
├── examples/            # Example configurations
├── e2e/                 # End-to-end tests
├── scripts/             # Shell scripts (install, CI/CD)
├── deploy/              # Deployment configurations
├── rfc/                 # Feature proposals
├── tasks/               # Development task automation
├── Cargo.toml           # Rust project configuration
├── pyproject.toml       # Python package configuration
└── install.sh           # One-line install script
```

---

## Related Projects

| Project | Role | Repository |
|---------|------|------------|
| **NVIDIA OpenShell** | Base runtime (upstream) | [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) |
| **NVIDIA NemoClaw** | OpenClaw blueprint for OpenShell | [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) |
| **OpenClaw** | AI agent framework | [openclaw/openclaw](https://github.com/openclaw/openclaw) |
| **NVIDIA Dynamo** | Distributed inference serving | [ai-dynamo/dynamo](https://github.com/ai-dynamo/dynamo) |

---

## Credits

This project is based on [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell), licensed under Apache 2.0.
Original work Copyright 2025-2026 NVIDIA CORPORATION & AFFILIATES.

OrcaPod is an independent research project and is **not affiliated with or endorsed by NVIDIA**.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

See [NOTICE](NOTICE) for attribution details.

