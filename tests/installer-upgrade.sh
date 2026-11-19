#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
# Runtime updates use private fixtures only; no host installation is changed.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=install.sh
source install.sh
# shellcheck source=lib/common.sh
source lib/common.sh
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if ( "$@" ); then fail "Unexpected success: $*"; fi; }
# Test-only trust checks for the unprivileged fixture, not a host ownership proof.
keel_trusted_path() {
  [[ -e "$1" && ! -L "$1" ]] || return 1
  local mode
  mode="$(stat -c %a "$1")" || return 1
  (( (8#$mode & 0022) == 0 ))
}
source_dir="$scratch/new"
mkdir -p "$source_dir/bin" "$source_dir/lib"
printf '#!/bin/bash\nprintf new\n' > "$source_dir/bin/keel"
chmod 755 "$source_dir/bin/keel"
for module in "${KI_MODULES[@]}"; do printf '# new %s\n' "$module" > "$source_dir/lib/$module.sh"; done
KEEL_CONFIG="$scratch/config"
printf 'unchanged intent\n' > "$KEEL_CONFIG"
fixture() {
  destination="$scratch/$1"
  mkdir -p "$destination"
  cp -a "$source_dir" "$destination/runtime"
  printf '# old runtime\n' >> "$destination/runtime/lib/common.sh"
  cp -a "$destination/runtime" "$destination/old"
  ln -s "$destination/runtime/bin/keel" "$destination/keel"
  KEEL_STATE="$destination/state"
  mkdir "$KEEL_STATE"
  printf old > "$KEEL_STATE/verified"
  printf old > "$KEEL_STATE/secured"
  printf old > "$KEEL_STATE/prepared"
  printf 'retain baseline\n' > "$KEEL_STATE/managed-firewall"
}
assert_backup() {
  local backup
  backup="$(find "$destination" -maxdepth 1 -type d -name '.keel-upgrade.*' -print)"
  [[ -n "$backup" ]] || fail 'No retained recovery directory.'
  ki_existing_matches "$destination/old" "$backup/runtime" || fail 'Previous runtime was not preserved.'
}
fixture success
ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
ki_existing_matches "$source_dir" "$destination/runtime"
assert_backup
[[ ! -e "$KEEL_STATE/verified" && ! -e "$KEEL_STATE/secured" ]] || fail 'Stale evidence survived update.'
[[ "$(cat "$KEEL_STATE/prepared")" != old ]] || fail 'Fresh-login boundary not advanced.'
grep -qx 'retain baseline' "$KEEL_STATE/managed-firewall"
grep -qx 'unchanged intent' "$KEEL_CONFIG"
fixture pending
touch "$KEEL_STATE/pending"
reject ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
ki_existing_matches "$destination/old" "$destination/runtime"
[[ "$(cat "$KEEL_STATE/verified")" == old ]] || fail 'Pending refusal modified evidence.'
fixture untrusted
chmod 666 "$destination/runtime/lib/common.sh"
reject ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
fixture extra
touch "$destination/runtime/bin/extra"
reject ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
fixture exchange-failure
(
  ki_exchange_runtime() { return 1; }
  reject ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
)
ki_existing_matches "$destination/old" "$destination/runtime"
fixture copy-failure
(
  install() { return 1; }
  reject ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
)
ki_existing_matches "$destination/old" "$destination/runtime"
for phase in before after; do
  fixture "killed-$phase"
  (
    python3() {
      if [[ "$phase" == before ]]; then kill -KILL "$BASHPID"; fi
      command python3 "$@" || return 1
      kill -KILL "$BASHPID"
    }
    reject ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
  )
  if [[ "$phase" == before ]]; then
    ki_existing_matches "$destination/old" "$destination/runtime"
  else
    ki_existing_matches "$source_dir" "$destination/runtime"
    assert_backup
  fi
done
fixture link-failure
(
  ln() {
    [[ "${!#}" != "$destination/keel" ]] || return 1
    command ln "$@"
  }
  reject ki_upgrade_runtime "$source_dir" "$destination/runtime" "$destination/keel" "$KEEL_STATE"
)
ki_existing_matches "$source_dir" "$destination/runtime"
assert_backup
printf 'PASS: automatic runtime upgrade, retained backup, pending/trust refusal, copy/exchange/link failures and SIGKILL boundaries\n'
