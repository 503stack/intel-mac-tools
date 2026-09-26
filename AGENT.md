# AGENT.md

Guidance for AI coding agents (and humans) working in this repo.

## What this repo is

This repo holds two things:

1. `update-cli-tools.sh`, the maintainer's updater for the CLI tools in
   `~/bin`. `~/bin/update-cli-tools.sh` is a symlink to this file, and a
   LaunchAgent runs it unattended at login and weekly, so a broken commit
   breaks updates on the Mac.
2. CI workflows that build CLI tools for **Intel Macs (darwin/amd64)** when
   upstream stopped shipping Intel Mac builds (podman) or never shipped
   Mac binaries at all (bash). The repo contains
   no tool source code. Each workflow checks out upstream at a release tag,
   builds it, and publishes a GitHub release here, which
   `update-cli-tools.sh` then installs.

## Layout

- `.github/workflows/<tool>.yml`: one self-contained workflow per tool.
- `update-cli-tools.sh`: the updater, with one `### <tool> ###` block per tool.
- `launchd/*.plist.template`: the LaunchAgent that schedules the updater.
  `__HOME__` is filled in at install time (see README). Keep it identical to
  the installed plist apart from that placeholder.
- `renovate.json`: Renovate config. It bumps the pinned upstream versions
  and the action versions, and automerges every PR once its checks pass.
- `README.md`: a table of tools, with release tag, asset name, and notes. Keep
  it in sync with the workflows.

## Release contract (don't break it)

`update-cli-tools.sh` depends on these rules:

- **Tag:** `<tool>/<upstream tag>`, using the upstream tag exactly
  (e.g. `podman/v6.1.2`). If upstream has no tags, use a version the tool
  itself reports, and explain it in the workflow (bash: `bash/5.3.20`, where
  `5.3` is the tarball and `20` is the official patch level shown in
  `BASH_VERSINFO`). The script lists releases, filters them by the
  `<tool>/` prefix, and picks the highest version with `sort -V`.
- **Asset name:** fixed per tool, with no version in the name
  (e.g. `podman-remote-darwin-amd64.tar.gz`), plus a `<asset>.sha256` file.
- **Archive contents:** a `.tar.gz` holding the binary under its final
  command name (e.g. `podman`). The script finds it by name anywhere in the
  archive.
- **Latest flag:** create releases with `--latest=false`. With several tools in
  one repo, GitHub's "latest release" means nothing and nobody should rely on
  it.
- **No rewriting:** don't delete or re-publish an existing tag. The script
  records the installed version and won't notice a replaced asset. To fix a
  bad build, delete the release *and* tag on purpose, then re-run the
  workflow.

If you change any of these rules, update the tool's block in
`update-cli-tools.sh` in the same commit.

## Editing update-cli-tools.sh

- It runs unattended under `set -uo pipefail` (no `-e`), so one tool failing
  must not stop the others. Keep the `update <name> <version> <install_fn>
  <url> [extra]` pattern, and log errors instead of exiting.
- Run `bash -n update-cli-tools.sh && shellcheck update-cli-tools.sh` before
  committing (shellcheck is one of the tools it installs).
- Keep `fetch` as the only way it downloads API responses: it reads the whole
  response before parsing (see the SIGPIPE comment in the script) and adds
  the GitHub token.
- Install binaries by writing a new file and renaming it over the old one,
  never by overwriting in place (see `install_from_archive`). Tools like
  `bash` may be running while the updater replaces them.
- Only download x86_64/amd64 Mac assets. The target Mac is Intel.
- Tools with no working upstream Intel Mac build belong in a workflow here,
  installed with `imt_latest_tag`. Don't compile them in the script.

## How versions flow (Renovate)

1. Each build workflow pins its upstream version in top-level `env:`, with a
   `# renovate: datasource=… depName=… [packageName=…]` comment on the line
   above. The regex custom manager in `renovate.json` picks these up.
2. The Mend Renovate app opens a PR that bumps the value. Because the PR
   changes `.github/workflows/<tool>.yml`, that tool's workflow runs on
   `pull_request` as a **build-only check**, with no release.
3. Renovate automerges once all checks are green (`platformAutomerge: false`
   means Renovate itself waits for the checks, with no branch protection
   needed). A failing build blocks the merge and leaves the PR open.
4. The merge pushes to `main`, and the workflow builds again and publishes
   `<tool>/<version>`. If that release already exists (e.g. the PR only bumped
   `actions/checkout`), the push run skips.
5. `update-cli-tools.sh` installs the new release on its next scheduled run.

Rules that follow from this:

- Each workflow's `paths:` filter must list only its own file, so a bump
  rebuilds just that tool.
- Never resolve "latest" at build time. Builds must be reproducible from the
  pinned value, and Renovate is the only thing that moves it.
