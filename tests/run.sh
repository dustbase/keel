#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
for file in install.sh bin/keel lib/*.sh tests/*.sh; do bash -n "$file"; done
bash tests/smoke.sh
for case_name in $(bash tests/regression.sh --list); do
  bash tests/regression.sh "$case_name"
  printf 'PASS: %s\n' "$case_name"
done
bash tests/installer.sh
bash tests/installer-upgrade.sh
bash tests/tailscale-policy.sh
bash tests/tailscale-onboarding.sh
