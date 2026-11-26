# Falcon Fusion RTR integration

This integration deploys AgentShield through Falcon Fusion and Real Time
Response (RTR). It uses custom RTR scripts so the workflow receives one typed
result per endpoint rather than relying on asynchronous command output.

The templates are reusable starting points, not tenant-ready workflows. They
contain no tenant identifiers, schedules, credentials, or embedded package
hashes.

| Platform | Workflow | Mock fixture |
|---|---|---|
| Windows | `agentshield-deploy.workflow.template.yaml` | `agentshield-deploy-windows.mocks.template.json` |
| Linux | `agentshield-deploy-linux.workflow.template.yaml` | `agentshield-deploy-linux.mocks.template.json` |
| macOS | `agentshield-deploy-macos.workflow.template.yaml` | `agentshield-deploy-macos.mocks.template.json` |

## Workflow behavior

For each endpoint in a dedicated pilot group, the workflow:

1. filters on the expected platform;
2. removes only the prior AgentShield ZIP and extraction directory;
3. uploads `agent-shield.zip` to the approved staging directory;
4. invokes the platform custom apply script;
5. records the outcome, hash, exit codes, and cleanup state in the Falcon log.

The custom script verifies the ZIP SHA-256 before extraction, checks managed
controls before deployment, skips deployment when already compliant, validates
after deployment, and removes only its own staging artifacts. Local deployment
transcripts remain available for authorized investigation.

## Build artifacts

For the published v1.1.1 pair, download `agent-shield.zip` and
`agent-shield-integrations.zip` from the [release page](https://github.com/JvM-0x676363/AgentShield/releases/tag/v1.1.1).
Verify each archive against its published SHA-256 before importing it.

To build both artifacts from a reviewed checkout:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\build-package.ps1 `
  -OutDir .\dist -Force -IncludeShell -IncludeFalconTemplates
```

Upload only `dist\agent-shield.zip` to the Falcon file library with the name
`agent-shield.zip`. Extract `dist\agent-shield-integrations.zip` on the
operator workstation; never transfer it to endpoints.

## Tenant setup

1. Verify both downloaded ZIPs against the digests in the selected GitHub release.
   For a local build, record both SHA-256 values printed by the builder.
2. Compare the digest assignment in each packaged apply script with the verified
   `agent-shield.zip` digest. The v1.1.1 operator ZIP includes both assignments. Source templates
   and the published v1.1.0 integrations ZIP contain `<AGENTSHIELD_PACKAGE_SHA256>`.
   In those copies, edit only the assignment in each script. The original Unix
   script also uses the placeholder in its validation condition. Leave that
   condition intact. When upgrading, update the Falcon file and both apply
   activities together, and check any workflow bindings to activity versions.
3. Upload the four custom scripts through Falcon's Custom Scripts interface:
   `AgentShield-Apply-Windows`, `AgentShield-Apply-Unix`,
   `AgentShield-Cleanup-Windows`, and `AgentShield-Cleanup-Unix`.
4. Attach `AgentShield-Apply.input-schema.json` and the matching output schema
   to the apply scripts; use `AgentShield-Cleanup.output-schema.json` for both
   cleanup scripts. Share the scripts with workflows and limit edit/run access
   to authorized RTR administrators.
5. Replace the activity-ID placeholders in the selected workflow template and
   replace `<FALCON_HOST_GROUP_ID>` with a dedicated pilot group.
6. Import the workflow as on-demand and keep it disabled until mock testing is
   complete.

Custom script activity IDs and version constraints are tenant-specific. Create
the activities in the Falcon UI if an import does not accept a placeholder.

## Mock testing

Falcon does not import node mocks with a workflow YAML. Each `*.mocks.template.json`
file contains fictitious success data and scenario overrides. Copy its values
to the matching nodes in Falcon Test view; do not paste tenant exports into
this repository.

Test at least these paths before a live pilot:

- `compliant_after_deploy`;
- `already_compliant`;
- `precheck_failed`;
- `deploy_failed`;
- `validation_failed`;
- `not_compliant_after_deploy`;
- `wrong_platform`.

An individual Falcon action test can execute against a real endpoint even when
the workflow is disabled. Treat `Put file`, cleanup, and apply-script tests as
live changes.

## Platform requirements

Windows uses `C:\Windows\Temp`. Linux and macOS use `/var/tmp`; Unix endpoints
need `/bin/bash`, a SHA-256 utility (`sha256sum` or `shasum`), and either
`unzip` or Python 3 for extraction. AgentShield's Unix managed detector also
requires Python 3.

The Windows apply script uses a narrowly scoped `ExecutionPolicy Bypass` when
it starts the verified package scripts. The ZIP hash check occurs first. Keep
this exception limited to the approved Falcon custom script and do not reuse
it for arbitrary PowerShell execution.
