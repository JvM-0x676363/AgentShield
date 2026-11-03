# Changelog

All notable changes to this project are documented here.

## Unreleased

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
