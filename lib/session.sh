#!/usr/bin/env bash
# Server-side connection evidence. No caller-provided SSH_* value is trusted.
keel_proc_exe() { readlink -f "/proc/$1/exe"; }
keel_proc_args() { cat "/proc/$1/cmdline"; }
keel_proc_environment() { cat "/proc/$1/environ"; }
keel_proc_parent() { awk '/^PPid:/ {print $2}' "/proc/$1/status"; }
keel_proc_root() { [[ "$(awk '/^Uid:/ {print $2 ":" $3 ":" $4}' "/proc/$1/status")" == 0:0:0 ]]; }
keel_proc_cgroup() { cat "/proc/$1/cgroup"; }
keel_loginctl() { timeout --kill-after=5s 15s /usr/bin/loginctl "$@"; }
keel_proc_start() {
  local stat
  stat="$(cat "/proc/$1/stat")" || return 1
  stat="${stat##*) }"
  awk '{print $20}' <<< "$stat"
}
keel_endpoint() {
  local endpoint="$1" prefix="$2" address port
  port="${endpoint##*:}"; address="${endpoint%:*}"
  address="${address#[}"; address="${address%]}"; address="${address#::ffff:}"
  [[ "$address" =~ ^[0-9a-fA-F:.]+$ && "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port > 0 && 10#$port <= 65535 )) || return 1
  printf -v "${prefix}_IP" '%s' "$address"
  printf -v "${prefix}_PORT" '%s' "$port"
}
keel_openssh_evidence() {
  local pid="$1" exe="$2" line local_endpoint peer_endpoint _unused logs
  local found=0
  while IFS= read -r line; do
    [[ "$line" == *"pid=$pid,"* ]] || continue
    (( found += 1 ))
    read -r _unused _unused local_endpoint peer_endpoint _unused <<< "$line"
  done < <(ss -Htnp state established)
  (( found == 1 )) || return 1
  keel_endpoint "$local_endpoint" KEEL_LOCAL || return 1
  keel_endpoint "$peer_endpoint" KEEL_REMOTE || return 1
  KEEL_CONNECTION_START="$(keel_proc_start "$pid")" || return 1
  [[ "$KEEL_CONNECTION_START" =~ ^[0-9]+$ ]] || return 1
  # Trusted journald fields and monotonic timestamps bind the message to this
  # live root sshd process, rejecting records from a previous use of its PID.
  logs="$(journalctl -q -b --no-pager -o json "_PID=$pid" '_UID=0' "_EXE=$exe")" || return 1
  jq -es --arg prefix "Accepted publickey for $KEEL_ADMIN from $KEEL_REMOTE_IP port $KEEL_REMOTE_PORT ssh2:" \
    --argjson start "$KEEL_CONNECTION_START" --argjson hz "$(getconf CLK_TCK)" '
      any(.[]; ((.MESSAGE | type) == "string") and
        (.MESSAGE | startswith($prefix)) and
        ((.__MONOTONIC_TIMESTAMP | tonumber) * $hz / 1000000 >= $start))
    ' <<< "$logs" >/dev/null || return 1
  KEEL_CONNECTION_ID="$(keel_boot_id):$pid:$KEEL_CONNECTION_START"
}
# Stable adapter for the upstream ssh-conn log format; unknown formats fail closed.
keel_tailscale_journal() {
  jq -rs --arg suffix "$1" --argjson hz "$2" '

    [.[] | select((.MESSAGE | type) == "string") |
      select(.MESSAGE | endswith($suffix)) |
      {id: (.MESSAGE | capture("(?<id>ssh-conn-[0-9]{8}T[0-9]{6}-[a-f0-9]+): handling conn: ").id),
       ticks: ((.__MONOTONIC_TIMESTAMP | tonumber) * $hz / 1000000 | floor)}] |
    sort_by(.ticks) | if length > 0 then .[0] | "\(.id) \(.ticks)" else empty end
  '
}
# login clears its own environment on recent Ubuntu. Recover the terminal only
# from root-owned logind state whose leader is that same privileged ancestor.
keel_tailscale_login_tty() {
  local pid="$1" cgroup session data line key value uid
  local -A fields=()
  keel_proc_root "$pid" || return 1
  cgroup="$(keel_proc_cgroup "$pid")" || return 1
  [[ "$cgroup" =~ ^0::/user\.slice/user-([0-9]+)\.slice/session-([a-zA-Z0-9]+)\.scope$ ]] || return 1
  uid="${BASH_REMATCH[1]}"; session="${BASH_REMATCH[2]}"
  [[ "$(id -u "$KEEL_ADMIN")" == "$uid" ]] || return 1
  data="$(keel_loginctl show-session "$session" -p Id -p Leader -p User -p Name \
    -p TTY -p Remote -p RemoteHost -p Service -p Type -p Class -p Scope)" || return 1
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || return 1
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in Id|Leader|User|Name|TTY|Remote|RemoteHost|Service|Type|Class|Scope) ;; *) return 1 ;; esac
    [[ ! -v "fields[$key]" ]] || return 1
    fields[$key]="$value"
  done <<< "$data"
  [[ "${fields[Id]:-}" == "$session" && "${fields[Leader]:-}" == "$pid" &&
     "${fields[User]:-}" == "$uid" && "${fields[Name]:-}" == "$KEEL_ADMIN" &&
     "${fields[Scope]:-}" == "session-$session.scope" && "${fields[Remote]:-}" == yes &&
     "${fields[Service]:-}" == remote && "${fields[Type]:-}" == tty && "${fields[Class]:-}" == user &&
     "${fields[TTY]:-}" =~ ^pts/[0-9]+$ && "${fields[RemoteHost]:-}" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  KEEL_LOGIN_TTY="${fields[TTY]}"
  KEEL_LOGIN_REMOTE="${fields[RemoteHost]}"
}
# Join three root-daemon records: PTY launch -> session -> original connection.
# The PTY comes from logind, not user argv/environment. Require a unique launch
# near login birth, so recycled terminals or ambiguous records cannot authorize.
keel_tailscale_pty_journal() {
  jq -ers --arg tty "$1" --arg admin "$2" --arg uid "$3" --arg daemon "$4" \
    --argjson birth "$5" --argjson hz "$6" '
    def ticks: (.__MONOTONIC_TIMESTAMP | tonumber) * $hz / 1000000 | floor;
    [.[] | select((.MESSAGE | type) == "string") | {message:.MESSAGE, ticks:ticks}] as $events |
    [ $events[] as $launch |
      ($launch.message | capture("^ssh-session\\((?<session>sess-[0-9]{8}T[0-9]{6}-[a-f0-9]+)\\): starting pty command via session monitor: \\[(?<argv>[^\\r\\n]+) --shell(?: --env-fd=[0-9]+)?\\]$")) as $spawn |
      select(($spawn.argv | startswith($daemon + " be-child ssh ")) and
        ($spawn.argv | contains(" --cmd=") | not)) |
      ($spawn.argv | split(" ")) as $args |
      select(all(["--tty-name=", "--local-user=", "--uid=", "--has-tty="][];
        . as $prefix | ([$args[] | select(startswith($prefix))] | length) == 1)) |
      select(all(["--tty-name="+$tty, "--local-user="+$admin, "--uid="+$uid, "--has-tty=true"][];
        . as $wanted | ([$args[] | select(. == $wanted)] | length) == 1)) |
      select($launch.ticks >= $birth - 5*$hz and $launch.ticks <= $birth + 5*$hz) |
      $events[] as $session |
      ($session.message | capture("^(?<conn>ssh-conn-[0-9]{8}T[0-9]{6}-[a-f0-9]+): starting session: (?<session>sess-[0-9]{8}T[0-9]{6}-[a-f0-9]+)$")) as $link |
      select($link.session == $spawn.session and $session.ticks <= $launch.ticks) |
      $events[] as $connection |
      ($connection.message | capture("^(?<conn>ssh-conn-[0-9]{8}T[0-9]{6}-[a-f0-9]+): handling conn: (?<source>[^ ]+)->(?<user>[a-z_][a-z0-9_-]*)@(?<destination>[^ ]+)$")) as $auth |
      select($auth.conn == $link.conn and $auth.user == $admin and $connection.ticks <= $session.ticks) |
      {id:$auth.conn, ticks:$connection.ticks, source:$auth.source, destination:$auth.destination}
    ] | if length == 1 then .[0] | "\(.id) \(.ticks) \(.source) \(.destination)" else error("Missing or ambiguous trusted PTY connection evidence") end
  '
}
keel_tailscale_evidence() {
  local pid="$1" daemon parent arg exe connection='' monitor='' records result suffix src dst
  local -a args=()
  # A server-spawned but unprivileged helper can have user-controlled metadata.
  # Keep this trust boundary here as well as in the ancestry walker.
  keel_proc_root "$pid" || return 1
  daemon="$(command -v tailscaled)" || return 1
  daemon="$(readlink -f "$daemon")" || return 1
  keel_trusted_path "$daemon" || return 1
  exe="$(keel_proc_exe "$pid")" || return 1
  case "$exe" in
    /usr/bin/login|/usr/bin/su) ;;
    "$daemon")
      mapfile -d '' -t args < <(keel_proc_args "$pid")
      [[ "${args[1]:-} ${args[2]:-}" == 'be-child ssh' ]] || return 1 ;;
    *) return 1 ;;
  esac
  parent="$(keel_proc_parent "$pid")"
  [[ "$(keel_proc_exe "$parent")" == "$daemon" ]] && keel_proc_root "$parent" || return 1
  mapfile -d '' -t args < <(keel_proc_args "$parent")
  if [[ "${args[1]:-} ${args[2]:-}" == 'be-child ssh-monitor' ]]; then
    [[ " ${args[*]} " == *" --local-user=$KEEL_ADMIN "* ]] || return 1
    monitor="$parent"
    parent="$(keel_proc_parent "$monitor")"
    [[ "$(keel_proc_exe "$parent")" == "$daemon" ]] && keel_proc_root "$parent" || return 1
  fi
  [[ "$(keel_systemctl show tailscaled.service -p MainPID --value)" == "$parent" ]] || return 1
  local daemon_start login_start
  daemon_start="$(keel_proc_start "$parent")" || return 1
  login_start="$(keel_proc_start "$pid")" || return 1
  [[ "$daemon_start" =~ ^[0-9]+$ && "$login_start" =~ ^[0-9]+$ ]] || return 1
  records="$(journalctl -q -b --no-pager -o json "_PID=$parent" '_UID=0' "_EXE=$daemon")" || return 1
  # This is the privileged server-created login environment, not the calling
  # user's SSH_CONNECTION. Unprivileged launchers and tmux fail ancestry checks.
  while IFS= read -r -d '' arg; do
    [[ "$arg" != SSH_CONNECTION=* ]] || connection="${arg#SSH_CONNECTION=}"
  done < <(keel_proc_environment "$pid")
  local remote_ip remote_port local_ip local_port extra
  if [[ -z "$connection" ]]; then
    [[ "$exe" == /usr/bin/login && -n "$monitor" ]] || return 1
    keel_tailscale_login_tty "$pid" || return 1
    result="$(keel_tailscale_pty_journal "$KEEL_LOGIN_TTY" "$KEEL_ADMIN" "$(id -u "$KEEL_ADMIN")" \
      "$daemon" "$login_start" "$(getconf CLK_TCK)" <<< "$records")" || return 1
    read -r KEEL_CONNECTION_ID KEEL_CONNECTION_START src dst extra <<< "$result"
    [[ -z "$extra" ]] || return 1
    keel_endpoint "$src" KEEL_REMOTE || return 1
    keel_endpoint "$dst" KEEL_LOCAL || return 1
    [[ "$KEEL_REMOTE_IP" == "$KEEL_LOGIN_REMOTE" ]] || return 1
  else
    read -r remote_ip remote_port local_ip local_port extra <<< "$connection"
    [[ -z "$extra" ]] || return 1
    keel_endpoint "[$remote_ip]:$remote_port" KEEL_REMOTE || return 1
    keel_endpoint "[$local_ip]:$local_port" KEEL_LOCAL || return 1
    src="$KEEL_REMOTE_IP:$KEEL_REMOTE_PORT"; dst="$KEEL_LOCAL_IP:$KEEL_LOCAL_PORT"
    [[ "$KEEL_REMOTE_IP" != *:* ]] || src="[$KEEL_REMOTE_IP]:$KEEL_REMOTE_PORT"
    [[ "$KEEL_LOCAL_IP" != *:* ]] || dst="[$KEEL_LOCAL_IP]:$KEEL_LOCAL_PORT"
    suffix=": handling conn: $src->$KEEL_ADMIN@$dst"
    # The oldest matching connection event prevents a new multiplexed session
    # from presenting its session creation time as a new authentication. Reused
    # tuples are conservatively rejected if their old evidence predates changes.
    result="$(keel_tailscale_journal "$suffix" "$(getconf CLK_TCK)" <<< "$records")" || return 1
    read -r KEEL_CONNECTION_ID KEEL_CONNECTION_START extra <<< "$result"
  fi
  [[ "$KEEL_LOCAL_PORT" == 22 ]] && keel_is_tailscale_ip "$KEEL_LOCAL_IP" || return 1
  tailscale debug prefs | jq -e '.RunSSH == true' >/dev/null || return 1
  [[ -n "$KEEL_CONNECTION_ID" && "$KEEL_CONNECTION_START" =~ ^[0-9]+$ && -z "$extra" ]] || return 1
  [[ "$(keel_proc_start "$pid")" == "$login_start" && "$(keel_proc_start "$parent")" == "$daemon_start" &&
     "$(keel_proc_parent "$pid")" == "${monitor:-$parent}" ]] && keel_proc_root "$pid" || return 1
  (( KEEL_CONNECTION_START >= daemon_start )) || return 1
  # A delayed log message must not make an already-open login appear fresh.
  (( KEEL_CONNECTION_START <= login_start )) || KEEL_CONNECTION_START="$login_start"
  KEEL_CONNECTION_ID="$(keel_boot_id):$parent:$daemon_start:$KEEL_CONNECTION_ID"
}
keel_session_evidence() {
  local pid="$BASHPID" exe n=0
  [[ -n "${SUDO_USER:-}" && "$SUDO_USER" == "$KEEL_ADMIN" && "$SUDO_USER" != root ]] || return 1
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && n < 100 )); do
    (( n += 1 ))
    exe="$(keel_proc_exe "$pid" 2>/dev/null)" || return 1
    if keel_proc_root "$pid"; then
      case "$KEEL_TS_MODE:$exe" in
        openssh:/usr/sbin/sshd|openssh:/usr/lib/openssh/sshd-session)
          if keel_openssh_evidence "$pid" "$exe"; then return 0; fi ;;
        tailscale-ssh:*/tailscaled|tailscale-ssh:/usr/bin/login|tailscale-ssh:/usr/bin/su)
          if keel_tailscale_evidence "$pid"; then return 0; fi ;;
      esac
    fi
    pid="$(keel_proc_parent "$pid")" || return 1
  done
  return 1
}
keel_tailscale_status_json() {
  timeout --kill-after=1s 3s tailscale --socket=/var/run/tailscale/tailscaled.sock status --json
}
# Advisory display only. A name never replaces connection/authentication proof.
# With an IP argument, require metadata for this same proven destination address.
keel_magicdns_names() {
  jq -er --arg ip "${2:-}" '
    def dns:
      type == "string" and length <= 253 and
      (split(".") | length >= 2 and all(.[];
        length >= 1 and length <= 63 and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")));
    select(.CurrentTailnet.MagicDNSEnabled == true) |
    (.CurrentTailnet.MagicDNSSuffix | ascii_downcase | sub("\\.$"; "")) as $suffix |
    (.Self.DNSName | ascii_downcase | sub("\\.$"; "")) as $name |
    select(($suffix | dns) and ($name | dns)) |
    .Self.TailscaleIPs as $ips |
    select($ips | type == "array" and length > 0 and all(.[]; type == "string")) |
    select($ip == "" or ($ips | index($ip)) != null) |
    ($name | split(".")[0]) as $short |
    select($name == ($short + "." + $suffix)) |
    "\($short) \($name)"
  ' <<< "$1" 2>/dev/null
}
keel_tailscale_ssh_state() {
  local prefs state
  prefs="$(tailscale debug prefs)" || { printf 'unknown\n'; return 0; }
  state="$(jq -er 'if .RunSSH == true then "enabled" elif .RunSSH == false then "disabled" else error("Unknown RunSSH state") end' <<< "$prefs")" || {
    printf 'unknown\n'; return 0;
  }
  printf '%s\n' "$state"
}
keel_verify_identity() {
  keel_load_config
  if [[ "$KEEL_TS_MODE" == tailscale-ssh ]]; then
    case "$(keel_tailscale_ssh_state)" in
      enabled) ;;
      disabled) keel_die 'Tailscale SSH was selected but its server is disabled. Configure network and SSH policy for this server tag and administrator, keep recovery access, then run sudo keel tailscale-ssh. Do not run secure yet.' ;;
      *) keel_die 'Cannot inspect Tailscale SSH server state. Check tailscaled and sudo tailscale debug prefs; verification remains blocked.' ;;
    esac
  fi
  if ! keel_session_evidence; then
    if [[ "$KEEL_TS_MODE" == tailscale-ssh ]]; then
      if ( KEEL_TS_MODE=openssh; keel_session_evidence ); then
        keel_die 'This is an OpenSSH public-key login, but Tailscale SSH identity authentication was selected. Keep this recovery session; open a fresh interactive login through the Tailscale address or MagicDNS name, then run keel verify there.'
      fi
      keel_die 'Cannot establish trusted Tailscale SSH login evidence for this administrator. Use a fresh interactive Tailscale SSH login, not a public-IP login or remote command. If Tailscale denies the connection, check its SSH policy destination tag and local user. Otherwise inspect trusted journal/logind records; see docs/security.md. Do not bypass verification.'
    fi
    keel_die 'Cannot prove OpenSSH public-key authentication for this administrator. Reconnect without multiplexing using an authorized key; trusted journald publickey records and a supported sshd process are required. See docs/security.md.'
  fi
  if [[ "$KEEL_TS" == yes ]]; then
    keel_is_tailscale_ip "$KEEL_LOCAL_IP" || keel_die "Connect through this host's Tailscale address."
  elif keel_is_tailscale_ip "$KEEL_LOCAL_IP"; then
    keel_die 'Public OpenSSH was selected; verify through the public path or select Tailscale in init.'
  fi
  [[ "$KEEL_CONNECTION_START" =~ ^[0-9]+$ ]] || keel_die 'Invalid connection evidence.'
}
keel_record_boundary() {
  printf '%s %s %s\n' "$(keel_boot_id)" "$(keel_ticks)" "$(keel_config_digest)"
}
keel_after_boundary() {
  local boot ticks digest extra
  read -r boot ticks digest extra < "$1" || return 1
  [[ -z "$extra" && "$ticks" =~ ^[0-9]+$ && "$boot" == "$(keel_boot_id)" && "$digest" == "$(keel_config_digest)" ]] || return 1
  (( KEEL_CONNECTION_START > ticks ))
}
