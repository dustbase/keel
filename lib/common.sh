#!/usr/bin/env bash
# Shared helpers. Configuration is data, never sourced shell.
KEEL_CONFIG=/etc/keel/config
KEEL_STATE=/var/lib/keel
KEEL_BACKUP=/var/backups/keel
# shellcheck disable=SC2034 # Used by resource/transaction modules.
KEEL_SSH_DROPIN=/etc/ssh/sshd_config.d/05-keel.conf
KEEL_CONFIG_VERSION=1
KEEL_FIELDS=(KEEL_CONFIG_VERSION KEEL_HOST KEEL_ADMIN KEEL_TS KEEL_TS_MODE KEEL_PROFILE KEEL_CUSTOM)
# Bound calls inside the recovery window; the independent timer shares our lock.
keel_systemctl() { timeout --kill-after=5s 30s /usr/bin/systemctl "$@"; }
keel_ufw() { timeout --kill-after=5s 30s /usr/sbin/ufw "$@"; }
keel_log() { printf '\n==> %s\n' "$*"; }
keel_warn() { printf 'WARNING: %s\n' "$*" >&2; }
keel_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
keel_require_root() { (( EUID == 0 )) || keel_die 'Run this command as root.'; }
keel_yes() {
  local reply
  read -r -p "$1 [y/N]: " reply || return 1
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}
keel_require_ubuntu() {
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "$ID" == ubuntu && "$VERSION_ID" =~ ^(24\.04|26\.04)$ ]] ||
    keel_die 'Supported releases: Ubuntu 24.04 and 26.04 LTS.'
}
keel_trusted_path() {
  local path="$1" mode
  while [[ "$path" != / ]]; do
    [[ -e "$path" && ! -L "$path" ]] || return 1
    [[ "$(stat -c %u "$path")" == 0 ]] || return 1
    mode="$(stat -c %a "$path")" || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    path="$(dirname "$path")"
  done
}
keel_setup_dirs() {
  local dir
  for dir in /etc/keel "$KEEL_STATE" "$KEEL_BACKUP"; do
    [[ ! -L "$dir" ]] || keel_die "Unsafe directory: $dir"
    if [[ -e "$dir" ]]; then
      keel_trusted_path "$dir" || keel_die "Untrusted directory: $dir"
    fi
    install -d -m 700 -o root -g root "$dir"
  done
}
keel_lock() {
  keel_setup_dirs
  keel_trusted_path "$KEEL_STATE" || keel_die 'Untrusted state directory.'
  [[ ! -L "$KEEL_STATE/lock" ]] || keel_die 'Unsafe lock file.'
  exec {KEEL_LOCK_FD}>"$KEEL_STATE/lock"
  flock -w 15 "$KEEL_LOCK_FD" || keel_die 'Another Keel operation is running; retry shortly.'
}
keel_atomic_write() {
  local path="$1" tmp
  tmp="$(mktemp "${path}.XXXXXX")" || return 1
  chmod 600 "$tmp" || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! sync -f "$tmp" || ! mv -fT "$tmp" "$path" || ! sync -f "$(dirname "$path")"; then
    rm -f "$tmp"
    return 1
  fi
}
keel_no_pending() {
  [[ ! -f "$KEEL_STATE/pending-rollback" ]] ||
    keel_die 'Legacy rollback is pending. Resolve it with the original installed runtime before upgrading; see docs/recovery.md.'
  [[ ! -f "$KEEL_STATE/pending" ]] ||
    keel_die 'A security transaction is pending. Run sudo keel status or sudo keel rollback.'
}
keel_valid_hostname() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,62}$ && "$1" != *- ]]; }
keel_valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$1" != root ]]; }
keel_existing_admin_safe() {
  local entry _name _password uid _gid _gecos home shell
  entry="$(getent passwd "$1")" || return 0
  IFS=: read -r _name _password uid _gid _gecos home shell <<< "$entry"
  [[ "$uid" =~ ^[0-9]+$ && "$home" == /* && "$home" != / &&
     "$shell" != */nologin && "$shell" != */false && -x "$shell" ]] || return 1
  (( uid >= 1000 && uid < 65534 ))
}
keel_valid_rules() {
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^[0-9]{1,5}/(tcp|udp)(,[0-9]{1,5}/(tcp|udp))*$ ]] || return 1
  local rule port
  local -a rules
  IFS=, read -ra rules <<< "$1"
  for rule in "${rules[@]}"; do
    port="${rule%/*}"
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  done
}
keel_validate_config() {
  [[ "$KEEL_CONFIG_VERSION" == 1 ]] && keel_valid_hostname "$KEEL_HOST" && keel_valid_user "$KEEL_ADMIN" &&
    [[ "$KEEL_TS" =~ ^(yes|no)$ && "$KEEL_TS_MODE" =~ ^(openssh|tailscale-ssh)$ &&
       "$KEEL_PROFILE" =~ ^(private|web|tunnel|custom)$ ]] &&
    keel_valid_rules "$KEEL_CUSTOM" || return 1
  [[ "$KEEL_TS_MODE" != tailscale-ssh || "$KEEL_TS" == yes ]] || return 1
  [[ "$KEEL_PROFILE" != custom || -n "$KEEL_CUSTOM" ]]
}
keel_parse_config() {
  local line key value field
  local -A seen=()
  KEEL_CONFIG_VERSION=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || return 1
    key="${line%%=*}"; value="${line#*=}"
    # Read the old writer's empty value without evaluating shell syntax.
    [[ "$value" != "''" ]] || value=''
    case "$key" in
      KEEL_CONFIG_VERSION|KEEL_HOST|KEEL_ADMIN|KEEL_TS|KEEL_TS_MODE|KEEL_PROFILE|KEEL_CUSTOM) ;;
      *) return 1 ;;
    esac
    [[ ! -v "seen[$key]" ]] || return 1
    seen[$key]=1
    printf -v "$key" '%s' "$value"
  done
  for field in "${KEEL_FIELDS[@]}"; do
    [[ "$field" == KEEL_CONFIG_VERSION || -v "seen[$field]" ]] || return 1
  done
  keel_validate_config
}
keel_load_config() {
  keel_trusted_path "$KEEL_CONFIG" || keel_die 'Missing or unsafe configuration. Run keel init.'
  keel_parse_config < "$KEEL_CONFIG" || keel_die 'Invalid configuration; run keel init to migrate old shell-format configuration.'
}
keel_save_config() {
  keel_validate_config || keel_die 'Invalid configuration.'
  local content='' key
  for key in "${KEEL_FIELDS[@]}"; do content+="$key=${!key}"$'\n'; done
  keel_atomic_write "$KEEL_CONFIG" "${content%$'\n'}"
}
keel_config_digest() { sha256sum "$KEEL_CONFIG" | cut -d' ' -f1; }
keel_boot_id() { cat /proc/sys/kernel/random/boot_id; }
keel_ticks() {
  local uptime _unused hz
  read -r uptime _unused < /proc/uptime
  hz="$(getconf CLK_TCK)"
  awk -v u="$uptime" -v h="$hz" 'BEGIN {printf "%.0f\n", u*h}'
}
keel_is_tailscale_ip() {
  local ip
  command -v tailscale >/dev/null || return 1
  while IFS= read -r ip; do [[ "$1" == "$ip" ]] && return 0; done < <(tailscale ip 2>/dev/null)
  return 1
}
keel_install_self() {
  local from="$1"
  keel_no_pending
  [[ -f "$from/bin/keel" && -d "$from/lib" ]] || keel_die 'Incomplete checkout.'
  local file
  for file in /opt/keel /opt/keel/bin /opt/keel/lib; do
    if [[ -e "$file" || -L "$file" ]]; then
      keel_trusted_path "$file" || keel_die "Untrusted install path: $file"
    fi
  done
  install -d -m 755 -o root -g root /opt/keel /opt/keel/bin /opt/keel/lib
  keel_trusted_path /opt/keel/lib || keel_die 'Untrusted installation path.'
  for file in "$from/bin/keel" "$from/lib/"*.sh; do
    [[ -f "$file" && ! -L "$file" ]] || keel_die 'Symlink in installation source.'
  done
  install -m 755 "$from/bin/keel" /opt/keel/bin/keel
  install -m 644 "$from/lib/"*.sh /opt/keel/lib/
  ln -sfn /opt/keel/bin/keel /usr/local/bin/keel
}
