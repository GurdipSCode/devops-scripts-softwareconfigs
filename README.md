# 🔐 devops-scripts-softwareconfigs

<p align="center">
  <img src="https://img.shields.io/badge/Platform-DevOps-blue?style=for-the-badge&logo=azuredevops" />
  <img src="https://img.shields.io/badge/Scripts-PowerShell%20%7C%20Bash-informational?style=for-the-badge&logo=gnubash" />
  <img src="https://img.shields.io/badge/Security-Hardening-critical?style=for-the-badge&logo=datadog" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/CI-Buildkite-14CC80?style=flat&logo=buildkite&logoColor=white" />
  <img src="https://img.shields.io/badge/Security-GitGuardian-orange?style=flat&logo=gitguardian&logoColor=white" />
  <img src="https://img.shields.io/badge/Code%20Review-CodeRabbit-ff6f61?style=flat" />
  <img src="https://img.shields.io/github/license/REPO_OWNER/REPO_NAME?style=flat" />
  <img src="https://img.shields.io/github/last-commit/REPO_OWNER/REPO_NAME?style=flat" />
</p>

---

## 📖 Overview

This repository contains **PowerShell** and **Bash** scripts used to:

* 🔧 Install and configure applications
* 🔐 Apply security hardening
* ⚙️ Standardise infrastructure setup
* 🚀 Automate deployment prerequisites

### 🧩 Supported Platforms

* 🟦 TeamCity
* 🐙 Octopus Deploy
* 🔍 Splunk
* 📊 Elastic Stack
* ☁️ General infrastructure (Linux & Windows)

---

## 🏗️ Repository Structure

```text
.
├── .buildkite/           # CI pipelines
├── scripts/
│   ├── powershell/       # Windows automation & hardening
│   ├── bash/             # Linux automation & hardening
│   └── shared/           # Reusable helpers
├── AGENTS.md             # CodeRabbit review guidance
├── .coderabbit.yaml      # CodeRabbit configuration
├── .mergify.yml          # Merge automation rules
└── README.md
```

---

## 🚀 CI / CD & Automation

| Tool               | Purpose                            |
| ------------------ | ---------------------------------- |
| 🟢 **Buildkite**   | Pipeline execution & orchestration |
| 🔐 **GitGuardian** | Secret scanning & detection        |
| 🤖 **CodeRabbit**  | AI-assisted code reviews           |
| 🔀 **Mergify**     | Automated PR merging & rules       |

---

## 🔐 Security Principles

This repo follows strict **security-first practices**:

* ❌ No hardcoded secrets
* 🔑 Secrets managed externally (Vault / CI variables)
* 🔒 TLS enforced wherever possible
* 📦 Downloads verified (checksum/signature where applicable)
* 🧱 Least privilege execution

---

## 🧪 Script Standards

### PowerShell

* `Set-StrictMode -Version Latest`
* `$ErrorActionPreference = "Stop"`
* Idempotent design
* Safe registry + service changes

### Bash

* `set -euo pipefail`
* Quoted variables
* Minimal assumptions on distro
* Safe package installs

---

## ⚠️ Important Notes

* These scripts may **modify system-level configuration**
* Always test in **non-production environments first**
* Some scripts may require:

  * 🛡️ Administrator (Windows)
  * 🔐 Root / sudo (Linux)

---

## 🧠 Code Review & Governance

All PRs are automatically reviewed for:

* 🔐 Security issues
* ⚙️ Operational risks
* 🔁 Idempotency
* 📉 Reliability concerns

See [`AGENTS.md`](./AGENTS.md) for full review policy.

---

## 🔀 Pull Request Workflow

1. Create feature branch
2. Open PR
3. ✅ Buildkite runs
4. 🔐 GitGuardian scans
5. 🤖 CodeRabbit reviews
6. 👀 Manual approval
7. 🚀 Mergify auto-merges

---

## 🛠️ Usage

Example:

### PowerShell

```powershell
.\scripts\powershell\harden-teamcity.ps1
```

### Bash

```bash
chmod +x ./scripts/bash/harden-elastic.sh
./scripts/bash/harden-elastic.sh
```

---

## 📌 Roadmap

* [ ] Add checksum validation to all downloads
* [ ] Add SBOM generation
* [ ] Add OPA policy checks
* [ ] Expand platform coverage

---

## 🤝 Contributing

* Follow security-first approach
* Keep scripts idempotent
* Document breaking changes
* Avoid introducing interactive steps

---

## 📜 License

MIT License (or update as appropriate)

---

<p align="center">
  Built for 🔐 secure, ⚙️ repeatable, and 🚀 production-ready infrastructure
</p>
