#!/usr/bin/env bash
# Pure output fixtures; never modify a tailnet or host configuration.
# shellcheck disable=SC2317,SC2329
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/prepare.sh
source lib/prepare.sh
keel_tailscale_status_json() { return 1; }
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
KEEL_STATE="$scratch/state"
mkdir "$KEEL_STATE"
tailscale() { fail 'Template invoked Tailscale.'; }
keel_save_config() { fail 'Template changed configuration.'; }
keel_lock() { fail 'Template acquired a mutation lock.'; }
KEEL_HOST=node KEEL_ADMIN=admin KEEL_TS=yes KEEL_TS_MODE=openssh KEEL_PROFILE=private KEEL_CUSTOM=''
render() { keel_tailscale_policy "$@" > "$scratch/policy.json" 2> "$scratch/guidance"; }
reject() {
  if render "$@"; then fail "Accepted invalid template arguments: $*"; fi
  [[ ! -s "$scratch/policy.json" ]] || fail 'Invalid input emitted a partial policy.'
}
render --tag tag:test-server --port 2222
jq -e '.grants == [{src:["group:keel-ssh-users"],dst:["tag:test-server"],ip:["tcp:2222"]}] and
  (has("ssh") | not) and .tagOwners["tag:test-server"] == ["REPLACE_WITH_TRUSTED_TAG_OWNER"] and
  .groups["group:keel-ssh-users"] == ["REPLACE_WITH_ALLOWED_TAILNET_USER"]' "$scratch/policy.json" >/dev/null
grep -q 'do not' "$scratch/guidance"
grep -q 'does not restrict' "$scratch/guidance"
render
jq -e '.grants[0].ip == ["tcp:REPLACE_WITH_OPENSSH_PORT"] and
  .grants[0].dst == ["tag:replace-with-server-tag"]' "$scratch/policy.json" >/dev/null
for port in 0 65536 -1 22/tcp '22"' ''; do reject --port "$port"; done
reject --port
reject --tag
reject --tag 'tag:bad"tag'
reject --tag '*'
reject --unknown
KEEL_TS_MODE=tailscale-ssh
render --tag tag:test-server
jq -e '.grants[0].ip == ["tcp:22"] and .ssh == [{action:"check",src:["group:keel-ssh-users"],
  dst:["tag:test-server"],users:["admin"]}]' "$scratch/policy.json" >/dev/null
render --port 22
reject --port 2222
# The persisted tag is reused without weakening trust or input validation.
keel_trusted_path() { [[ -f "$1" && ! -L "$1" ]]; }
printf 'tag:dustbase-node\n' > "$KEEL_STATE/tailscale-tag"
render
jq -e '.ssh[0].dst == ["tag:dustbase-node"]' "$scratch/policy.json" >/dev/null
keel_preparation_next_steps > "$scratch/next" 2> "$scratch/guidance"
grep -q 'setup is incomplete' "$scratch/next"
grep -q 'not the public IP' "$scratch/next"
grep -q 'sudo keel tailscale-ssh' "$scratch/next"
printf 'tag:bad"tag\n' > "$KEEL_STATE/tailscale-tag"
reject
rm "$KEEL_STATE/tailscale-tag"
ln -s missing "$KEEL_STATE/tailscale-tag"
reject
rm "$KEEL_STATE/tailscale-tag"
KEEL_ADMIN='root'
reject
KEEL_ADMIN='admin", "root'
reject
KEEL_ADMIN=admin KEEL_TS=no
reject
KEEL_TS_MODE=openssh
render
[[ ! -s "$scratch/policy.json" ]] || fail 'Public mode emitted a tailnet grant.'
grep -q 'no Tailscale policy template' "$scratch/guidance"
printf 'PASS: Tailscale policy modes, least-privilege placeholders, ports and invalid input\n'
