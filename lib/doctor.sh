#!/usr/bin/env bash
# Read-only diagnostics. These checks describe local state, not internet reachability.

keel_doctor() {
  keel_require_ubuntu
  echo "Keel server diagnostic (read-only)"
  echo "Hostname: $(hostname)"
  echo "Ubuntu: $(. /etc/os-release; echo "$PRETTY_NAME")"
  if [[ -f "$KEEL_CONFIG" ]]; then
    keel_load_config
    echo "Administrator: $KEEL_ADMIN"
    echo "Intended firewall profile: $KEEL_PROFILE"
    echo "Intended SSH access: $([[ "$KEEL_TS" == yes ]] && echo Tailscale || echo public)"
  else
    keel_warn "No Keel configuration exists."
  fi

  local effective
  effective="$(/usr/sbin/sshd -T 2>/dev/null || true)"
  if grep -qx 'passwordauthentication no' <<< "$effective"; then
    echo "PASS: SSH password authentication disabled"
  else
    echo "WARN: SSH password authentication is not disabled"
  fi
  if grep -qx 'permitrootlogin no' <<< "$effective"; then
    echo "PASS: Root SSH login disabled"
  else
    echo "WARN: Root SSH login not fully disabled"
  fi

  if ufw status | grep -q '^Status: active'; then
    echo "PASS: UFW active"
  else
    echo "WARN: UFW inactive"
  fi
  ufw status verbose

  if [[ -n "$(command -v tailscale || true)" ]] &&
     [[ -n "$(tailscale ip -4 2>/dev/null || true)" ]]; then
    echo "PASS: Tailscale has an IPv4 address"
  else
    echo "INFO: Tailscale not connected"
  fi

  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] &&
     grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
    echo "PASS: Unattended upgrades configured"
  else
    echo "WARN: Unattended upgrades not configured by Keel"
  fi

  if [[ -e /var/run/reboot-required ]]; then
    echo "INFO: Reboot required"
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "WARN: Docker detected. Published ports can bypass normal UFW filtering."
  fi
  if [[ -f "$KEEL_STATE/pending-rollback" ]]; then
    echo "WARNING: A security rollback is pending; run keel confirm from a new SSH session."
  fi
  echo "NOTE: Local UFW checks do not prove public reachability or provider firewall status."
}
