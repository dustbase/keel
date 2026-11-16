#!/usr/bin/env bash
# Diagnostics describe local observations, never an external security guarantee.
keel_doctor() {
  keel_require_ubuntu
  echo "Keel diagnostic (read-only) — $(hostname)"
  if [[ ! -f "$KEEL_CONFIG" ]]; then
    keel_warn 'No Keel configuration; run init for a plan.'
    return 0
  fi
  keel_load_config
  printf 'Administrator: %s\nApplication profile: %s\nAuthentication: %s\n' "$KEEL_ADMIN" "$KEEL_PROFILE" "$KEEL_TS_MODE"
  # Diagnostic contexts are explicitly local samples. Preflight rejects Match
  # layouts rather than extrapolate a sample to all possible connections.
  # shellcheck disable=SC2034 # Shared connection context for keel_ssh_check.
  KEEL_REMOTE_IP=127.0.0.1 KEEL_LOCAL_IP=127.0.0.1 KEEL_LOCAL_PORT=22
  if keel_ssh_check; then echo 'PASS: Supported OpenSSH configuration disables root/password/interactive login.'
  else echo 'WARN: OpenSSH policy differs or configuration cannot be evaluated safely.'; fi
  if command -v ufw >/dev/null; then
    keel_ufw status verbose
    if [[ -f "$KEEL_STATE/managed-firewall" && "$(cat "$KEEL_STATE/managed-firewall")" == "$(keel_security_digest)" ]]; then
      echo 'PASS: Local SSH/UFW files and reported UFW state match the confirmed baseline.'
    else echo 'UNKNOWN: No matching confirmed SSH/UFW baseline.'; fi
  else echo 'WARN: UFW unavailable.'; fi
  if command -v tailscale >/dev/null; then
    tailscale status || keel_warn 'Tailscale unavailable.'
    if tailscale debug prefs | jq -e '.RunSSH == true' >/dev/null; then
      echo 'INFO: Tailscale SSH enabled; its tailnet policy is independent of OpenSSH.'
    fi
    echo 'UNKNOWN: Tailnet network/SSH policy is externally managed; UFW alone does not prove tailnet isolation.'
  fi
  if command -v apt-config >/dev/null; then
    apt-config dump | grep -E 'APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)|Unattended-Upgrade::Automatic-Reboot' || true
    echo 'INFO: Above is effective APT policy; package installation and successful update execution require separate checks.'
  fi
  [[ ! -e /var/run/reboot-required ]] || echo 'INFO: Reboot required; Keel will not reboot automatically.'
  if command -v docker >/dev/null; then echo 'WARN: Docker-published ports may bypass UFW.'; fi
  if [[ -f "$KEEL_STATE/preparation-status" ]]; then
    printf 'Preparation: %s\n' "$(cat "$KEEL_STATE/preparation-status")"
  fi
  keel_status
  echo 'UNKNOWN: External IPv4/IPv6 reachability and provider firewall policy require external testing.'
}
