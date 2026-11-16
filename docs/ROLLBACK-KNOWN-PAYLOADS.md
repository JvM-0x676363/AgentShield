# Rollback of known AgentShield payloads

This design covers an existing file that AgentShield previously installed and
later overwrites. It does not authorize a backup of the user profile or of an
unknown configuration file. The source-checkout rollback pilot remains opt-in.

## Admission

An existing file is eligible only when all of these conditions hold:

1. The destination is an explicit `overwrite` target in a manifest, with a
   documented prior AgentShield payload for that same target and OS.
2. The file is regular, has no reparse point or symbolic-link parent escape,
   and its bytes exactly match the SHA-256 of that prior payload.
3. The prior payload is shipped with the same reviewed rollback package. Its
   digest is recorded in the manifest and checked before installation and
   again before restoration. The receipt stores the payload identifier and
   hashes, never the previous file contents.
4. A private, per-run receipt directory is available before installation.
   A provisional marker is written before the target changes.

Any unknown or customized file keeps a `manual_review` receipt. A `.bak` file
created by the current installer is not a trusted rollback source: it has no
private storage or retention contract.

## Receipt and restoration

The completed receipt records the canonical destination, previous payload ID
and SHA-256, installed SHA-256, file identity and timestamps, and the selected
target. The provisional marker is cleared only after the completed receipt is
durable. An interrupted operation leaves the marker for operator review.

Preview verifies the receipt, the prior packaged payload, current destination
identity, and installed hash. Apply repeats those checks immediately before a
locked write, restores the previous bytes, and reports a partial failure if a
write or metadata restoration fails. If the destination has changed, rollback
does not overwrite it. Batch apply stays blocked when any receipt in the run is
blocked or preview-only.

The first candidate is the Claude managed status-line script. On the pilot
Windows endpoint, its installed bytes matched the first public AgentShield
revision, and a temporary replacement with the current payload made all five
managed detector checks pass. The canary restored the original file; it did
not exercise receipt rollback. A synthetic test must prove preview, restore,
changed-file refusal, wrong-payload refusal, interrupted-write handling, and
Administrator gating before this receipt kind is enabled.

## Files without a known prior payload

Some managed JSON files, merged settings, hooks, and user-supplied files cannot
be recreated from a reviewed AgentShield payload. They remain manual-review
items. Byte-for-byte backup support needs a separate administrator-managed
storage and retention design, including encryption, access control, bounded
file selection, deletion policy, and recovery after a partial restore. No
automatic backup of unknown file content is part of this pilot.
