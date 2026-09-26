# intel-mac-tools

Builds of CLI tools for Intel Macs (darwin/amd64) whose upstream projects have
stopped shipping them, or never shipped Mac binaries at all. Each tool has its
own workflow in `.github/workflows/` that watches upstream releases and
publishes a matching release here, tagged `<tool>/<upstream tag>`.

Upstream versions are pinned in each workflow and kept current by
[Renovate](https://docs.renovatebot.com/). A bump PR builds the tool as a
check, Renovate automerges it when the build passes, and the merge publishes
the new release.

It also holds `update-cli-tools.sh`, the updater that keeps a curated set of
CLI tools in `~/bin` current. It pulls each tool from its official release
channel (bypassing Homebrew/MacPorts), and pulls the tools built here from
this repo's releases.

| Tool | Release tag | Asset | Notes |
|------|-------------|-------|-------|
| bash | `bash/X.Y.N` | `bash-darwin-amd64.tar.gz` | GNU bash `X.Y` tarball plus official patches `001`..`N` (bash has no git tags), GPG-verified against the GNU keyring. Built natively on `macos-26-intel` (C needs the macOS SDK), linked only against system libraries, NLS disabled. |
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
mkdir -p ~/bin
ln -sf ~/git/intel-mac-tools/update-cli-tools.sh ~/bin/update-cli-tools.sh
```

Because `~/bin` holds a symlink, and each run first fast-forwards the clone's
`main` from GitHub over HTTPS (re-running itself if the script changed),
anything merged to `main` takes effect on the next run, with no manual
`git pull`. If the clone has local changes, has diverged, or isn't on `main`,
the self-update is skipped with a note in the log. Add `~/bin`, `~/lib/azure-cli/bin`, and `~/lib/lima/bin` to
`PATH`.

### Scheduling (LaunchAgent)

`launchd/com.bengt.cli-tools-update.plist.template` runs the updater at login
and every Monday 09:00, logging to `~/Library/Logs/cli-tools-update.log`.
launchd doesn't expand `~` or `$HOME`, so the template uses `__HOME__` in
place of your home directory, and the install step below fills it in:

```bash
plist=~/Library/LaunchAgents/com.bengt.cli-tools-update.plist
sed "s|__HOME__|$HOME|g" ~/git/intel-mac-tools/launchd/com.bengt.cli-tools-update.plist.template > "$plist"
launchctl bootout gui/$(id -u) "$plist" 2>/dev/null  # if already loaded
launchctl bootstrap gui/$(id -u) "$plist"             # RunAtLoad: runs once now
```

Other useful commands:

```bash
launchctl kickstart gui/$(id -u)/com.bengt.cli-tools-update   # run now
launchctl print gui/$(id -u)/com.bengt.cli-tools-update        # status, last exit code
tail -f ~/Library/Logs/cli-tools-update.log
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.bengt.cli-tools-update.plist  # uninstall
```

To change the schedule, edit `StartCalendarInterval` in the template and
re-run the install step.

## Using podman on the Intel Mac

The `podman` built here is only the client. Containers run in a Lima VM (kept
current by the updater's `lima`), started on demand:

```bash
limactl start --name=podman --cpus=4 --memory=8 --disk=100 --mount-writable --tty=false template:podman
podman system connection add --default lima-podman "unix://$HOME/.lima/podman/sock/podman.sock"
# LLMNR in the Fedora guest collides with macOS on port 5355 (noisy warnings)
limactl shell podman sudo sh -c 'mkdir -p /etc/systemd/resolved.conf.d && printf "[Resolve]\nLLMNR=no\n" > /etc/systemd/resolved.conf.d/no-llmnr.conf && systemctl restart systemd-resolved'
```

In `~/.zshrc`, map `podman machine` onto the VM and point Docker-API clients
(testcontainers, kind, devcontainers, ...) at the same socket:

```zsh
export DOCKER_HOST="unix://$HOME/.lima/podman/sock/podman.sock"
podman() {
  if [[ $1 == machine ]]; then
    case $2 in
      start)   limactl start --tty=false podman; return ;;
      stop)    limactl stop podman; return ;;
      list|ls) limactl list podman; return ;;
      ssh)     shift 2; limactl shell podman "$@"; return ;;
      *)       print -u2 "podman machine $2: not mapped (VM is Lima instance \"podman\"; use limactl)"; return 1 ;;
    esac
  fi
  command podman "$@"
}
```

Then run `podman machine start` when you need it (about 20 s) and
`podman machine stop` when you're done. To boot it at login instead, run
`limactl autostart enable podman`.

- `--mount-writable` makes `~` writable in the VM, so `-v "$PWD:/x"` works
  like it does with podman machine. Lima forwards published ports to
  `localhost` automatically.
- The server is whatever the VM's Fedora ships. The v6 client works with any
  server from libpod API 4.0 up, so Fedora 44's podman 5.8 is fine. To get a
  v6 server, upgrade the VM to Fedora 45+ with `dnf system-upgrade` inside
  `podman machine ssh`.
- The real `podman machine` isn't used. There is no x86_64 `applehv` image
  for v6.
