#!/bin/bash
# Keeps the curated CLI toolset in ~/bin up to date from each project's
# official release channel (bypasses Homebrew/MacPorts entirely).
set -uo pipefail

BIN_DIR="$HOME/bin"
STATE="$HOME/bin/.cli-tools-versions"
LOG="$HOME/Library/Logs/cli-tools-update.log"
mkdir -p "$BIN_DIR" "$(dirname "$LOG")"
touch "$STATE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# resolve the ~/bin symlink to the real script inside the repo clone
SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT" ]; do
  link=$(readlink "$SCRIPT")
  case "$link" in /*) SCRIPT="$link" ;; *) SCRIPT="$(dirname "$SCRIPT")/$link" ;; esac
done
REPO=$(cd "$(dirname "$SCRIPT")" && pwd)

# Self-update: fast-forward the clone's main from the public HTTPS URL (no SSH
# keys needed under launchd), and re-exec once if anything changed. git swaps
# files in via a new inode, so the copy bash is currently reading isn't
# disturbed. Any failure just logs and carries on as-is.
self_update() {
  local before after
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || return 0
  if [ "$(git -C "$REPO" symbolic-ref --short -q HEAD)" != main ]; then
    log "self-update: $REPO is not on main, skipping"
    return 0
  fi
  before=$(git -C "$REPO" rev-parse HEAD)
  if ! git -C "$REPO" fetch --quiet https://github.com/503stack/intel-mac-tools.git main 2>>"$LOG" \
     || ! git -C "$REPO" merge --ff-only --quiet FETCH_HEAD >>"$LOG" 2>&1; then
    log "WARNING: self-update of $REPO failed (offline, local changes or diverged?), running current version"
    return 0
  fi
  after=$(git -C "$REPO" rev-parse HEAD)
  if [ "$before" != "$after" ]; then
    log "self-update: $REPO ${before:0:7} -> ${after:0:7}, re-running"
    CLI_TOOLS_SELF_UPDATED=1 exec /bin/bash "$SCRIPT" "$@"
  fi
}
[ -n "${CLI_TOOLS_SELF_UPDATED:-}" ] || self_update "$@"
log "run started (script $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "outside git"))"

current_version() { awk -v k="$1" '$1==k{print $2}' "$STATE"; }
save_version() {
  local name="$1" version="$2"
  grep -v "^$name " "$STATE" > "$STATE.tmp" 2>/dev/null || true
  echo "$name $version" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

# Use an authenticated GitHub API token when available (60/hr -> 5000/hr).
# Falls back to unauthenticated silently if gh isn't installed or logged out.
GH_TOKEN=""
if command -v gh >/dev/null 2>&1; then
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi

# fetch a URL fully into memory first, THEN parse it -- piping curl directly
# into awk/grep with an early exit can SIGPIPE curl mid-download and silently
# truncate the result.
fetch() {
  local url="$1"
  if [ -n "$GH_TOKEN" ] && [[ "$url" == https://api.github.com/* ]]; then
    curl -fsSL -H "Authorization: Bearer $GH_TOKEN" "$url"
  else
    curl -fsSL "$url"
  fi
}

json_field() {
  # position-independent: works for both pretty-printed (GitHub) and
  # single-line compact (HashiCorp checkpoint API) JSON
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

gh_latest_tag() { json_field "$(fetch "https://api.github.com/repos/$1/releases/latest")" "tag_name"; }

# our own darwin/amd64 builds of tools upstream stopped shipping for Intel Macs;
# releases are tagged "<tool>/<upstream tag>", prints the newest upstream tag
imt_latest_tag() {
  printf '%s' "$(fetch "https://api.github.com/repos/503stack/intel-mac-tools/releases?per_page=100")" \
    | awk -F'"' '/"tag_name"/{print $4}' | grep "^$1/" | sed "s|^$1/||" | sort -V | tail -1
}

install_raw() {
  local name="$1" url="$2"
  curl -fsSL -o "$BIN_DIR/$name.new" "$url"
  chmod +x "$BIN_DIR/$name.new"
  mv "$BIN_DIR/$name.new" "$BIN_DIR/$name"
}

install_from_archive() {
  local name="$1" url="$2" src_name="${3:-$1}"
  local tmp; tmp=$(mktemp -d)
  local archive="$tmp/archive"
  curl -fsSL -o "$archive" "$url"
  case "$url" in
    *.zip) unzip -q "$archive" -d "$tmp" ;;
    *)     tar xf "$archive" -C "$tmp" ;;
  esac
  local found
  found=$(find "$tmp" -type f -name "$src_name" | head -1)
  if [ -z "$found" ]; then
    log "ERROR: could not find '$src_name' binary inside archive from $url"
    rm -rf "$tmp"
    return 1
  fi
  # copy then rename: overwriting a running binary in place (e.g. an open
  # bash) can crash it on macOS; a rename gives the new file a fresh inode
  cp "$found" "$BIN_DIR/$name.new"
  chmod +x "$BIN_DIR/$name.new"
  mv "$BIN_DIR/$name.new" "$BIN_DIR/$name"
  rm -rf "$tmp"
}

# lima ships its main tree plus a separate "additional guestagents" tarball
# (non-x86_64 guest agents, for running e.g. an arm64 Linux VM on this host)
install_lima() {
  local name="$1" url="$2" guestagents_url="$3"
  local target="$HOME/lib/lima"
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/archive" "$url"
  rm -rf "$target.new"
  mkdir -p "$target.new"
  tar xzf "$tmp/archive" -C "$target.new"
  curl -fsSL -o "$tmp/guestagents" "$guestagents_url"
  tar xzf "$tmp/guestagents" -C "$target.new"
  rm -rf "$target.old" 2>/dev/null
  [ -d "$target" ] && mv "$target" "$target.old"
  mv "$target.new" "$target"
  rm -rf "$target.old" "$tmp"
}

# extracts a whole tarball into $HOME/lib/<target_dir>, atomically replacing
# it -- for tools shipped as a full bin/+share/ prefix tree, not one binary
install_tree() {
  local name="$1" url="$2" target_dir="$3"
  local target="$HOME/lib/$target_dir"
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/archive" "$url"
  rm -rf "$target.new"
  mkdir -p "$target.new"
  tar xzf "$tmp/archive" -C "$target.new"
  rm -rf "$target.old" 2>/dev/null
  [ -d "$target" ] && mv "$target" "$target.old"
  mv "$target.new" "$target"
  rm -rf "$target.old" "$tmp"
}

update() {
  local name="$1" latest="$2" install_fn="$3" url="$4" src_name="${5:-}"
  if [ -z "$latest" ]; then
    log "ERROR: could not determine latest version for $name"
    return 1
  fi
  local current; current=$(current_version "$name")
  if [ "$current" = "$latest" ]; then
    log "$name already up to date ($current)"
    return 0
  fi
  log "$name: ${current:-none} -> $latest, updating"
  if "$install_fn" "$name" "$url" "$src_name"; then
    save_version "$name" "$latest"
    log "$name updated to $latest"
  else
    log "$name update FAILED"
  fi
}

### vcluster ###
v=$(gh_latest_tag loft-sh/vcluster | sed 's/^v//')
update "vcluster" "$v" install_raw "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-darwin-amd64"

### jq ###
v=$(gh_latest_tag jqlang/jq | sed 's/^jq-//')
update "jq" "$v" install_raw "https://github.com/jqlang/jq/releases/download/jq-${v}/jq-macos-amd64"

### yq (mikefarah's Go yq) ###
v=$(gh_latest_tag mikefarah/yq | sed 's/^v//')
update "yq" "$v" install_raw "https://github.com/mikefarah/yq/releases/download/v${v}/yq_darwin_amd64"

### shellcheck ###
v=$(gh_latest_tag koalaman/shellcheck | sed 's/^v//')
update "shellcheck" "$v" install_from_archive "https://github.com/koalaman/shellcheck/releases/download/v${v}/shellcheck-v${v}.darwin.x86_64.tar.xz"

### gh (GitHub CLI) ###
v=$(gh_latest_tag cli/cli | sed 's/^v//')
update "gh" "$v" install_from_archive "https://github.com/cli/cli/releases/download/v${v}/gh_${v}_macOS_amd64.zip"

### watch (installed as viddy, a modern watch replacement -- no macOS watch binary exists) ###
v=$(gh_latest_tag sachaos/viddy | sed 's/^v//')
update "watch" "$v" install_from_archive "https://github.com/sachaos/viddy/releases/download/v${v}/viddy-v${v}-macos-x86_64.tar.gz" "viddy"

### kubectl (no GitHub releases; official channel is dl.k8s.io) ###
v=$(fetch "https://dl.k8s.io/release/stable.txt")
update "kubectl" "$v" install_raw "https://dl.k8s.io/release/${v}/bin/darwin/amd64/kubectl"

### helm (GitHub release only has signatures; binary lives on get.helm.sh) ###
v=$(gh_latest_tag helm/helm)
update "helm" "$v" install_from_archive "https://get.helm.sh/helm-${v}-darwin-amd64.tar.gz"

### kustomize (monorepo; releases tagged "kustomize/vX.Y.Z") ###
kv_full=$(printf '%s' "$(fetch "https://api.github.com/repos/kubernetes-sigs/kustomize/releases?per_page=20")" | awk -F'"' '/"tag_name"/{print $4}' | grep '^kustomize/' | head -1)
v="${kv_full#kustomize/}"
update "kustomize" "$v" install_from_archive "https://github.com/kubernetes-sigs/kustomize/releases/download/${kv_full}/kustomize_${v}_darwin_amd64.tar.gz"

### k0sctl ###
v=$(gh_latest_tag k0sproject/k0sctl | sed 's/^v//')
update "k0sctl" "$v" install_raw "https://github.com/k0sproject/k0sctl/releases/download/v${v}/k0sctl-darwin-amd64"

### kubecolor ###
v=$(gh_latest_tag kubecolor/kubecolor | sed 's/^v//')
update "kubecolor" "$v" install_from_archive "https://github.com/kubecolor/kubecolor/releases/download/v${v}/kubecolor_${v}_darwin_amd64.tar.gz"

### stern ###
v=$(gh_latest_tag stern/stern | sed 's/^v//')
update "stern" "$v" install_from_archive "https://github.com/stern/stern/releases/download/v${v}/stern_${v}_darwin_amd64.tar.gz"

### terraform (HashiCorp's own release channel, zip not tar.gz) ###
v=$(json_field "$(fetch https://checkpoint-api.hashicorp.com/v1/check/terraform)" current_version)
update "terraform" "$v" install_from_archive "https://releases.hashicorp.com/terraform/${v}/terraform_${v}_darwin_amd64.zip"

### terraform-ls ###
v=$(json_field "$(fetch https://checkpoint-api.hashicorp.com/v1/check/terraform-ls)" current_version)
update "terraform-ls" "$v" install_from_archive "https://releases.hashicorp.com/terraform-ls/${v}/terraform-ls_${v}_darwin_amd64.zip"

### azure-cli (tarball, extracted whole into ~/lib/azure-cli) ###
v=$(gh_latest_tag Azure/azure-cli | sed 's/^azure-cli-//')
update "azure-cli" "$v" install_tree "https://github.com/Azure/azure-cli/releases/download/azure-cli-${v}/azure-cli-${v}-macos-x86_64.tar.gz" "azure-cli"

### lima (main tree + additional guestagents tarball) ###
v=$(gh_latest_tag lima-vm/lima | sed 's/^v//')
update "lima" "$v" install_lima "https://github.com/lima-vm/lima/releases/download/v${v}/lima-${v}-Darwin-x86_64.tar.gz" "https://github.com/lima-vm/lima/releases/download/v${v}/lima-additional-guestagents-${v}-Darwin-x86_64.tar.gz"

### flux ###
v=$(gh_latest_tag fluxcd/flux2 | sed 's/^v//')
update "flux" "$v" install_from_archive "https://github.com/fluxcd/flux2/releases/download/v${v}/flux_${v}_darwin_amd64.tar.gz"

### flux-operator ###
v=$(gh_latest_tag controlplaneio-fluxcd/flux-operator | sed 's/^v//')
update "flux-operator" "$v" install_from_archive "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${v}/flux-operator_${v}_darwin_amd64.tar.gz"

### yt-dlp (standalone PyInstaller build; universal2, includes x86_64; tags have no "v") ###
v=$(gh_latest_tag yt-dlp/yt-dlp)
update "yt-dlp" "$v" install_raw "https://github.com/yt-dlp/yt-dlp/releases/download/${v}/yt-dlp_macos"

### ffmpeg + ffprobe (FFmpeg publishes source only; ffmpeg.org links evermeet.cx's static x86_64 builds) ###
v=$(json_field "$(fetch https://evermeet.cx/ffmpeg/info/ffmpeg/release)" version)
update "ffmpeg" "$v" install_from_archive "https://evermeet.cx/ffmpeg/ffmpeg-${v}.zip"
v=$(json_field "$(fetch https://evermeet.cx/ffmpeg/info/ffprobe/release)" version)
update "ffprobe" "$v" install_from_archive "https://evermeet.cx/ffmpeg/ffprobe-${v}.zip"

### podman (remote client only; upstream v6 dropped Intel Macs, so it's built in 503stack/intel-mac-tools) ###
v=$(imt_latest_tag podman | sed 's/^v//')
update "podman" "$v" install_from_archive "https://github.com/503stack/intel-mac-tools/releases/download/podman/v${v}/podman-remote-darwin-amd64.tar.gz"

### bash (macOS only ships 3.2; GNU publishes source only, built in 503stack/intel-mac-tools) ###
v=$(imt_latest_tag bash)
update "bash" "$v" install_from_archive "https://github.com/503stack/intel-mac-tools/releases/download/bash/${v}/bash-darwin-amd64.tar.gz"