- Upstreams without a standard Renovate datasource get a `customDatasources`
  entry (bash reads the ftp.gnu.org directory listings with `format: html`
  and `extractVersion`). Test lookups with the `renovate-config` workflow,
  which validates the config and dry-runs every lookup.
- **bash base upgrades (e.g. 5.3 → 5.4) need a human.** The patch-level dep's
  `packageName` names the base, and its value must go back to `"000"`.
  Renovate's base-bump PR will fail its check (the old patch numbers don't
  exist for the new base), so fix those two lines in that PR by hand.

## Workflow conventions

Follow `.github/workflows/podman.yml` as the template:

1. **Triggers:** `push` to `main` and `pull_request`, both filtered by
   `paths: [.github/workflows/<tool>.yml]`, plus `workflow_dispatch`. No
   schedule, because Renovate drives updates.
2. **Idempotent:** the first step computes the release tag from the pinned
   version. On push or dispatch, later steps are skipped if that release
   exists. On `pull_request` it always builds, and the Release step is
   gated with `github.event_name != 'pull_request'`.
3. **Cheap runners:** use `ubuntu-latest` and cross-compile
   (e.g. Go with `GOOS=darwin GOARCH=amd64 CGO_ENABLED=0`). Use a
   `macos-*` runner only if the build really needs the macOS SDK or cgo, and
   say why in a comment.
4. **Mirror upstream:** copy build tags, ldflags, and version stamping from
   upstream's own release build (Makefile, goreleaser config, etc.), and add a
   comment pointing at the upstream target you mirrored. Set a build-origin or
   similar field to `github.com/$GITHUB_REPOSITORY` when upstream has one, so
   `<tool> version` shows where the binary came from.
5. **Pin the toolchain from upstream:** e.g. `actions/setup-go` with
   `go-version-file: go.mod`, not a hard-coded version.
6. **Print what was built:** run `file <binary>` so the log shows
   `Mach-O 64-bit x86_64`.

## Patching upstream

Keep patches to a minimum. They should only undo Intel Mac exclusions, not
change behavior.

- Put each patch in its own clearly named step (e.g. `Re-enable darwin/amd64`)
  with a comment explaining what upstream changed and when.
- **Fail loudly on drift:** check that the exact original text is present
  before replacing it, and exit with a `::error` annotation if it isn't. A
  silent no-op patch that produces a broken or different binary is worse than
  a red run.
- Prefer returning code to its last upstream release that supported Intel
  Macs over writing new code.
- Don't use `sed` with `|` as the delimiter on Go build tags, since tags
  contain `||`. Rewrite whole lines instead (see `patch_tag` in `podman.yml`).
- List the patch in the README table's Notes column.

## Adding a new tool

1. Confirm upstream really doesn't ship a usable darwin/amd64 build. Check
   which assets the latest release actually has, and read the release notes.
   Also check whether the tool needs a runtime piece that doesn't exist for
   Intel Macs, such as a VM image or helper binaries. If it does, say so in
   the README instead of shipping a binary that can't work.
2. Copy the closest existing workflow to `<tool>.yml` and adapt it. For
   pure-Go tools cross-compiled on Linux, start from `podman.yml`. For C or
   autoconf tools that need the macOS SDK, start from `bash.yml`, which runs
   natively on `macos-26-intel`, verifies GPG signatures on the sources, and
   fails if anything outside `/usr/lib` or `/System` gets linked.
3. Add a row to the README table.
4. Add the `# renovate:` comment above the pinned version (plus a custom
   datasource if needed), and open a PR. The PR run is the test. Merging it
   publishes the first release.
5. Add the consumer block to `update-cli-tools.sh` in this repo:

   ```bash
   ### <tool> (built in 503stack/intel-mac-tools: <why>) ###
   v=$(imt_latest_tag <tool> | sed 's/^v//')
   update "<tool>" "$v" install_from_archive "https://github.com/503stack/intel-mac-tools/releases/download/<tool>/v${v}/<asset>.tar.gz"
   ```

## Practical notes

- **Don't build locally.** The maintainer's Mac is an older Intel machine.
  Test by pushing and running the workflow, not by installing toolchains or
  compiling on the Mac.
- **Pushing workflow files:** use the SSH remote
  (`git@github.com:503stack/intel-mac-tools.git`). The local `gh` OAuth token
  lacks the `workflow` scope, so HTTPS pushes that touch
  `.github/workflows/` are rejected.
- Workflows rely on the default `GITHUB_TOKEN` with `contents: write`; no
  secrets are needed. Renovate runs as the Mend app, which can change
  workflow files.
- ldflags `-X` silently ignores unknown symbol paths. Derive module paths at
  build time (e.g. `$(go list -m)`), and check that the stamp landed in the
  binary, so a major-version bump can't quietly drop version info.
- These are unofficial builds. Keep the release notes clear about that and
  link to the exact upstream tag.
