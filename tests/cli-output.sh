#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
# Human output fixtures. No host authentication, policy or service is changed.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/session.sh
source lib/session.sh
# shellcheck source=lib/doctor.sh
source lib/doctor.sh
scratch="$(mktemp -d /tmp/keel-cli-test.XXXXXXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TERM=xterm keel_ui_status PASS 'plain redirected output' > "$scratch/plain"
if grep -q $'\033' "$scratch/plain"; then fail 'Redirected output contains ANSI.'; fi
grep -q '\[PASS' "$scratch/plain"
keel_warn 'recoverable warning' > "$scratch/stdout" 2> "$scratch/stderr"
[[ ! -s "$scratch/stdout" ]] || fail 'Warning leaked to stdout.'
grep -q recoverable "$scratch/stderr"
if ( keel_die 'stop here' ) > "$scratch/stdout" 2> "$scratch/stderr"; then fail 'Error did not fail.'; fi
grep -q '\[ERROR' "$scratch/stderr"
keel_ui_status INFO $'untrusted\033[31m text' > "$scratch/sanitized"
if grep -q $'\033' "$scratch/sanitized"; then fail 'Message injected terminal controls.'; fi
cat > "$scratch/color.sh" <<EOF
#!/bin/bash
source "$PWD/lib/common.sh"
keel_ui_status PASS 'TTY color probe'
EOF
# A real pseudo-terminal exercises color policy rather than mocking -t.
script -q -c "env -u NO_COLOR TERM=xterm bash $scratch/color.sh" /dev/null > "$scratch/color"
grep -q $'\033' "$scratch/color" || fail 'TTY color was not enabled.'
script -q -c "env NO_COLOR= TERM=xterm bash $scratch/color.sh" /dev/null > "$scratch/no-color"
if grep -q $'\033' "$scratch/no-color"; then fail 'NO_COLOR was ignored.'; fi
script -q -c "env -u NO_COLOR TERM=dumb bash $scratch/color.sh" /dev/null > "$scratch/dumb"
if grep -q $'\033' "$scratch/dumb"; then fail 'TERM=dumb was ignored.'; fi
cat > "$scratch/wrap.sh" <<EOF
#!/bin/bash
source "$PWD/lib/common.sh"
COLUMNS=40 keel_ui_status WARN 'A long warning stays readable across several lines in a narrow terminal without losing its status label or words.'
EOF
script -q -c "env NO_COLOR=1 TERM=xterm bash $scratch/wrap.sh" /dev/null | tr -d '\r' > "$scratch/wrapped"
awk 'length > 40 {exit 1}' "$scratch/wrapped" || fail 'Narrow-terminal prose was not wrapped.'
grep -q '\[WARN\]' "$scratch/wrapped"
# Full doctor presentation preserves health failures without dumping peer lists.
KEEL_CONFIG="$scratch/config"
KEEL_STATE="$scratch/state"
mkdir "$KEEL_STATE"
touch "$KEEL_CONFIG"
printf baseline > "$KEEL_STATE/managed-firewall"
keel_require_ubuntu() { :; }
hostname() { printf fixture-host; }
keel_load_config() { KEEL_ADMIN=admin KEEL_PROFILE=private KEEL_TS_MODE=openssh KEEL_CUSTOM=''; }
keel_ssh_check() { return 0; }
ufw() { fail 'Unexpected raw UFW invocation.'; }
keel_ufw() { printf 'Status: active\n22/tcp ALLOW IN Anywhere\n'; }
keel_security_digest() { printf baseline; }
apt-config() {
  printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' \
    'APT::Periodic::Unattended-Upgrade "1";' 'Unattended-Upgrade::Automatic-Reboot "false";'
}
tailscale() {
  [[ "$*" == 'debug prefs' ]] || fail 'Unexpected Tailscale query.'
  printf '{"RunSSH":false}\n'
}
timeout() {
  [[ "$*" == *'tailscale status --json' ]] || fail 'Unexpected timed command.'
  cat "$scratch/tailscale"
}
keel_docker_doctor() { keel_ui_section Docker; keel_ui_status INFO 'Docker fixture; no engine contacted.'; }
keel_status() { keel_ui_status INFO 'No pending security transaction.'; }
printf '{"BackendState":"Running","Self":{"Online":false},"Health":["Unable to connect to the coordination server"],"Peer":{"private-peer-name":{}}}\n' > "$scratch/tailscale"
keel_doctor > "$scratch/doctor"
for section in Configuration 'SSH and firewall' Tailscale 'Security updates' Docker Recovery Limits Summary; do
  grep -q "^  $section$" "$scratch/doctor" || fail "Missing section: $section"
done
grep -q 'coordination server' "$scratch/doctor"
grep -q 'Checks.*3 passed' "$scratch/doctor"
grep -q 'Automatic-Reboot.*false' "$scratch/doctor"
if grep -q private-peer-name "$scratch/doctor"; then fail 'Doctor dumped the peer list.'; fi
printf '{"BackendState":"Running","Health":"unsupported"}\n' > "$scratch/tailscale"
keel_doctor_tailscale > "$scratch/unknown"
grep -q 'Unsupported Tailscale status' "$scratch/unknown"
printf 'PASS: CLI color/NO_COLOR/redirection, error streams, control sanitization and structured doctor health/unknown reporting\n'
