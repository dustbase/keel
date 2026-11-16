#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
bash -n bin/keel lib/*.sh
bash bin/keel --help | grep -q 'Keel'
# Pure-function tests; no host changes.
# shellcheck disable=SC1091
source lib/common.sh
keel_valid_hostname example
keel_valid_hostname node-01
if keel_valid_hostname -broken; then exit 1; fi
if keel_valid_hostname 'bad host'; then exit 1; fi
keel_valid_user admin
if keel_valid_user root; then exit 1; fi
if keel_valid_user 'bad user'; then exit 1; fi
echo "Smoke tests passed"
