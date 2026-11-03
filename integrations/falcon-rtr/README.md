# Falcon RTR workflow template

This directory contains CrowdStrike Falcon Fusion Workflow templates for
AgentShield deployment through Real Time Response (RTR).

It is deliberately not ready to target a production fleet. Before import,
replace the host-group placeholder and confirm the generic action identifiers
against the Falcon action catalog available to your tenant. Do not copy host
groups, schedules, custom scripts, log destinations, or credentials from
another workflow.

| Workflow template | Mock data | Platform | Validation status |
|---|---|---|---|
| `agentshield-deploy.workflow.template.yaml` | `agentshield-deploy-windows.mocks.template.json` | Windows | Imported and mock-tested in a pilot tenant. The `Put file` action was also tested on one pilot endpoint. |
| `agentshield-deploy-linux.workflow.template.yaml` | `agentshield-deploy-linux.mocks.template.json` | Linux | Imported and success-path mock-tested. Validate a real pilot endpoint and host prerequisites before rollout. |
| `agentshield-deploy-macos.workflow.template.yaml` | `agentshield-deploy-macos.mocks.template.json` | macOS | Imported and success-path mock-tested. Validate a real pilot endpoint and host prerequisites before rollout. |

## What the template does

Each template filters the selected host group to its declared platform, then:

1. uploads `agent-shield.zip` from the Falcon file library to the platform
   staging directory (`C:\Windows\Temp` on Windows and `/var/tmp` on Unix);
2. extracts the package and runs the fast configuration-only pass;
3. runs the platform-appropriate managed-control verification;
4. writes structured RTR output to the workflow log for either outcome.

It does not download scanners, deploy VS Code extensions, reboot hosts, remove
them from groups, or delete the staged package. A failed endpoint keeps its
local transcript available for an authorized operator to retrieve and review.

The Unix templates require `/bin/bash`, `unzip`, and `python3` on the endpoint.
They use `deploy.sh` and `Test-AgentShieldManaged.sh`, which are included only
when the ZIP is built with `-IncludeShell`. The Unix detector uses the bundled
verifier and requires Python 3 on the endpoint.

## Prepare the package

Build the artifact from a reviewed source checkout:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\build-package.ps1 `
  -OutDir .\dist -Force -IncludeShell -IncludeFalconTemplates
```

Upload the resulting `dist\agent-shield.zip` to the Falcon file library with
the exact name `agent-shield.zip`. Record the SHA-256 printed by the build and
verify it before upload using your approved operational process.

The same command produces `dist\agent-shield-integrations.zip`. Extract that
archive only on the operator workstation and import the appropriate workflow
from `falcon-rtr/`; do not transfer this integration archive to endpoints.

## Configure and import

1. Copy the template to an environment-owned workflow file. Do not edit the
   release artifact in place.
2. Replace `<FALCON_HOST_GROUP_ID>` with a dedicated pilot host-group ID.
3. Import the YAML in Falcon Fusion Workflows. If Falcon has changed an action
   identifier or property name, recreate that action in the UI while retaining
   the same order and parameters.
4. Keep the workflow manual for the initial pilot. Add a schedule only after a
   successful pilot and documented change approval.
5. Review the workflow log. A success path requires both a successful
   deployment result and a compliant managed-layer detector result.

The template invokes the endpoint in an elevated RTR context. It is intended
for `deploy.ps1`, not the per-user `install.ps1` entry point.

## Mock test before a live pilot

Falcon Fusion's **Test** view supports a mock execution: it evaluates the
workflow graph with simulated action output and does not call RTR or modify an
endpoint. Use it to prove both the success and failure branches before a live
pilot.

Configure each node as mock in the Test view. Provide output that matches the
schemas exposed by your tenant's action catalog. At minimum, exercise these two
paths:

| Path | Required simulated output | Expected route |
|---|---|---|
| Success | `DeviceQuery` returns one synthetic device; `GetDeviceDetails` identifies the template platform; deployment stdout contains `"status":"success"`; verification stdout contains the template's expected success value | `WriteSuccessLog` |
| Failure | Deployment stdout omits `"status":"success"`, or detector stdout omits `"compliant":true` | `WriteFailureLog` |

Each `*.mocks.template.json` file contains sanitized success data and scenario
overrides for that workflow. Falcon does not import node mocks with the YAML:
copy the values into the matching nodes in the Test view and apply an override
for each failure branch. The files contain fictitious device values and must
remain tenant-neutral.

Do not store mock exports from production executions in this repository. Falcon
can export node mocks inline, but their `output_data` is tenant-specific and
may include host or operational data. Keep mock definitions in the Falcon test
workspace or a separately approved internal repository.

The tested Windows workflow also confirmed that Falcon conditions need the
leading wildcard inside the quoted value. For example, the success condition is
stored as `*'*\"status\":\"success\"*'`; omitting that inner wildcard changes
the comparison to a prefix match and routes a valid JSON result to failure.

Testing an individual `Put file` or `Run file` action in the Falcon UI can run
the action against the selected endpoint, even when the overall workflow is in
test mode or disabled. Treat individual-action tests as live endpoint changes.

After mock validation, switch only the RTR actions to live mode and run the
workflow against the dedicated pilot group. The live pilot is the first test
that can upload a file or execute the deployment command. Confirm `/bin/bash`,
`unzip`, and Python 3 on Unix endpoints before a Linux or macOS live pilot.

## Rollout guidance

Use the configuration-only pass first. Run a separate, approved maintenance
workflow for scanner downloads, because those downloads depend on endpoint
network policy. Deploy VS Code extensions through a user-context mechanism,
not RTR.

For a failed endpoint, retrieve only the deployment transcript through the
approved responder workflow and investigate it under your incident or endpoint
management procedure. Do not use workflow logs to collect user configuration
or credential data.

See the repository's `docs/OPERATIONS.md` for package construction, output
semantics, and equivalent Intune deployment guidance.
