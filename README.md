# intel-mac-tools

Builds of CLI tools for Intel Macs (darwin/amd64) whose upstream projects have
stopped shipping them. Each tool has its own workflow in `.github/workflows/`
that watches upstream releases and publishes a matching release here, tagged
`<tool>/<upstream tag>`.

It also holds `update-cli-tools.sh`, the updater that keeps a curated set of
CLI tools in `~/bin` current. It pulls each tool from its official release
channel (bypassing Homebrew/MacPorts), and pulls the tools built here from
this repo's releases.

| Tool | Release tag | Asset | Notes |
|------|-------------|-------|-------|
| podman | `podman/vX.Y.Z` | `podman-remote-darwin-amd64.tar.gz` | Remote client only (`podman`), cross-compiled with CGO off; two build tags patched back to their v5 values. Podman 6 dropped Intel Macs and has no x86_64 `applehv` machine image, so point it at a Linux host or VM running podman (e.g. Lima's `podman` template). |

These are unofficial builds. Upstream sources are used as-is except where a
workflow has to undo an Intel-Mac exclusion (e.g. podman's `//go:build` tags);
each such patch is a separate, clearly named workflow step.

## update-cli-tools.sh

Installs single binaries into `~/bin` and whole release trees into `~/lib/<tool>`
(lima, azure-cli). Installed versions are recorded in `~/bin/.cli-tools-versions`,
and runs are logged to `~/Library/Logs/cli-tools-update.log`. It uses `gh auth
token`, when available, for a higher GitHub API rate limit.

Setup on the Mac:

```bash
git clone git@github.com:503stack/intel-mac-tools.git ~/git/intel-mac-tools
ln -sf ~/git/intel-mac-tools/update-cli-tools.sh ~/bin/update-cli-tools.sh
```

A LaunchAgent (`~/Library/LaunchAgents/com.bengt.cli-tools-update.plist`)
runs it at login and every Monday 09:00. Because `~/bin` holds a symlink,
committed changes take effect on the next run.
