#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
# Advisory names only; all daemon responses are fixtures.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/session.sh
source lib/session.sh
# shellcheck source=lib/prepare.sh
source lib/prepare.sh
# shellcheck source=lib/security.sh
source lib/security.sh
scratch="$(mktemp -d /tmp/keel-magicdns.XXXXXXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
fixture_data='{"CurrentTailnet":{"MagicDNSEnabled":true,"MagicDNSSuffix":"tail-example.ts.net"},"Self":{"DNSName":"Casked.tail-example.ts.net.","TailscaleIPs":["100.73.96.5","fd7a:115c:a1e0::5"]}}'
[[ "$(keel_magicdns_names "$fixture_data" 100.73.96.5)" == 'casked casked.tail-example.ts.net' ]] || fail 'Matching node name missing.'
[[ "$(keel_magicdns_names "$fixture_data" fd7a:115c:a1e0::5)" == 'casked casked.tail-example.ts.net' ]] || fail 'IPv6 node name missing.'
for change in '.CurrentTailnet.MagicDNSEnabled=false' '.CurrentTailnet.MagicDNSEnabled=null' '.CurrentTailnet.MagicDNSSuffix="wrong.ts.net"' '.Self.DNSName="bad;command.tail-example.ts.net"' '.Self.TailscaleIPs=[]' '.Self.DNSName=null'; do
  changed="$(jq "$change" <<< "$fixture_data")"
  if keel_magicdns_names "$changed" 100.73.96.5; then fail "Accepted invalid metadata: $change"; fi
done
if keel_magicdns_names "$fixture_data" 203.0.113.5; then fail 'Name not bound to proven destination.'; fi
if keel_magicdns_names 'invalid'; then fail 'Malformed JSON accepted.'; fi
keel_tailscale_status_json() { printf '%s\n' "$fixture_data"; }
KEEL_ADMIN=admin KEEL_HOST=unrelated-host KEEL_TS=yes KEEL_LOCAL_IP=100.73.96.5 KEEL_LOCAL_PORT=22
out="$(keel_reconnect_help confirm)"
grep -q 'ControlPath=none admin@casked$' <<< "$out" || fail 'Short name not preferred.'
grep -q 'ControlPath=none admin@100.73.96.5$' <<< "$out" || fail 'IP fallback missing.'
grep -q '    keel confirm$' <<< "$out" || fail 'Next command missing.'
grep -q 'casked.tail-example.ts.net' <<< "$out" || fail 'Full name missing.'
out="$(keel_magicdns_report "$fixture_data")"
grep -q 'client resolution is not verified' <<< "$out" || fail 'Client DNS limitation missing.'
KEEL_LOCAL_PORT=2222
out="$(keel_reconnect_help verify)"
grep -q -- '-p 2222 admin@casked$' <<< "$out" || fail 'Custom port lost.'
KEEL_LOCAL_IP=203.0.113.5
out="$(keel_reconnect_help verify)"
if grep -q 'admin@casked' <<< "$out"; then fail 'Unrelated address got node name.'; fi
keel_tailscale_status_json() { return 1; }
KEEL_LOCAL_IP=100.73.96.5
out="$(keel_reconnect_help confirm)"
grep -q 'admin@100.73.96.5$' <<< "$out" || fail 'Query failure lost address.'
keel_tailscale_status_json() { touch "$scratch/unexpected-query"; return 1; }
KEEL_TS=no
out="$(keel_reconnect_help confirm)"
grep -q 'admin@100.73.96.5$' <<< "$out" || fail 'Public mode changed destination.'
[[ ! -e "$scratch/unexpected-query" ]] || fail 'Public mode queried Tailscale.'
printf 'PASS: advisory MagicDNS names and reconnect fallback\n'
