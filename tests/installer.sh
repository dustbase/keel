#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
# Checksum doubles below are invoked indirectly through imported functions.
# Bootstrap fixtures only: no installation, account, firewall, or host-state writes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=install.sh
source ./install.sh
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if ( "$@" ); then fail "Unexpected success: $*"; fi; }
ki_main --help | grep -q -- --init
reject ki_main --not-an-option
mkdir "$scratch/state"
ki_no_pending "$scratch/state"
touch "$scratch/state/pending"
reject ki_no_pending "$scratch/state"
rm "$scratch/state/pending"
ln -s absent "$scratch/state/pending"
reject ki_no_pending "$scratch/state"
rm "$scratch/state/pending"
mkdir "$scratch/state/pending-rollback"
reject ki_no_pending "$scratch/state"
printf 'PASS: installer pending markers (including malformed/legacy)\n'
printf 'tampered download\n' > "$scratch/download"
reject ki_verify_download "$scratch/download"
(
  sha256sum() { printf '%s  %s\n' "$KI_SHA256" "$1"; }
  ki_verify_download "$scratch/download"
)
printf 'PASS: installer checksum acceptance/rejection\n'
source_dir="$scratch/$KI_ROOT"
mkdir -p "$source_dir/bin" "$source_dir/lib"
printf '#!/bin/bash\n' > "$source_dir/bin/keel"
for module in "${KI_MODULES[@]}"; do printf '# fixture\n' > "$source_dir/lib/$module.sh"; done
ki_validate_payload "$source_dir"
tar -czf "$scratch/good.tar.gz" -C "$scratch" "$KI_ROOT"
ki_validate_archive "$scratch/good.tar.gz"
tar -czf "$scratch/traversal.tar.gz" --transform="s|^$KI_ROOT|$KI_ROOT/../escape|" -C "$scratch" "$KI_ROOT"
reject ki_validate_archive "$scratch/traversal.tar.gz"
ln -s /etc/passwd "$source_dir/lib/link"
tar -czf "$scratch/link.tar.gz" -C "$scratch" "$KI_ROOT"
reject ki_validate_archive "$scratch/link.tar.gz"
rm "$source_dir/lib/link"
printf 'PASS: installer archive paths and link rejection\n'
cp -a "$source_dir" "$scratch/installed"
ki_existing_matches "$source_dir" "$scratch/installed"
printf '# changed\n' >> "$scratch/installed/lib/ssh.sh"
reject ki_existing_matches "$source_dir" "$scratch/installed"
cp "$source_dir/lib/ssh.sh" "$scratch/installed/lib/ssh.sh"
rm "$scratch/installed/lib/ssh.sh"
ln -s "$source_dir/lib/ssh.sh" "$scratch/installed/lib/ssh.sh"
reject ki_existing_matches "$source_dir" "$scratch/installed"
rm "$scratch/installed/lib/ssh.sh"
reject ki_validate_payload "$scratch/installed"
touch "$source_dir/lib/extra.sh"
reject ki_validate_payload "$source_dir"
printf 'PASS: installer exact runtime matching, missing/extra files and symlinks\n'
rm "$source_dir/lib/extra.sh"

# Exercise the actual publisher inside a conditional, where Bash disables errexit.
for failure in directories entrypoint modules interrupted; do
  destination="$scratch/publish-$failure"
  mkdir "$destination"
  (
    install() {
      case "$failure:$*" in
        directories:*-d*|entrypoint:*755*bin/keel*|modules:*644*) return 1 ;;
        interrupted:*644*) kill -TERM "$BASHPID"; return 1 ;;
      esac
      command install "$@"
    }
    reject ki_install_runtime "$source_dir" "$destination/runtime" "$destination/keel"
  )
  [[ ! -e "$destination/runtime" && ! -L "$destination/keel" ]] ||
    fail "Failed $failure installation published a runtime or command."
  [[ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail "Failed $failure installation left staging behind."
  ki_install_runtime "$source_dir" "$destination/runtime" "$destination/keel"
  ki_existing_matches "$source_dir" "$destination/runtime"
  [[ "$(readlink "$destination/keel")" == "$destination/runtime/bin/keel" ]] || fail 'Missing installed command.'
done
destination="$scratch/publish-link-failure"
mkdir "$destination"
(
  ln() { return 1; }
  reject ki_install_runtime "$source_dir" "$destination/runtime" "$destination/keel"
)
ki_existing_matches "$source_dir" "$destination/runtime"
[[ ! -L "$destination/keel" ]] || fail 'Failed link operation unexpectedly published a command.'
printf 'PASS: installer copy failures, interruption, retry and link failure propagation\n'

KI_WORK="$(mktemp -d /tmp/keel-install.fixture.XXXXXXXXXX)"
touch "$KI_WORK/partial-download"
ki_cleanup
[[ ! -e "$KI_WORK" ]] || fail 'Partial installer staging was not removed.'
KI_WORK="$scratch"
ki_cleanup
[[ -d "$scratch" ]] || fail 'Cleanup removed a path outside the installer namespace.'
link="/tmp/keel-install.fixture-link-${BASHPID}"
ln -s "$scratch" "$link"
KI_WORK="$link"
ki_cleanup
[[ -L "$link" && -d "$scratch" ]] || fail 'Cleanup followed a staging symlink.'
rm "$link"
printf 'PASS: installer staging cleanup and namespace/symlink guards\n'
