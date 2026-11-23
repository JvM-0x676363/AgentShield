# Native secret write guard pilot

This candidate implements the write-input guard using the Go standard library.
It requires no Node runtime on the endpoint. It reads bounded JSON from stdin
and returns either `{}` or a Claude `PreToolUse` deny decision. It does not read
files, invoke subprocesses or use the network. Coverage limits are the same as
the [Node prototype](../README.md); this is not an OS security boundary.

The local Windows pilot passed unit tests and process-level decision comparison
with the Node prototype. A synthetic `NODE_OPTIONS` value does not affect the
native executable. The operator also reported eight passing offline cases on
Linux amd64 under WSL, using the matching artifact digest. Native Linux outside
WSL, macOS, ARM64 execution, signing, deployment and actual Claude hook failure
behavior have not been validated.

An offline cross-build completed on 2026-11-15 for Windows, Linux and macOS,
each in amd64 and arm64 variants. The Windows amd64 artifact also passed 15
synthetic process-level comparisons. Cross-build success does not establish
runtime compatibility or signing/notarization. Pilot archives include a build
manifest with compiler and source hashes, per-artifact hashes, and a separate
Windows test record. They are not part of the deployment release.

## Offline build and test

From this directory, using an approved installed Go compiler:

```powershell
$env:GOTOOLCHAIN = 'local'
$env:GOPROXY = 'off'
$env:GOSUMDB = 'off'
$env:CGO_ENABLED = '0'
$env:GOCACHE = Join-Path (Resolve-Path ../../..) 'tmp/go-cache'
go test ./...
go build -trimpath -o ../../../tmp/secret-write-guard-pilot.exe .
```

From the repository root, test the resulting Windows executable:

```powershell
$env:AGENTSHIELD_TEST_GUARD = (Resolve-Path ./tmp/secret-write-guard-pilot.exe).Path
node --test tests/hooks/native-guard.test.cjs
Remove-Item Env:\AGENTSHIELD_TEST_GUARD
```

The process test skips when no executable is supplied. A skipped test is not
runtime validation. Build outputs and caches stay in the ignored `tmp/` folder.
These environment settings affect only the current shell, not global settings.

## Admission before deployment

### Offline check on a work PC

Do not install this pilot as a machine-managed hook on a shared work PC.
`Test-Pilot.ps1` checks the supplied executable's expected SHA-256 before running
eight synthetic protocol cases. It sets a synthetic `NODE_OPTIONS` value only
for each child process. It does not invoke Claude, consume model tokens, create
the named test files or change endpoint settings. It outputs JSON with
`claude_integration: "not_tested"`; exit 0 means those offline cases passed,
1 means a case failed, and 2 means artifact verification could not complete.

```powershell
powershell -NoProfile -File .\Test-Pilot.ps1 `
  -Executable .\secret-write-guard-windows-amd64.exe `
  -ExpectedSha256 '<hash supplied through the trusted delivery channel>'
```

A manifest next to a binary is useful for consistency checks, not independent
proof of authenticity. Do not disable platform execution controls if the
unsigned pilot is blocked; report the block instead.

For Linux/WSL or macOS, `test_pilot.py` provides the same eight offline checks
using the Python standard library. Select the binary for the actual OS and
architecture, verify its supplied digest, and set its executable bit if archive
extraction did not preserve it. Do not change system security settings.

```bash
chmod u+x ./secret-write-guard-linux-amd64
python3 ./test_pilot.py \
  --executable ./secret-write-guard-linux-amd64 \
  --expected-sha256 '<hash supplied through the trusted delivery channel>'
```

The operator ran the portable tester successfully under WSL: eight passed,
zero failed, with no endpoint configuration changes. The development sandbox
could not reproduce that run because its WSL distributions were unavailable.
This is operator-supplied WSL evidence, not a macOS or ARM64 pass. The tester
neither installs Python nor grants execution rights.

### Live Claude test, pending

Use the [host validation procedure](HOST-VALIDATION.md) and record outcomes in
`host-validation.template.json`. Every case starts as `not_tested`.

Record the Claude version, OS, architecture and artifact digest. In an approved
test endpoint, keep `allowManagedHooksOnly` and existing permission denials.
An administrator must add the test hook through the managed configuration,
preserving existing keys and hook entries. Do not use local settings to bypass
managed policy. `/hooks` should identify the correct managed source and command.

Acceptance requires a clean Write to complete, a synthetic secret Write/Edit
to receive the guard's deny decision, and missing-executable/timeout failures
to block the tool through `onFailure: "block"`. An agent refusing to attempt
the tool does not prove the hook ran. Record the tool outcome and final file
state; do not collect unrelated session logs or credentials. Failure tests must
use a disposable test configuration, never remove or damage a deployed guard.

Reference: [managed hook scope](https://code.claude.com/docs/en/settings-reference#allowmanagedhooksonly)
and [hook failure handling](https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails).

### Release requirements

- Review and pin the build toolchain; record source revision and artifact hashes.
- Validate each OS and architecture on a real supported host, including client
  handling of a missing binary, denied execution, malformed output and timeout.
- Install to an administrator-controlled path with an approved ownership/ACL
  policy. Review native loader behavior and signing requirements per platform.
- Register the executable directly with an empty `args` list and
  `onFailure: "block"` only after the supported client contract is verified.
- Update target payloads, packaging and endpoint detection together.

No installer or build package includes this pilot. The Node configuration
generator still describes the isolated Node test, not this executable.
