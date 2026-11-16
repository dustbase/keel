#!/usr/bin/env bash
keel_sshd() { timeout --kill-after=5s 15s /usr/sbin/sshd "$@"; }
keel_ssh_layout_file() {
  local file="$1" line trimmed keyword
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" && "$trimmed" != \#* ]] || continue
    keyword="${trimmed%%[[:space:]=]*}"
    case "${keyword,,}" in
      match) return 1 ;;
      include)
        [[ "$file" == /etc/ssh/sshd_config && "$trimmed" =~ ^[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+/etc/ssh/sshd_config.d/\*.conf[[:space:]]*$ ]] || return 1 ;;
    esac
  done
}
keel_ssh_preflight() {
  local file line
  [[ -d /etc/ssh/sshd_config.d && -f /etc/ssh/sshd_config ]] || return 1
  # A sample of Match contexts cannot prove policy for every possible source.
  for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -e "$file" ]] || continue
    keel_trusted_path "$file" || return 1
    # shellcheck disable=SC2094 # Pure validator reads stdin; it does not modify the file.
    keel_ssh_layout_file "$file" < "$file" || return 1
  done
  # A drop-in has no effect if the main config never includes it.
  grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*.conf[[:space:]]*$' /etc/ssh/sshd_config || return 1
  if [[ -f /etc/default/ssh ]]; then
    line="$(sed -n -E 's/^[[:space:]]*SSHD_OPTS=(.*)/\1/p' /etc/default/ssh)"
    [[ -z "$line" || "$line" == '""' || "$line" == "''" ]] || return 1
  fi
  line="$(keel_systemctl show ssh.service -p ExecStart --value)" || return 1
  [[ "$line" == *'/usr/sbin/sshd'* && ! "$line" =~ [[:space:]]-[fop] ]] || return 1
  keel_systemctl is-active --quiet ssh.service || return 1
  keel_sshd -t
}
keel_effective_hardened() {
  local effective="$1" setting
  for setting in 'permitrootlogin no' 'passwordauthentication no' \
    'kbdinteractiveauthentication no' 'pubkeyauthentication yes'; do
    # OpenSSH versions differ in the capitalization of effective keywords.
    grep -qxi "$setting" <<< "$effective" || return 1
  done
}
keel_ssh_check() {
  keel_ssh_preflight || return 1
  local effective user
  effective="$(keel_sshd -T)" || return 1
  keel_effective_hardened "$effective" || return 1
  for user in "$KEEL_ADMIN" root; do
    effective="$(keel_sshd -T -C "user=$user,addr=$KEEL_REMOTE_IP,host=$KEEL_REMOTE_IP,laddr=$KEEL_LOCAL_IP,lport=$KEEL_LOCAL_PORT")" || return 1
    keel_effective_hardened "$effective" || return 1
  done
}
keel_listener_check() {
  local line state _unused endpoint found=1
  while IFS= read -r line; do
    # ss -l includes State before Recv-Q, Send-Q, and the local endpoint.
    read -r state _unused _unused endpoint _unused <<< "$line"
    [[ "$state" == LISTEN ]] || continue
    [[ "${endpoint##*:}" != "$KEEL_LOCAL_PORT" ]] || found=0
  done < <(ss -Hltn)
  return "$found"
}
keel_write_ssh() {
  local tmp
  tmp="$(mktemp /etc/ssh/sshd_config.d/.keel.XXXXXX)" || return 1
  printf '%s\n' 'PermitRootLogin no' 'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' 'PubkeyAuthentication yes' > "$tmp" || return 1
  chmod 644 "$tmp" && mv -fT "$tmp" "$KEEL_SSH_DROPIN"
}
