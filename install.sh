#!/usr/bin/env bash
# Public bootstrap: installs a reviewed runtime; never applies hardening.
set -Eeuo pipefail
umask 077
readonly KI_REF=bf38141fe2a7b7bfa4d5f6940ed5ed8052fd73b3
readonly KI_SHA256=e00e10a892b9a1e6a7d78f034eb2e9381968e9c88cc91bee2a5bc614f942d4bb
readonly KI_URL="https://codeload.github.com/dustbase/keel/tar.gz/$KI_REF"
readonly KI_ROOT="keel-$KI_REF"
KI_MODULES=(common doctor keys prepare security session ssh transaction)
KI_WORK=''
ki_print() { printf '  %-9s %s\n' "[$1]" "$2"; }
ki_die() { ki_print ERROR "$*" >&2; return 1; }
ki_cleanup() {
  if [[ "$KI_WORK" == /tmp/keel-install.* && -d "$KI_WORK" && ! -L "$KI_WORK" ]]; then
    rm -rf -- "$KI_WORK"
  fi
}
ki_no_pending() {
  local state="$1" marker
  for marker in pending pending-rollback; do
    [[ ! -e "$state/$marker" && ! -L "$state/$marker" ]] ||
      { ki_die 'Recovery is pending. Recover with the installed runtime before installing.'; return 1; }
  done
}
ki_verify_download() {
  local actual
  actual="$(sha256sum "$1")" || return 1
  [[ "${actual%% *}" == "$KI_SHA256" ]] ||
    { ki_die 'Downloaded archive checksum mismatch; nothing installed.'; return 1; }
}
ki_validate_archive() {
  local listing types entry
  listing="$(tar -tzf "$1")" || return 1
  types="$(tar -tvzf "$1")" || return 1
  while IFS= read -r entry; do
    case "$entry" in
      "$KI_ROOT/"*) ;;
      *) ki_die 'Unexpected archive root.'; return 1 ;;
    esac
    case "/$entry" in */../*|*/./*) ki_die 'Unsafe archive path.'; return 1 ;; esac
  done <<< "$listing"
  while IFS= read -r entry; do
    case "${entry:0:1}" in -|d) ;; *) ki_die 'Archive links and special files are not supported.'; return 1 ;; esac
  done <<< "$types"
}
ki_validate_payload() {
  local source="$1" module count
  [[ -f "$source/bin/keel" && ! -L "$source/bin/keel" && -d "$source/lib" && ! -L "$source/lib" ]] || return 1
  for module in "${KI_MODULES[@]}"; do
    [[ -f "$source/lib/$module.sh" && ! -L "$source/lib/$module.sh" ]] || return 1
  done
  count="$(find "$source/lib" -mindepth 1 -maxdepth 1 | wc -l)" || return 1
  (( count == ${#KI_MODULES[@]} ))
}
ki_existing_matches() {
  local source="$1" target="$2" module
  [[ ! -L "$target" && ! -L "$target/bin" && ! -L "$target/lib" &&
     -f "$target/bin/keel" && ! -L "$target/bin/keel" ]] || return 1
  ki_validate_payload "$target" || return 1
  cmp -s "$source/bin/keel" "$target/bin/keel" || return 1
  for module in "${KI_MODULES[@]}"; do
    cmp -s "$source/lib/$module.sh" "$target/lib/$module.sh" || return 1
  done
}
ki_install_runtime() (
  # Build beside the destination so publication is one same-filesystem rename.
  # Every operation is checked: callers may invoke this function conditionally.
  local source="$1" target="$2" command_link="$3" stage=''
  trap 'if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  [[ ! -e "$target" && ! -L "$target" ]] || return 1
  stage="$(mktemp -d "${target%/*}/.keel-install.XXXXXXXXXX")" || return 1
  install -d -m 755 "$stage/bin" "$stage/lib" || return 1
  install -m 755 "$source/bin/keel" "$stage/bin/keel" || return 1
  install -m 644 "$source/lib/"*.sh "$stage/lib/" || return 1
  ki_existing_matches "$source" "$stage" || return 1
  chmod 755 "$stage" || return 1
  mv -T "$stage" "$target" || return 1
  stage=''
  ln -sfn "$target/bin/keel" "$command_link" || return 1
)
ki_trusted_runtime() {
  local target="$1" file count
  ki_validate_payload "$target" || return 1
  for file in "$target" "$target/bin" "$target/lib" "$target/bin/keel" "$target/lib/"*.sh; do
    keel_trusted_path "$file" || return 1
  done
  [[ -x "$target/bin/keel" ]] || return 1
  count="$(find "$target/bin" -mindepth 1 -maxdepth 1 | wc -l)" || return 1
  (( count == 1 )) || return 1
  count="$(find "$target" -mindepth 1 -maxdepth 1 | wc -l)" || return 1
  (( count == 2 ))
}
ki_exchange_runtime() {
  # Linux RENAME_EXCHANGE keeps a complete runtime at the command's fixed path,
  # even if this process is killed or the host reboots during publication.
  python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

libc = ctypes.CDLL(None, use_errno=True)
exchange = libc.renameat2
exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
exchange.restype = ctypes.c_int
if exchange(-100, os.fsencode(sys.argv[1]), -100, os.fsencode(sys.argv[2]), 2):
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
PY
}
ki_upgrade_runtime() {
  local source="$1" target="$2" command_link="$3" state="$4" backup boot ticks digest
  ki_trusted_runtime "$target" || { ki_die 'Untrusted or unsupported installed runtime; nothing replaced.'; return 1; }
  command -v python3 >/dev/null || { ki_die 'Automatic updates require python3 for atomic publication; nothing replaced.'; return 1; }
  ki_no_pending "$state" || return 1
  backup="$(mktemp -d "${target%/*}/.keel-upgrade.XXXXXXXXXX")" || return 1
  ki_print INFO "Update recovery directory: $backup"
  # Keep this directory on failure; it is not part of download cleanup.
  ki_install_runtime "$source" "$backup/runtime" "$backup/staged-command" || return 1
  ki_existing_matches "$source" "$backup/runtime" || return 1
  keel_atomic_write "$backup/status" 'staged; runtime publication may not yet have occurred' || return 1
  ki_no_pending "$state" || return 1
  rm -f -- "$state/verified" "$state/secured" || return 1
  if [[ -e "$state/prepared" || -L "$state/prepared" ]]; then
    keel_trusted_path "$state/prepared" || return 1
    boot="$(keel_boot_id)" || return 1
    ticks="$(keel_ticks)" || return 1
    digest="$(keel_config_digest)" || return 1
    keel_atomic_write "$state/prepared" "$boot $ticks $digest" || return 1
  fi
  sync -f "$state" || return 1
  sync -f "$backup" || return 1
  # The previous runtime becomes backup/runtime in the same atomic operation.
  ki_exchange_runtime "$backup/runtime" "$target" || {
    ki_die "Atomic publication failed. Inspect $target and $backup/runtime; recovery data retained."; return 1;
  }
  sync -f "$backup" || return 1
  ki_existing_matches "$source" "$target" || {
    ki_die "Published runtime could not be verified. Recovery retained at $backup/runtime."; return 1;
  }
  ln -sfn "$target/bin/keel" "$command_link" || return 1
  keel_atomic_write "$backup/status" 'complete; runtime contains the previous installation' || return 1
  ki_print PASS "Updated Keel. Previous runtime retained at $backup/runtime"
}
ki_main() {
  local init=no existing=no arg command payload
  for arg in "$@"; do
    case "$arg" in
      --init) init=yes ;;
      -h|--help)
        printf 'Usage: install.sh [--init]\nInstalls or updates pinned experimental Keel. --init also starts interactive preparation.\n'
        return 0 ;;
      *) ki_die "Unknown option: $arg"; return 1 ;;
    esac
  done
  (( EUID == 0 )) || { ki_die 'Run with sudo bash (or as root).'; return 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "$ID" == ubuntu && "$VERSION_ID" =~ ^(24\.04|26\.04)$ ]] ||
    { ki_die 'Supported releases: Ubuntu 24.04 and 26.04 LTS.'; return 1; }
  if [[ "$init" == yes ]]; then
    if ! ( : </dev/tty ) 2>/dev/null; then
      ki_die '--init needs a terminal. Install without it, then run sudo keel init interactively.'; return 1
    fi
  fi
  for command in curl tar sha256sum flock readlink stat install find cmp timeout chmod mv sync; do
    command -v "$command" >/dev/null || { ki_die "Required command missing: $command"; return 1; }
  done
  ki_no_pending /var/lib/keel || return 1
  # Ignore caller TMPDIR: the staging parent must not be replaceable by that user.
  KI_WORK="$(mktemp -d /tmp/keel-install.XXXXXXXXXX)" || return 1
  trap ki_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  printf '\n  Keel / Install or update\n\n'
  ki_print INFO "Downloading experimental Keel runtime $KI_REF"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 15 --max-time 120 "$KI_URL" -o "$KI_WORK/runtime.tar.gz" || return 1
  ki_verify_download "$KI_WORK/runtime.tar.gz" || return 1
  ki_validate_archive "$KI_WORK/runtime.tar.gz" || return 1
  tar -xzf "$KI_WORK/runtime.tar.gz" -C "$KI_WORK" --no-same-owner --no-same-permissions \
    "$KI_ROOT/bin" "$KI_ROOT/lib" || return 1
  payload="$KI_WORK/$KI_ROOT"
  ki_validate_payload "$payload" || { ki_die 'Incomplete runtime archive.'; return 1; }
  # shellcheck disable=SC2034 # Used by the downloaded installation module.
  KEEL_HOME="$payload"
  # This code is loaded only after verifying the pinned archive checksum.
  # shellcheck disable=SC1091
  source "$payload/lib/common.sh"
  keel_lock || return 1
  ki_no_pending /var/lib/keel || return 1
  keel_trusted_path /usr/local/bin || { ki_die 'Untrusted /usr/local/bin.'; return 1; }
  if [[ -e /usr/local/bin/keel || -L /usr/local/bin/keel ]]; then
    [[ -L /usr/local/bin/keel && "$(readlink /usr/local/bin/keel)" == /opt/keel/bin/keel ]] ||
      { ki_die 'Existing keel command is not the expected installation; nothing replaced.'; return 1; }
  fi
  if [[ -e /opt/keel || -L /opt/keel ]]; then
    existing=yes
    ki_trusted_runtime /opt/keel || { ki_die 'Untrusted or unsupported installed runtime; nothing replaced.'; return 1; }
    if ki_existing_matches "$payload" /opt/keel; then
      ln -sfn /opt/keel/bin/keel /usr/local/bin/keel || return 1
      ki_print INFO 'The pinned runtime is already installed.'
    else
      ki_upgrade_runtime "$payload" /opt/keel /usr/local/bin/keel /var/lib/keel || return 1
    fi
  else
    keel_trusted_path /opt || { ki_die 'Untrusted /opt.'; return 1; }
    ki_install_runtime "$payload" /opt/keel /usr/local/bin/keel || return 1
    ki_print PASS 'Installed Keel at /usr/local/bin/keel.'
  fi
  exec {KEEL_LOCK_FD}>&-
  ki_cleanup
  trap - EXIT INT HUP TERM
  if [[ "$init" == yes ]]; then
    exec /opt/keel/bin/keel init </dev/tty
  fi
  if [[ "$existing" == yes ]]; then
    ki_print INFO 'Settings and accounts preserved.'
    ki_print NEXT 'Open a fresh SSH login and run keel verify before secure.'
    ki_print INFO 'Use sudo keel init only if you want to rerun preparation.'
    return 0
  fi
  ki_print NEXT 'sudo keel init'
  ki_print INFO 'Then use fresh SSH connections for keel verify, keel secure, and keel confirm.'
}
# Supports both a downloaded script and curl | sudo bash, while allowing fixture imports.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  ki_main "$@"
fi
