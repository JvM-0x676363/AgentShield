# Changelog

All notable changes to this project are documented here.

## Unreleased

- Removed unsupported Codex command rules from Unix managed defaults. Command
  restrictions remain in `requirements.toml`; ordinary workflows use approval
  or an operator-selected Auto-review session.
- Minimized retained evidence for manual secure-development benchmarks. The
  scorecard record now keeps sanitized outcomes and scores, not transcripts,
  commands, paths, workspace files, or raw tool output.
- Clarified that local Gitleaks and Trivy scans are audit-only. Any blocking
  merge or release gate belongs to a separately managed remote pipeline.
- Added a non-destructive macOS smoke-test runbook. macOS remains pending
  validation on a real host; the runbook does not apply configuration or
  install scanners.
- Documented the isolation contract required before automated agent benchmark
  collection can be added. Interactive benchmark scoring remains supported;
  uncontained local agent runners are not distributed.
- Added an optional, local-only Claude Code security posture panel prototype.
  It reads a bounded sanitized scan-state record on demand and is excluded from
  installers, deployment targets, endpoint packages, and managed payloads.
- Added a disabled Claude write-guard pilot with synthetic tests and a Windows
  build helper. It is not included in installers, deployment targets, endpoint
  packages, or managed payloads.
- Split vendor-specific guidance out of always-loaded Claude Code, Codex, and
  Antigravity context. Short pointers now reference adjacent vendor appendices;
  managed Claude also installs the security review playbook beside its context
  file.
- Added an offline-capable local scanner runner for Windows, Linux, and macOS.
  It scans secrets, IaC, and dependency surfaces with Gitleaks and Trivy, and
  returns structured automation results.
- Added scanner runner verification to endpoint installation checks.
- Added a reproducible secure-development benchmark scorecard with a versioned,
  sanitized report format for Codex and Claude comparisons.
- Documented the Claude Mods threat model and opt-in admission requirements;
  no executable Mod is deployed by default.
- Replaced the Falcon workflow baseline with the v3 custom-script flow,
  including package SHA-256 verification, bounded staging cleanup, and typed
  failure states.
- Rewrote the public Falcon RTR templates, mock fixtures, custom scripts, and
  operator guide in English.

## 1.0.2 - 2026-11-03

- Corrected Falcon RTR JSON result conditions using the syntax validated by a
  mocked Windows workflow.
- Added Linux and macOS Falcon RTR workflow templates for tenant-specific mock
  and pilot validation.
- Added Unix verification assets to `-IncludeShell` packages and restored
  Bash 3.2 compatibility in the Unix fleet deployment script for macOS.
- Added a Linux/macOS managed-control detector for MDM and Falcon RTR.
- Split deployment payloads from optional Falcon and GPO integration assets.
- Confirmed Falcon mock success paths for the Windows, Linux, and macOS
  workflow templates; live pilots remain required.
- Added sanitized Falcon mock fixtures for manual Test-view configuration after
  a workflow import.
## 1.0.1 - 2026-11-03

- Added a Falcon Fusion RTR workflow template with mock-test guidance and
  pilot-first rollout controls.
- Included the Falcon RTR template and its guide in the Windows release ZIP.

## 1.0.0 - 2026-11-02

- Added managed security baselines for Codex, Claude Code, Claude Desktop,
  Antigravity, VS Code, and local Git hooks.
- Added Windows, Linux, macOS, and Windows/WSL deployment paths.
- Added Console, JSON Lines, and Quiet automation output modes.
- Added endpoint transcripts, post-deployment verification, and a native
  PowerShell detector for Intune managed-layer detection.
- Added benchmark fixtures for secure-development and prompt-injection tests.
- Added source, behavior, package, and payload-parity validation.
