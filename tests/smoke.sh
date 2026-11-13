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
! keel_valid_hostname -broken
! keel_valid_hostname 'bad host'
keel_valid_user admin
! keel_valid_user root
! keel_valid_user 'bad user'
echo "Smoke tests passed"
