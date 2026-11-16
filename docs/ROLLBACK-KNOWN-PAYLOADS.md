# Rollback of known AgentShield payloads

This design covers an existing file that AgentShield previously installed and
later overwrites. It does not authorize a backup of the user profile or of an
unknown configuration file. The first receipt implementation is limited to the
Windows Claude managed status line in the opt-in source-checkout pilot.

## Admission

An existing file is eligible only when all of these conditions hold:

1. The destination is an explicit `overwrite` target in a manifest, with a
   documented prior AgentShield payload for that same target and OS.
2. The file is regular, has no reparse point or symbolic-link parent escape,
   and its bytes exactly match the SHA-256 of that prior payload.
3. The prior payload is present in the same reviewed source checkout. Its
   digest is pinned in the receipt implementation and checked before
   installation and again before restoration. The receipt stores the payload
   identifier and hashes, never the previous file contents.
4. A private, per-run receipt directory is available before installation.
   A provisional marker is written before the target changes.

Any unknown or customized file keeps a `manual_review` receipt. A `.bak` file
created by the current installer is not a trusted rollback source: it has no
private storage or retention contract.

## Receipt and restoration

The completed receipt records the absolute destination, previous payload ID
and SHA-256, installed SHA-256, file identity and timestamps, and the selected
target. The provisional marker is cleared only after the completed receipt is
durable. An interrupted operation leaves the marker for operator review.

Restoring an older managed script can lower the security posture. Applying a
receipt to the real Windows managed status-line path requires an elevated
operator action; preview remains read-only.

Preview verifies the receipt, the prior packaged payload, current destination
identity, and installed hash. Apply repeats those checks immediately before a
locked write, restores the previous bytes, and reports a partial failure if a
write or metadata restoration fails. If the destination has changed, rollback
does not overwrite it. Batch apply stays blocked when any receipt in the run is
blocked or preview-only.

The first implementation is the Claude managed status-line script. On the pilot
Windows endpoint, its installed bytes matched the first public AgentShield
revision, and a temporary replacement with the current payload made all five
managed detector checks pass. The canary restored the original file; it did
not exercise receipt rollback. The isolated Windows test now covers preview,
restore, changed-file refusal, invalid prior digest, and the existing
Administrator gate. It also injects a receipt-writing failure after the
managed file changes and confirms that the provisional marker blocks batch
rollback. A process-kill test remains for release qualification.

## Files without a known prior payload

Some managed JSON files, merged settings, hooks, and user-supplied files cannot
be recreated from a reviewed AgentShield payload. They remain manual-review
items. Byte-for-byte backup support needs a separate administrator-managed
storage and retention design, including encryption, access control, bounded
file selection, deletion policy, and recovery after a partial restore. No
automatic backup of unknown file content is part of this pilot.
