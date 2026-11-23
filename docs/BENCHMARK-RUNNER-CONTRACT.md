# Automated benchmark runner contract

The secure-development benchmark currently supports reviewed, interactive runs
and a local scorecard. AgentShield does not provide an automated agent runner
until a separate execution environment can enforce this contract.

## Required boundary

The runner must create an operating-system-enforced boundary for each run:

- An empty, allowlisted environment and a temporary home, cache, and workspace.
  It must not inherit the operator's environment, credentials, configuration,
  agent history, or instruction files.
- Read-only benchmark source and toolchain. The agent may write only to an
  assigned disposable workspace.
- No general outbound network access from the agent workspace. If a supported
  agent requires provider connectivity, a separately reviewed runner component
  must broker only that provider protocol and deny package registries, remote
  installers, arbitrary URLs, and other destinations.
- Explicit CPU, memory, process, file-size, disk, and wall-clock limits.
- A fresh workspace and identity for every benchmark round. Do not reuse a
  workspace, conversation, or retained runtime state.
- Synthetic fixtures only. Never expose personal data, credentials, global
  configuration, shared repositories, sockets, containers, clusters, or cloud
  control planes.

## Evidence boundary

The runner may retain only a schema-validated, bounded evidence record. It
must not retain raw tool output, command strings, workspace files, environment
values, credentials, or agent transcripts by default. Any optional response
capture needs a separate privacy review and a redaction design that is not
presently approved.

A completed run may report guardrail and scanner operability only. It cannot
certify application security. A human-reviewed scorecard remains required.

## Admission

Before automated collection is added to this repository, its implementation
must provide:

1. A tested launcher that demonstrates every required boundary above on each
   supported platform.
2. A vendor-specific compatibility contract for the selected agent CLI.
3. Fail-closed handling for launcher, sandbox, network, timeout, and scanner
   failures.
4. Synthetic tests that prove no ambient environment or repository guidance is
   available to the agent.
5. Packaging and endpoint-detection checks proving the runner is not installed
   or invoked by normal AgentShield `install` or `deploy` flows.

Until then, use the documented interactive benchmark procedure and local
scorecard only.
