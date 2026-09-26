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
current by the updater's `lima`), started on demand. The VM runs **Fedora 45**
(Beta, until it's released and Lima's `template:podman` moves to it), which
ships a podman 6 server to match the client.

In `~/.zshrc`, map `podman machine` onto the VM and point Docker-API clients
(testcontainers, kind, devcontainers, ...) at the same socket:

```zsh
export DOCKER_HOST="unix://$HOME/.lima/podman/sock/podman.sock"
podman() {
  if [[ $1 != machine ]]; then
    command podman "$@"; return
  fi
  local vm=podman was_running
  case $2 in
    start)   limactl start --tty=false $vm ;;
    stop)    limactl stop $vm ;;
    list|ls) limactl list $vm ;;
    ssh)     shift 2; limactl shell $vm "$@" ;;
    update)  # dnf upgrade inside the VM; leaves it running/stopped as it was
      [[ $(limactl list --format '{{.Status}}' $vm 2>/dev/null) == Running ]] && was_running=1
      [[ -n $was_running ]] || limactl start --tty=false $vm 2>/dev/null || return
      limactl shell $vm sudo dnf -y upgrade --refresh || return
      if ! limactl shell $vm sh -c '[ "$(uname -r)" = "$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" kernel-core | sort -V | tail -1)" ]'; then
        [[ -n $was_running ]] && print "New kernel installed: run 'podman machine stop && podman machine start' to boot it."
      fi
      [[ -n $was_running ]] || limactl stop $vm 2>/dev/null ;;
    reset)   # delete and recreate the VM from the current Lima template image
      if [[ $3 != -f ]]; then
        read -q "?Delete VM '$vm' with ALL its images, containers and volumes, then recreate it? [y/N] " || { print; return 1; }
        print
      fi
      limactl delete -f $vm 2>/dev/null
      # Fedora 45 Beta (podman 6) until Lima's template:podman moves past Fedora 44; then drop --set
      limactl start --name=$vm --cpus=4 --memory=8 --disk=100 --mount-writable --tty=false \
        --set '.images = [{"location": "https://download.fedoraproject.org/pub/fedora/linux/releases/test/45_Beta/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-45_Beta-1.3.x86_64.qcow2", "arch": "x86_64", "digest": "sha256:06bd4382a3bc5e5f94cd520f9ee15bdfb38d7bb72552b27fe06d581ba9a84292"}]' \
        template:podman || return
      # LLMNR in the Fedora guest collides with macOS on port 5355 (noisy forward warnings)
      limactl shell $vm sudo sh -c 'mkdir -p /etc/systemd/resolved.conf.d && printf "[Resolve]\nLLMNR=no\n" > /etc/systemd/resolved.conf.d/no-llmnr.conf && systemctl restart systemd-resolved'
      # Fedora 45 SELinux denies sshd-session (sshd_session_t) connectto the podman socket
      # (container_runtime_t), which breaks Lima's ssh socket forward to the host
      limactl shell $vm sudo sh -c 'printf "(allow sshd_session_t container_runtime_t (unix_stream_socket (connectto)))\n" > /root/lima-podman-socket.cil && semodule -i /root/lima-podman-socket.cil'
      print "Fresh VM: run 'podman machine update' to bring it past the image's release-day packages." ;;
    *)       print -u2 "podman machine ${2:-}: not mapped; use start|stop|list|ssh|update|reset [-f] (VM is Lima instance \"$vm\")"; return 1 ;;
  esac
}
```

Then create the VM once, and add the connection:

```bash
podman machine reset -f && podman machine update
podman system connection add --default lima-podman "unix://$HOME/.lima/podman/sock/podman.sock"
```

| Command | Does |
|---------|------|
| `podman machine start` / `stop` | Boot or shut down the VM (start takes about 20 s) |
| `podman machine list` / `ssh [cmd]` | Show status, or open a shell (or run `cmd`) in the VM |
| `podman machine update` | `dnf upgrade` in the VM, starting it if needed and leaving it as it was. Says when a new kernel needs a restart |
| `podman machine reset [-f]` | Delete the VM and everything in it, and recreate it from the current Lima template image. Asks first unless `-f`. Run `update` afterwards, because the template image is from the Fedora release date |

To boot it at login instead, run `limactl autostart enable podman`.

- `--mount-writable` makes `~` writable in the VM, so `-v "$PWD:/x"` works
  like it does with podman machine. Lima forwards published ports to
  `localhost` automatically.
- `reset` builds the VM with these fixes on top of `template:podman`:
  - **Fedora 45 Beta image**, pinned by URL and SHA-256 via `--set '.images=…'`.
    Once Fedora 45 is out the VM just keeps updating. Remove the `--set` when
    Lima's template ships Fedora 45 or later.
  - **SELinux:** Fedora 45's policy denies `sshd_session_t` (OpenSSH 10's
    `sshd-session`) `connectto` on the rootless podman socket
    (`container_runtime_t`). That breaks Lima's ssh socket forward (the host
    sees an empty reply) while podman works fine inside the guest. A one-rule
    CIL module (`lima-podman-socket`) allows exactly that, and SELinux stays
    enforcing.
  - **LLMNR off** in the guest, to stop port 5355 forward warnings.
- The v6 client also works with older servers (libpod API 4.0 and up), for
  example Fedora 44's podman 5.8.
- The real `podman machine` isn't used. There is no x86_64 `applehv` image
  for v6.
