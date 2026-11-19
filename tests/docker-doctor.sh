#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
# Read-only Docker CLI doubles and private JSON fixtures; no engine is contacted.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/doctor.sh
source lib/doctor.sh
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
docker() { fail 'Unexpected real Docker invocation.'; }
# Check the real transport wrapper before overriding its I/O.
(
  timeout() { printf '%s\n' "$@" > "$scratch/transport"; }
  DOCKER_HOST=tcp://do-not-connect.invalid:2375 DOCKER_CONTEXT=remote keel_docker_query info
)
grep -qx 'unix:///var/run/docker.sock' "$scratch/transport"
grep -qx DOCKER_HOST "$scratch/transport"
grep -qx DOCKER_CONTEXT "$scratch/transport"
printf '{"FirewallBackend":{"Driver":"iptables"},"Swarm":{"LocalNodeState":"inactive","ControlAvailable":false}}\n' > "$scratch/info"
printf 'abcdef012345\n' > "$scratch/containers"
printf '{"name":"/app","mode":"bridge","ports":{"3000/tcp":[{"HostIp":"0.0.0.0","HostPort":"3000"}],"443/tcp":[{"HostIp":"::","HostPort":"443"}],"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}],"9090/tcp":null}}\n' > "$scratch/container-data"
printf 'abcdefghijklm\n' > "$scratch/services"
printf '{"name":"dashboard","ports":[{"PublishedPort":3000,"Protocol":"tcp","PublishMode":"ingress"}]}\n' > "$scratch/service-data"
failure=''
keel_docker_query() {
  printf '%s\n' "$*" >> "$scratch/calls"
  case "$1:$2" in
    info:--format) [[ "$failure" != daemon ]] || return 1; cat "$scratch/info" ;;
    container:ls) [[ "$failure" != list ]] || return 1; cat "$scratch/containers" ;;
    container:inspect)
      [[ "$*" != *'{{json .}}'* ]] || fail 'Container inspection requested full secret-bearing data.'
      [[ "$failure" != inspect ]] || return 1; cat "$scratch/container-data" ;;
    service:ls) [[ "$failure" != services ]] || return 1; cat "$scratch/services" ;;
    service:inspect) cat "$scratch/service-data" ;;
    *) fail "Unexpected Docker operation: $*" ;;
  esac
}
report() { keel_docker_doctor "$@" > "$scratch/report"; }
report private ''
grep -q 'Firewall backend.*iptables' "$scratch/report"
grep -q 'Swarm.*inactive' "$scratch/report"
grep -q '0.0.0.0:3000/tcp' "$scratch/report"
grep -q ':::443/tcp' "$scratch/report"
grep -q 'Loopback binding reported' "$scratch/report"
grep -q 'Potential profile conflict' "$scratch/report"
grep -q 'External IPv4/IPv6 reachability' "$scratch/report"
if grep -q '\[PASS' "$scratch/report"; then fail 'Docker report claimed proven security.'; fi
report web ''
grep -q 'matches the web profile' "$scratch/report"
grep -q 'outside public web' "$scratch/report"
report custom '03000/tcp,443/tcp'
grep -q 'matches a custom rule' "$scratch/report"
report '' ''
grep -q 'No prepared application profile' "$scratch/report"
for failure in daemon list inspect; do
  report private ''
  grep -q UNKNOWN "$scratch/report"
done
failure=''
printf 'not-json\n' > "$scratch/container-data"
report private ''
grep -q 'Unsupported container publication data' "$scratch/report"
printf '{"name":"/host","mode":"host","ports":null}\n' > "$scratch/container-data"
report private ''
grep -q 'Host/shared network namespace' "$scratch/report"
printf '{"Swarm":{"LocalNodeState":"active","ControlAvailable":true}}\n' > "$scratch/info"
report private ''
grep -q 'Firewall backend.*unknown' "$scratch/report"
grep -q 'service dashboard \[ingress\]: \*:3000/tcp' "$scratch/report"
grep -q 'advertise-addr does not constrain' "$scratch/report"
printf '{"name":"internal","ports":[]}\n' > "$scratch/service-data"
report private ''
grep -q 'No published Swarm service ports' "$scratch/report"
printf '{"name":"broken","ports":[{"PublishedPort":"bad","Protocol":"tcp"}]}\n' > "$scratch/service-data"
report private ''
grep -q 'Unsupported Swarm publication data' "$scratch/report"
failure=services
report private ''
grep -q 'Cannot list Swarm' "$scratch/report"
failure=''
printf '{"FirewallBackend":{"Driver":"nftables"},"Swarm":{"LocalNodeState":"active","ControlAvailable":false}}\n' > "$scratch/info"
report private ''
grep -q 'Firewall backend.*nftables' "$scratch/report"
grep -q 'worker or unknown manager' "$scratch/report"
# Empty inventory reports an observation rather than a safety conclusion.
: > "$scratch/containers"
printf '{"Swarm":{"LocalNodeState":"inactive"}}\n' > "$scratch/info"
report private ''
grep -q 'no running containers' "$scratch/report"
(
  command() {
    [[ "$*" != '-v docker' ]] || return 1
    builtin command "$@"
  }
  report private ''
)
grep -q 'Docker CLI unavailable' "$scratch/report"
# Doctor still inspects Docker before preparation, without adopting env intent.
(
  keel_require_ubuntu() { :; }
  keel_warn() { printf 'WARN: %s\n' "$*"; }
  keel_load_config() { fail 'Loaded nonexistent config.'; }
  KEEL_CONFIG="$scratch/no-config"
  KEEL_PROFILE=web
  printf 'abcdef012345\n' > "$scratch/containers"
  printf '{"name":"/app","mode":"bridge","ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"80"}]}}\n' > "$scratch/container-data"
  keel_doctor > "$scratch/report"
)
grep -q 'No prepared application profile' "$scratch/report"
printf 'PASS: Docker doctor bindings, profile comparisons, backend/Swarm reporting, malformed/unavailable data and local-only read transport\n'
