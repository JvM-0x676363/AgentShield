# Bitbucket pipeline distribution

Bitbucket Cloud does not provide native reusable workflows equivalent to GitHub
Actions. Teams can centralize the security pipeline in one of two ways.

## Recommended: a custom Bitbucket Pipe

Maintain a dedicated repository containing the scanner image and entry script.
Each application repository references the reviewed Pipe from its pipeline.
Version the Pipe immutably; do not use a mutable `latest` tag for a security
gate.

This keeps scanning logic in one place while allowing controlled rollouts of
rules and scanner updates.

## Alternative: managed template distribution

Use your approved configuration-management process to distribute a reviewed
pipeline template to repositories. Bitbucket YAML does not natively include
remote files, so avoid runtime cloning of untrusted templates or use of tokens
embedded in pipeline commands.

## Merge enforcement

Pipeline YAML alone does not prevent merging. Configure branch restrictions so
that required security builds must pass before merge to protected branches.

## Security principles

- Pin container images and Pipe versions.
- Keep scanner failures distinct from scanner findings.
- Do not print credentials, tokens, or full sensitive reports in logs.
- Use branch protection as the authoritative merge gate.
- Test pipeline changes in a non-production repository before rollout.
