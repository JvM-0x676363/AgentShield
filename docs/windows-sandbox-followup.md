# Windows sandbox follow-up

This legacy path is retained for installer and validator compatibility. The
current English incident record is [WINDOWS-SANDBOX.md](WINDOWS-SANDBOX.md).

The affected native Windows setup can fail during thread creation with a
`setup refresh had errors` message after the elevated sandbox was provisioned.
Do not weaken or disable the required sandbox as a workaround.
