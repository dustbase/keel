#!/usr/bin/env bash
# Shared Keel helpers. Sourced by bin/keel.

KEEL_CONFIG=/etc/keel/config
KEEL_STATE=/var/lib/keel
KEEL_BACKUP=/var/backups/keel
KEEL_SSH_DROPIN=/etc/ssh/sshd_config.d/05-keel.conf

keel_log() { printf '\n==> %s\n' "$*"; }
keel_warn() { printf 'WARNING: %s\n' "$*" >&2; }
keel_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
keel_require_root() {
  (( EUID == 0 )) || keel_die "Run this command as root."
}
keel_yes() {
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}
keel_require_ubuntu() {
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "$ID" == ubuntu ]] || keel_die "v0.1 supports Ubuntu only."
  case "$VERSION_ID" in
    24.04|26.04) ;;
    *) keel_warn "Ubuntu $VERSION_ID is not tested by Keel." ;;
  esac
}
keel_setup_dirs() {
  install -d -m 700 -o root -g root /etc/keel "$KEEL_STATE" "$KEEL_BACKUP"
}
keel_load_config() {
  [[ -f "$KEEL_CONFIG" && ! -L "$KEEL_CONFIG" ]] ||
    keel_die "No Keel configuration. Run 'keel init' first."
  [[ "$(stat -c '%u' "$KEEL_CONFIG")" == 0 ]] ||
    keel_die "Configuration must be owned by root."
  # shellcheck disable=SC1090
  source "$KEEL_CONFIG"
}
keel_save_config() {
  keel_setup_dirs
  local f
  f="$(mktemp /etc/keel/.config.XXXXXX)"
  chmod 600 "$f"
  {
    printf 'KEEL_HOST=%q\n' "$KEEL_HOST"
    printf 'KEEL_ADMIN=%q\n' "$KEEL_ADMIN"
    printf 'KEEL_TS=%q\n' "$KEEL_TS"
    printf 'KEEL_TS_MODE=%q\n' "$KEEL_TS_MODE"
    printf 'KEEL_PROFILE=%q\n' "$KEEL_PROFILE"
    printf 'KEEL_CUSTOM=%q\n' "$KEEL_CUSTOM"
  } > "$f"
  mv -f "$f" "$KEEL_CONFIG"
}
keel_valid_hostname() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,62}$ && "$1" != *- ]]
}
keel_valid_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$1" != root ]]
}
keel_is_tailscale_ip() {
  local dest="$1" ip
  command -v tailscale >/dev/null || return 1
  while IFS= read -r ip; do
    [[ -n "$ip" && "$dest" == "$ip" ]] && return 0
  done < <(tailscale ip 2>/dev/null || true)
  return 1
}
keel_session_dest() {
  local a b dest port
  read -r a b dest port <<< "$1"
  [[ -n "$dest" && -n "$port" ]] || return 1
  printf '%s' "$dest"
}
keel_install_self() {
  local from="$1"
  [[ -f "$from/bin/keel" && -d "$from/lib" ]] ||
    keel_die "Incomplete Keel checkout."
  keel_setup_dirs
  install -d -m 755 /opt/keel/bin /opt/keel/lib
  cp -f -- "$from/bin/keel" /opt/keel/bin/keel
  cp -f -- "$from/lib/"*.sh /opt/keel/lib/
  chmod 755 /opt/keel/bin/keel
  chmod 644 /opt/keel/lib/*.sh
  ln -sfn /opt/keel/bin/keel /usr/local/bin/keel
  keel_log "Installed Keel command at /usr/local/bin/keel"
}
