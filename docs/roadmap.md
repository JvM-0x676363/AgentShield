# Maturity roadmap

This roadmap describes planned work. None of these items is an active control
until it is implemented, tested, and documented as such.

## Platform validation after v1.1.1

| Work item | Next evidence |
|---|---|
| macOS smoke test | Run the [macOS procedure](MACOS-SMOKE-TEST.md) on an approved Mac and record the OS, tool versions and check outcomes. |
| Scanner coverage on Windows, Linux/WSL and macOS | Run the [scanner benchmark](../benchmarks/agent-security/README.md) on each platform. Record findings on the synthetic fixture and distinguish unavailable tools from successful scans. |
| Windows Desktop thread startup | Verify whether a new thread starts on the previously affected endpoint. Track this separately from the [successful CLI MXC pilots](WINDOWS-SANDBOX.md). |
| Automatic MXC fallback (deferred) | On an approved test VM, establish whether a failed MXC startup leads to a successful run under the permitted elevated legacy backend. The earlier run with MXC disabled exercised a different starting condition. |

The v1.1.1 release checks verified both Falcon apply scripts against the
published deployment ZIP digest. Tenant workflow execution remains a
deployment-specific check. See the [Falcon mock and pilot procedure](../integrations/falcon-rtr/README.md).

## Approved offline dependencies

Provide a corporate wheelhouse or internal package repository with approved,
pinned artifacts and verified hashes. Publish provenance, license, and
accepted-advisory metadata for direct and transitive dependencies. Require
hash-locked installs through the approved source and define promotion,
revocation, and vulnerability-refresh processes.

Outcome: a dependency request still requires human approval, but installation
does not require broad access to public registries.

## Reliable local scanners in sandboxes

`agent-shield-scan` provides a local Gitleaks and Trivy baseline. It scans
Trivy IaC and dependency surfaces, reports
`clean`, `findings`, `not_applicable`, or `environment_blocked`, and is invoked
by the Git hook.

This repository validates the scanner wrapper and package; it does not run the
local scanner baseline as a blocking gate. A separately managed remote pipeline
must own any blocking decision, its rules, and its Trivy database lifecycle.
Remaining work: validate the wrapper on Windows, Linux/WSL, and macOS; and
evaluate an independently maintained source-code scanner through normal pull
requests.

## Reproducible agent benchmarks

The secure-development journey now includes a versioned JSON report shape and
local scorecard. It makes Codex, Claude Code, and Claude Desktop results
comparable when the prompts, fixture revision, platform, sandbox, and agent
version are recorded. The scorecard does not infer evidence; a human reviewer
still scores each control from the sanitized conversation record.
Automated collection remains deferred until an external runner can enforce the
isolation and evidence requirements in
[BENCHMARK-RUNNER-CONTRACT.md](BENCHMARK-RUNNER-CONTRACT.md). Do not run an
agent CLI directly from a benchmark helper as a substitute for that boundary.

Remaining work: build a privacy-preserving aggregate report only after there
are enough repeated runs to define meaningful trend thresholds.

## Claude Mods

Claude Mods are optional executable extensions, not a control boundary. The
initial evaluation and admission criteria are in
[CLAUDE-MODS.md](CLAUDE-MODS.md). A read-only security-posture panel is available as a local prototype using
the existing sanitized scan-state record. Evaluate it in an approved
non-production profile against the documented admission criteria. No Mod is deployed by AgentShield.

## Antigravity local commits

Keep `git commit` in Ask. Before considering an opt-in Allow rule, test the
candidate permission policy in a disposable Git repository and isolated user
profile on Windows, Linux, and macOS. Record the CLI version, effective rules,
actual tool decisions, and whether Git changed the fixture. Ordinary commits
must run without approval; `--no-verify`, `-n`, `--amend`, and push must never
run automatically. An agent response without a tool event is not evidence of
the permission decision. The CLI 1.5.11 pilot on Windows only established that
a benign project Ask regex requested approval; the unsafe bypass prompt was
refused before a tool call.
