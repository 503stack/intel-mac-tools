# intel-mac-tools

Builds of CLI tools for Intel Macs (darwin/amd64) whose upstream projects have
stopped shipping them. Each tool has its own workflow in `.github/workflows/`
that watches upstream releases and publishes a matching release here, tagged
`<tool>/<upstream tag>`.

| Tool | Release tag | Asset | Notes |
|------|-------------|-------|-------|
| podman | `podman/vX.Y.Z` | `podman-remote-darwin-amd64.tar.gz` | Remote client only (`podman`), cross-compiled with CGO off. Podman 6 dropped Intel Macs and has no x86_64 `applehv` machine image, so point it at a Linux host or VM running podman (e.g. Lima's `podman` template). |

These are unofficial builds from unmodified upstream sources.
