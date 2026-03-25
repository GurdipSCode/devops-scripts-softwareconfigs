# Repository review instructions

This repository contains PowerShell and Bash scripts used to install, configure, secure, and harden platforms and applications such as TeamCity, Octopus Deploy, Splunk, Elastic, and related infrastructure.

It also contains Buildkite pipeline definitions used to execute automation in CI/CD.

## Review priorities

Focus on security, correctness, repeatability, and operational safety.
Do not spend much time on minor style-only comments unless they affect maintainability or clarity.

## Security

- Flag any hardcoded secrets, tokens, API keys, passwords, private keys, certificates, or bearer tokens.
- Assume GitGuardian is the primary secret scanning tool, but still comment on obvious secret-handling mistakes in code and pipeline files.
- Flag `Invoke-Expression`, `iex`, `curl | bash`, `wget | bash`, remote script execution without validation, and unsafe shell evaluation.
- Flag disabled TLS verification, insecure protocols, weak ciphers, blanket firewall disablement, or trust-on-first-use patterns.
- Flag downloads of installers, packages, scripts, or binaries that do not verify checksum, signature, digest, or provenance when validation is practical.
- Flag over-privileged execution such as unnecessary root, sudo, Administrator, or LocalSystem usage.
- Flag scripts that write secrets to logs, console output, temp files, artifacts, or world-readable locations.

## Hardening and platform safety

- Prefer idempotent changes.
- Prefer explicit secure configuration over insecure defaults.
- Flag changes that weaken RBAC, audit logging, authentication, retention, or transport security.
- Flag overly broad network exposure, open management ports, or unrestricted ingress rules.
- Flag scripts that alter host-wide settings without clearly documenting the change.
- Check file permissions, ownership, service accounts, certificate stores, keystores, and registry changes carefully.

## Reliability and automation

- Prefer non-interactive automation suitable for CI/CD, image baking, and repeated execution.
- Flag scripts that are unsafe to rerun.
- Flag missing error handling or partial configuration flows that can leave systems in an inconsistent state.
- Flag destructive actions, service restarts, reboots, or firewall changes if they are not clearly intentional.
- Prefer explicit exit conditions and failure handling.

## PowerShell guidance

- Prefer `Set-StrictMode -Version Latest`.
- Prefer `$ErrorActionPreference = 'Stop'`.
- Prefer advanced functions and named parameters for reusable logic.
- Prefer `Join-Path`, `Test-Path`, and robust path handling.
- Flag insecure use of `Invoke-WebRequest` and `Invoke-RestMethod`.
- Flag registry edits that are risky, opaque, or hard to reverse.
- Flag use of `Write-Host` for important operational or machine-readable output where structured logging would be better.

## Bash guidance

- Prefer `set -euo pipefail` where appropriate.
- Prefer quoted variables.
- Flag unsafe globbing, word splitting, unchecked command substitutions, and fragile pipes.
- Flag distro-specific assumptions unless clearly documented.
- Check systemd unit changes, sysctl changes, package installation logic, firewall changes, and permission changes carefully.

## Buildkite guidance

- Review `.buildkite` pipeline files for security and least privilege.
- Flag plaintext secrets, unsafe env var handling, and secret values echoed to logs.
- Flag downloading tools or scripts in pipeline steps without checksum or signature validation.
- Flag use of unpinned container images, plugins, or external actions where pinning is practical.
- Prefer immutable references such as exact versions, digests, or commit SHAs for critical dependencies.
- Check that queues, agents, and step permissions are appropriately scoped.
- Flag steps that use privileged containers, host mounts, Docker socket mounts, or excessive permissions without strong justification.
- Flag artifact handling that may expose secrets, certificates, logs with tokens, or sensitive config files.
- Flag retry or ignore-failure patterns that could hide security or deployment issues.
- Comment on opportunities to separate validation, hardening, and deployment concerns into safer stages.

## Domain-specific checks

### TeamCity
- Check server and agent token handling, service account permissions, TLS, plugin trust, and external exposure.
- Flag insecure bootstrap, agent registration, or trust establishment flows.

### Octopus Deploy
- Check API key handling, certificate handling, worker permissions, target exposure, and overly broad scoping.
- Flag insecure deployment target registration or machine policy shortcuts.

### Splunk
- Check admin credentials, HEC token handling, TLS, index/storage permissions, service permissions, and input exposure.
- Flag world-readable secrets or insecure listener configuration.

### Elastic
- Check built-in user handling, enrollment tokens, keystore usage, HTTP/transport TLS, and bootstrap configuration.
- Flag reusable scripts that embed insecure single-node shortcuts.

## Comment style

When raising issues, classify them where possible as:
- critical security issue
- operational risk
- correctness issue
- maintainability issue
- style/nit

Prefer actionable comments with safer alternatives.
Avoid low-value nitpicks.
