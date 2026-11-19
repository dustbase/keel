#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
# Isolated state and daemon doubles: no host or tailnet mutations.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/prepare.sh
source lib/prepare.sh
# shellcheck source=lib/session.sh
source lib/session.sh
# shellcheck source=lib/security.sh
source lib/security.sh
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
KEEL_STATE="$scratch/state"
mkdir "$KEEL_STATE"
KEEL_HOST=node KEEL_ADMIN=admin KEEL_TS=yes KEEL_TS_MODE=tailscale-ssh KEEL_PROFILE=private KEEL_CUSTOM=''
keel_load_config() { :; }
keel_trusted_path() { [[ -f "$1" && ! -L "$1" ]]; }
keel_record_boundary() { printf 'new-boundary\n'; }
keel_atomic_write() { printf '%s\n' "$2" > "$1"; }
questions=0 decline=0 result=success evidence=none
keel_yes() { questions=$((questions + 1)); (( questions != decline )); }
tailscale() {
  case "$*" in
    'debug prefs') cat "$scratch/prefs" ;;
    'set --ssh')
      [[ ! -e "$KEEL_STATE/verified" && ! -e "$KEEL_STATE/secured" ]] || fail 'Switch preceded invalidation.'
      [[ "$(cat "$KEEL_STATE/prepared")" == new-boundary ]] || fail 'Switch preceded durable boundary.'
      touch "$scratch/switched"
      [[ "$result" != interrupted ]] || return 143
      [[ "$result" != failure ]] || return 1
      [[ "$result" != unconfirmed ]] || return 0
      printf '{"RunSSH":true}\n' > "$scratch/prefs" ;;
    *) fail 'Unexpected Tailscale command.' ;;
  esac
}
keel_session_evidence() {
  if [[ "$KEEL_TS_MODE:$evidence" == openssh:openssh ]]; then
    KEEL_LOCAL_IP=203.0.113.1
    return 0
  fi
  return 1
}
keel_is_tailscale_ip() { [[ "$1" == 100.* ]]; }
reject() {
  if ( "$@" ) > "$scratch/output" 2>&1; then fail "Unexpected success: $*"; fi
}
reset_fixture() {
  printf '{"RunSSH":false}\n' > "$scratch/prefs"
  printf old > "$KEEL_STATE/verified"
  printf old > "$KEEL_STATE/secured"
  printf old > "$KEEL_STATE/prepared"
  rm -f "$scratch/switched"
  questions=0 decline=0 result=success
}
reset_fixture
reject keel_verify_identity
grep -q 'server is disabled' "$scratch/output"
printf '{}\n' > "$scratch/prefs"
reject keel_verify_identity
grep -q 'Cannot inspect' "$scratch/output"
reject keel_enable_tailscale_ssh
[[ ! -e "$scratch/switched" ]] || fail 'Unknown daemon state switched servers.'
printf '{"RunSSH":true}\n' > "$scratch/prefs"
evidence=openssh
reject keel_verify_identity
grep -q 'This is an OpenSSH public-key login' "$scratch/output"
evidence=none
# Caller environment still cannot substitute for trusted connection evidence.
export SSH_CONNECTION='100.64.0.1 12345 100.64.0.2 22'
reject keel_verify_identity
grep -q 'Cannot establish trusted Tailscale SSH login evidence' "$scratch/output"
keel_enable_tailscale_ssh > "$scratch/output"
grep -q 'already enabled' "$scratch/output"
[[ "$(cat "$KEEL_STATE/verified")" == old ]] || fail 'No-op enable invalidated evidence.'
for decline_at in 1 2 3; do
  reset_fixture
  decline="$decline_at"
  keel_enable_tailscale_ssh > "$scratch/output" 2>&1
  [[ ! -e "$scratch/switched" && "$(cat "$KEEL_STATE/verified")" == old ]] || fail 'Declined checklist changed state.'
done
reset_fixture
(
  keel_atomic_write() { return 1; }
  reject keel_enable_tailscale_ssh
)
[[ ! -e "$scratch/switched" ]] || fail 'Failed durable boundary allowed server switch.'
for outcome in failure interrupted unconfirmed; do
  reset_fixture
  result="$outcome"
  reject keel_enable_tailscale_ssh
  [[ -e "$scratch/switched" && ! -e "$KEEL_STATE/verified" && ! -e "$KEEL_STATE/secured" ]] || fail 'Failed switch retained stale verification.'
  if grep -q 'Establish a new Tailscale SSH connection' "$scratch/output"; then fail 'Failed enable reported success.'; fi
done
reset_fixture
keel_enable_tailscale_ssh > "$scratch/output" 2>&1
[[ -e "$scratch/switched" ]] || fail 'Confirmed enable did not switch.'
grep -q 'Establish a new Tailscale SSH connection' "$scratch/output"
reset_fixture
touch "$KEEL_STATE/managed-firewall"
reject keel_enable_tailscale_ssh
[[ ! -e "$scratch/switched" ]] || fail 'Hardened host switched without proven public recovery.'
rm "$KEEL_STATE/managed-firewall"
touch "$KEEL_STATE/pending"
reject keel_enable_tailscale_ssh
[[ ! -e "$scratch/switched" ]] || fail 'Pending transaction allowed switch.'
printf 'PASS: Tailscale setup gates, mode diagnostics, enable failures and interrupted-state invalidation\n'
