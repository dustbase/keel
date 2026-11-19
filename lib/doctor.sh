#!/usr/bin/env bash
# Diagnostics describe local observations, never an external security guarantee.
keel_docker_query() {
  # Never follow a caller's remote Docker context or DOCKER_HOST.
  timeout --kill-after=2s 15s env -u DOCKER_HOST -u DOCKER_CONTEXT \
    -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH docker --host unix:///var/run/docker.sock "$@"
}
keel_docker_binding() {
  local kind="$1" name="$2" mode="$3" address="$4" port="$5" protocol="$6" profile="$7" custom="$8" rule
  keel_ui_status INFO "Docker $kind $name [$mode]: $address:$port/$protocol"
  if [[ "$address" == 127.* || "$address" == ::1 ]]; then
    keel_ui_status INFO 'Loopback binding reported; external isolation is not verified.'
    return 0
  fi
  case "$profile" in
    private|tunnel)
      keel_ui_status WARN 'Potential profile conflict: non-loopback publication; this profile intends no public application ports.' ;;
    web)
      if [[ "$protocol" == tcp && ( "$port" == 80 || "$port" == 443 ) ]]; then
        keel_ui_status INFO 'Published port matches the web profile; effective filtering and reachability remain unknown.'
      else keel_ui_status WARN 'Potential profile conflict: this publication is outside public web TCP 80/443.'; fi ;;
    custom)
      local -a rules=()
      IFS=, read -ra rules <<< "$custom"
      for rule in "${rules[@]}"; do
        if [[ "$protocol" == "${rule#*/}" && "$port" == "$((10#${rule%/*}))" ]]; then
          keel_ui_status INFO 'Published port matches a custom rule; effective filtering and reachability remain unknown.'
          return 0
        fi
      done
      keel_ui_status WARN 'Potential profile conflict: publication does not match a custom application rule.' ;;
    *) keel_ui_status UNKNOWN 'No prepared application profile available for comparison.' ;;
  esac
}
keel_docker_containers() {
  local listing id data rows kind name mode address port protocol
  local -a ids=()
  listing="$(keel_docker_query container ls -q 2>/dev/null)" || { keel_ui_status UNKNOWN 'Cannot list running Docker containers.'; return 0; }
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$id" =~ ^[a-f0-9]{12,64}$ ]] || { keel_ui_status UNKNOWN 'Unsupported container ID response.'; return 0; }
    ids+=("$id")
  done <<< "$listing"
  (( ${#ids[@]} )) || { keel_ui_status INFO 'Docker reports no running containers.'; return 0; }
  (( ${#ids[@]} <= 100 )) || { keel_ui_status UNKNOWN 'More than 100 containers; automatic inspection skipped.'; return 0; }
  # Project only network fields: never retrieve container environment/secrets.
  data="$(keel_docker_query container inspect --format \
    '{"name":{{json .Name}},"mode":{{json .HostConfig.NetworkMode}},"ports":{{json .NetworkSettings.Ports}}}' "${ids[@]}" 2>/dev/null)" || {
    keel_ui_status UNKNOWN 'Container inspection failed or containers changed during inspection.'; return 0;
  }
  rows="$(jq -rs --argjson count "${#ids[@]}" '
    def clean: gsub("[\\x00-\\x1f\\x7f]"; "?") | .[0:160];
    def binding: type == "object" and (.HostIp | type == "string") and
      (.HostPort | type == "string" and test("^[0-9]{1,5}$")) and
      (.HostPort | tonumber) >= 1 and (.HostPort | tonumber) <= 65535;
    if length != $count or (all(.[]; type == "object" and (.name | type == "string" and length > 0) and
      (.mode | type == "string" and length > 0) and (.ports == null or (.ports | type == "object"))) | not)
      then error("Unsupported container response") else . end |
    .[] | . as $c |
    ["container", ($c.name | clean), ($c.mode | clean), "-", "-", "-"] | @tsv,
    ($c.ports // {} | to_entries[] |
      if (.key | test("^[0-9]{1,5}/(tcp|udp|sctp)$") | not) then error("Unsupported port") else . end |
      . as $p | if .value == null then empty else
        if (.value | type != "array") then error("Unsupported bindings") else .value[] end |
        if binding then . else error("Unsupported binding") end |
        ["binding", ($c.name | clean), ($c.mode | clean),
         (if .HostIp == "" then "*" else .HostIp | clean end),
         (.HostPort | tonumber | tostring), ($p.key | split("/")[1])] | @tsv end)
  ' <<< "$data" 2>/dev/null)" || { keel_ui_status UNKNOWN 'Unsupported container publication data; no isolation conclusion.'; return 0; }
  while IFS=$'\t' read -r kind name mode address port protocol; do
    if [[ "$kind" == container ]]; then
      keel_ui_field Container "$name (network=$mode)"
      case "$mode" in host|container:*) keel_ui_status WARN 'Host/shared network namespace; published-port metadata is incomplete for this container.' ;; esac
    else
      keel_docker_binding container "$name" "$mode" "$address" "$port" "$protocol" "$1" "$2"
    fi
  done <<< "$rows"
}
keel_docker_services() {
  local listing id data rows name mode port protocol
  local -a ids=()
  listing="$(keel_docker_query service ls -q 2>/dev/null)" || { keel_ui_status UNKNOWN 'Cannot list Swarm service publications.'; return 0; }
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$id" =~ ^[a-z0-9]{12,64}$ ]] || { keel_ui_status UNKNOWN 'Unsupported Swarm service ID response.'; return 0; }
    ids+=("$id")
  done <<< "$listing"
  (( ${#ids[@]} )) || { keel_ui_status INFO 'Swarm reports no services.'; return 0; }
  (( ${#ids[@]} <= 100 )) || { keel_ui_status UNKNOWN 'More than 100 services; automatic inspection skipped.'; return 0; }
  data="$(keel_docker_query service inspect --format \
    '{"name":{{json .Spec.Name}},"ports":{{json .Endpoint.Ports}}}' "${ids[@]}" 2>/dev/null)" || {
    keel_ui_status UNKNOWN 'Swarm service inspection failed.'; return 0;
  }
  rows="$(jq -rs --argjson count "${#ids[@]}" '
    if length != $count then error("Missing services") else . end |
    .[] | if (.name | type != "string" or length == 0) or (.ports != null and (.ports | type != "array"))
      then error("Unsupported service") else . end | . as $s | (.ports // [])[] |
    if (.PublishedPort | type == "number" and . >= 1 and . <= 65535 and floor == .) and
      (.Protocol == "tcp" or .Protocol == "udp" or .Protocol == "sctp") and
      (.PublishMode == null or .PublishMode == "ingress" or .PublishMode == "host")
      then [($s.name | gsub("[\\x00-\\x1f\\x7f]"; "?") | .[0:160]),
        (.PublishMode // "ingress"), (.PublishedPort | tostring), .Protocol] | @tsv
      else error("Unsupported service publication") end
  ' <<< "$data" 2>/dev/null)" || { keel_ui_status UNKNOWN 'Unsupported Swarm publication data.'; return 0; }
  if [[ -z "$rows" ]]; then keel_ui_status INFO 'No published Swarm service ports reported.'; return 0; fi
  while IFS=$'\t' read -r name mode port protocol; do
    keel_docker_binding service "$name" "$mode" '*' "$port" "$protocol" "$1" "$2"
  done <<< "$rows"
  keel_ui_status WARN 'Swarm publication can span node addresses; advertise-addr does not constrain service bindings.'
}
keel_docker_inspect() {
  local profile="${1:-}" custom="${2:-}" info backend swarm manager
  info="$(keel_docker_query info --format '{{json .}}' 2>/dev/null | jq -ec \
    'if type != "object" then error("Unsupported info") else
      {backend:(.FirewallBackend.Driver // "unknown"), swarm:(.Swarm.LocalNodeState // "unknown"), manager:.Swarm.ControlAvailable} end' 2>/dev/null)" || {
    keel_ui_status UNKNOWN 'Local Docker daemon unavailable or info response unsupported.'; return 0;
  }
  backend="$(jq -r 'if .backend == "iptables" or .backend == "nftables" then .backend else "unknown" end' <<< "$info")"
  swarm="$(jq -r 'if .swarm == "active" or .swarm == "inactive" or .swarm == "pending" or .swarm == "locked" then .swarm else "unknown" end' <<< "$info")"
  manager="$(jq -r 'if .manager == true then "true" elif .manager == false then "false" else "unknown" end' <<< "$info")"
  keel_ui_field "Firewall backend" "$backend"
  keel_ui_field Swarm "$swarm"
  keel_ui_field Manager "$manager"
  [[ "$backend" != unknown ]] || keel_ui_status UNKNOWN 'Docker did not report a recognized effective firewall backend; no backend inferred from configuration.'
  keel_docker_containers "$profile" "$custom"
  if [[ "$swarm" == active ]]; then
    if [[ "$manager" == true ]]; then keel_docker_services "$profile" "$custom"
    else keel_ui_status UNKNOWN 'Swarm service inventory unavailable on this node (worker or unknown manager state); container ports alone are incomplete.'; fi
  elif [[ "$swarm" != inactive ]]; then keel_ui_status UNKNOWN 'Swarm service publication state is not established.'; fi
}
keel_docker_doctor() {
  keel_ui_section Docker
  if ! command -v docker >/dev/null 2>&1; then
    keel_ui_status INFO 'Docker CLI unavailable; Docker inspection skipped.'
    return 0
  fi
  keel_ui_field Endpoint /var/run/docker.sock
  keel_docker_inspect "${1:-}" "${2:-}"
  keel_ui_section 'Docker limits'
  keel_ui_status UNKNOWN 'External IPv4/IPv6 reachability, effective Docker/UFW filtering and other/rootless engines are not verified.'
  keel_ui_status UNKNOWN 'Network drivers, direct routing and host-network listeners require separate review; publication metadata is not a complete exposure inventory.'
  keel_ui_status WARN 'Docker publication may bypass UFW. IPv4-only container networks do not prove host IPv6 ports are closed.'
}
keel_doctor_tailscale() {
  keel_ui_section Tailscale
  if ! command -v tailscale >/dev/null 2>&1; then
    keel_ui_status INFO 'Tailscale CLI unavailable.'
    return 0
  fi
  local data state online health ssh
  data="$(keel_tailscale_status_json 2>/dev/null)" || {
    keel_ui_status UNKNOWN 'Cannot query Tailscale status; service and peer health are unverified.'
    return 0
  }
  if ! jq -e 'type == "object" and (.BackendState | type == "string") and
      (.Health == null or (.Health | type == "array" and all(.[]; type == "string")))' <<< "$data" >/dev/null 2>&1; then
    keel_ui_status UNKNOWN 'Unsupported Tailscale status response; health remains unverified.'
    return 0
  fi
  state="$(jq -r '.BackendState' <<< "$data")"
  online="$(jq -r 'if .Self.Online == true then "online" elif .Self.Online == false then "offline" else "unknown" end' <<< "$data")"
  keel_ui_field Service "$state"
  keel_ui_field Node "$online"
  keel_magicdns_report "$data"
  [[ "$state" == Running && "$online" == online ]] || keel_ui_status WARN 'Tailscale is not reporting a running, online node. Check its health before relying on tailnet access.'
  health="$(jq -r '(.Health // [])[]' <<< "$data")"
  if [[ -n "$health" ]]; then
    while IFS= read -r health; do keel_ui_status WARN "$health"; done <<< "$health"
  else keel_ui_status INFO 'No Tailscale health warnings reported; peer reachability is not verified.'; fi
  ssh="$(keel_tailscale_ssh_state)"
  case "$ssh" in
    enabled) keel_ui_field 'SSH server' 'Tailscale SSH enabled' ;;
    disabled)
      keel_ui_field 'SSH server' 'Tailscale SSH disabled'
      [[ "$KEEL_TS_MODE" != tailscale-ssh ]] || keel_ui_status WARN 'Selected Tailscale SSH mode requires its server to be enabled before verification.' ;;
    *) keel_ui_status UNKNOWN 'Tailscale SSH server state could not be inspected.' ;;
  esac
  keel_ui_status UNKNOWN 'Tailnet network and SSH policies are externally managed; UFW does not prove tailnet isolation.'
}
keel_doctor() {
  keel_require_ubuntu
  # shellcheck disable=SC2034 # Dynamically scoped counters consumed by common UI helpers.
  local KEEL_UI_COUNT=yes KEEL_UI_PASSED=0 KEEL_UI_WARNED=0 KEEL_UI_UNKNOWN=0 KEEL_UI_ERRORS=0
  local ufw_output policy value key
  keel_ui_section 'Keel / Doctor'
  keel_ui_field Host "$(hostname)"
  keel_ui_field Mode read-only
  if [[ ! -f "$KEEL_CONFIG" ]]; then
    keel_ui_status WARN 'No Keel configuration; application intent has not been prepared.'
    keel_docker_doctor '' ''
    keel_ui_summary
    keel_ui_next 'sudo keel init  (interactive preparation; review before applying)'
    return 0
  fi
  keel_load_config
  keel_ui_section Configuration
  keel_ui_field Administrator "$KEEL_ADMIN"
  keel_ui_field 'Application profile' "$KEEL_PROFILE"
  keel_ui_field Authentication "$(keel_access_label "$KEEL_TS" "$KEEL_TS_MODE")"
  keel_ui_section 'SSH and firewall'
  # Diagnostic contexts are local samples, never global evidence for Match rules.
  # shellcheck disable=SC2034
  KEEL_REMOTE_IP=127.0.0.1 KEEL_LOCAL_IP=127.0.0.1 KEEL_LOCAL_PORT=22
  if keel_ssh_check; then keel_ui_status PASS 'Supported OpenSSH policy disables root, password and keyboard-interactive login.'
  else keel_ui_status WARN 'OpenSSH policy differs or cannot be evaluated safely.'; fi
  if command -v ufw >/dev/null; then
    if ufw_output="$(keel_ufw status verbose)"; then
      printf '%s\n' "$ufw_output" | keel_ui_details
      if [[ -f "$KEEL_STATE/managed-firewall" && "$(cat "$KEEL_STATE/managed-firewall")" == "$(keel_security_digest)" ]]; then
        keel_ui_status PASS 'Local SSH/UFW configuration matches the confirmed baseline.'
      else keel_ui_status UNKNOWN 'No matching confirmed SSH/UFW baseline.'; fi
    else keel_ui_status UNKNOWN 'Cannot query UFW; effective firewall state is unverified.'; fi
  else keel_ui_status WARN 'UFW unavailable.'; fi
  keel_doctor_tailscale
  keel_ui_section 'Security updates'
  if command -v apt-config >/dev/null && policy="$(apt-config dump)"; then
    for key in 'APT::Periodic::Update-Package-Lists' 'APT::Periodic::Unattended-Upgrade' 'Unattended-Upgrade::Automatic-Reboot'; do
      value="$(sed -n "s/^$key \"\\([^\"]*\\)\";$/\\1/p" <<< "$policy")"
      keel_ui_field "${key##*::}" "${value:-unknown}"
    done
    if grep -qx 'APT::Periodic::Update-Package-Lists "1";' <<< "$policy" &&
       grep -qx 'APT::Periodic::Unattended-Upgrade "1";' <<< "$policy" &&
       grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' <<< "$policy"; then
      keel_ui_status PASS 'Effective security-update policy is enabled; automatic reboot is disabled.'
    else keel_ui_status WARN 'Effective update policy differs or is incomplete.'; fi
    keel_ui_status UNKNOWN 'Package installation and successful update execution require separate checks.'
  else keel_ui_status UNKNOWN 'Effective APT policy is unavailable.'; fi
  [[ ! -e /var/run/reboot-required ]] || keel_ui_status INFO 'Reboot required; Keel will not reboot automatically.'
  keel_docker_doctor "$KEEL_PROFILE" "$KEEL_CUSTOM"
  keel_ui_section Recovery
  if [[ -f "$KEEL_STATE/preparation-status" ]]; then
    keel_ui_field Preparation "$(cat "$KEEL_STATE/preparation-status")"
  fi
  keel_status
  keel_ui_section Limits
  keel_ui_status UNKNOWN 'External IPv4/IPv6 reachability and provider firewall policy require external testing.'
  keel_ui_summary
  keel_ui_next 'Review warnings and unknowns above. Keep independent recovery access available.'
}
