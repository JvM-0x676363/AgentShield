# Maturity roadmap

This roadmap describes planned work. None of these items is an active control
until it is implemented, tested, and documented as such.

## Approved offline dependencies

Provide a corporate wheelhouse or internal package repository with approved,
pinned artifacts and verified hashes. Publish provenance, license, and
accepted-advisory metadata for direct and transitive dependencies. Require
hash-locked installs through the approved source and define promotion,
revocation, and vulnerability-refresh processes.

Outcome: a dependency request still requires human approval, but installation
does not require broad access to public registries.

## Reliable local scanners in sandboxes

Create an approved `agent-shield-scan` wrapper for Gitleaks, Semgrep, and
Trivy. The wrapper must keep Semgrep state in a temporary directory rather
than the user home, use reviewed versioned local rules, report `clean`,
`findings`, `not_applicable`, or `environment_blocked`, and share its
invocation with the Git hook.

CI remains the authoritative, blocking gate with current rules and databases.
Validate the wrapper on Windows, Linux/WSL, and macOS before rollout.
