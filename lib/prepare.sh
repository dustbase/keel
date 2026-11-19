#!/usr/bin/env bash
# Interactive first-stage configuration. No restrictive network changes.

keel_detect_login() {
  local u="${SUDO_USER:-}"
  if [[ -z "$u" || "$u" == root ]]; then
    read -r -p "Existing SSH login username: " u
  fi
  id "$u" >/dev/null 2>&1 || keel_die "User $u does not exist."
  printf '%s' "$u"
}

keel_init() {
  keel_require_ubuntu
  keel_setup_dirs
  keel_no_pending
  if [[ -f "$KEEL_CONFIG" ]]; then
    keel_load_config
    keel_warn "Existing Keel configuration found for $KEEL_ADMIN on $KEEL_HOST."
    keel_yes "Re-run preparation? No keys will be removed." || exit 0
  fi

  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait || keel_die 'cloud-init is unfinished or has errors. Resolve it before preparation.'
  fi
  local old_user old_host ts_tag="" chosen name
  old_user="$(keel_detect_login)"
  old_host="$(hostname)"
  echo
  echo "Detected OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "Current account: $old_user"
  echo "Current hostname: $old_host"
  echo "Current authorized keys:"
  keel_key_display "$(getent passwd "$old_user" | cut -d: -f6)/.ssh/authorized_keys"

  read -r -p "New hostname [$old_host]: " name
  KEEL_HOST="${name:-$old_host}"
  keel_valid_hostname "$KEEL_HOST" || keel_die "Invalid hostname."

  local default_admin="$old_user"
  [[ "$default_admin" != root ]] || default_admin="admin"
  read -r -p "Administrator username [$default_admin]: " KEEL_ADMIN
  KEEL_ADMIN="${KEEL_ADMIN:-$default_admin}"
  keel_valid_user "$KEEL_ADMIN" || keel_die "Invalid administrator username."
  keel_existing_admin_safe "$KEEL_ADMIN" || keel_die 'Refusing to promote a system account or account without a usable home/login shell.'

  KEEL_TS=no
  KEEL_TS_MODE=openssh
  if keel_yes "Install/configure Tailscale?"; then
    KEEL_TS=yes
    read -r -p "Tailscale tag (optional; e.g. tag:servers): " ts_tag
    [[ -z "$ts_tag" || "$ts_tag" =~ ^tag:[a-z0-9][a-z0-9-]*$ ]] ||
      keel_die "Invalid tag."
    if keel_yes "Use Tailscale SSH identity authentication? (requires tailnet SSH policy)"; then
      KEEL_TS_MODE=tailscale-ssh
    fi
  fi

  echo
  echo "Firewall profile (applied only after verification):"
  echo "  1) Private: no public application ports [default]"
  echo "  2) Public web: TCP 80 and 443"
  echo "  3) Cloudflare Tunnel: no public inbound application ports"
  echo "  4) Custom: comma-separated TCP or UDP port/protocol pairs"
  read -r -p "Selection [1]: " chosen
  KEEL_CUSTOM=""
  case "${chosen:-1}" in
    1) KEEL_PROFILE=private ;;
    2) KEEL_PROFILE=web ;;
    3) KEEL_PROFILE=tunnel ;;
    4)
      KEEL_PROFILE=custom
      read -r -p "Rules (example: 25565/tcp,51820/udp): " KEEL_CUSTOM
      if ! keel_valid_rules "$KEEL_CUSTOM" || [[ -z "$KEEL_CUSTOM" ]]; then
        keel_die "Invalid custom port rules."
      fi
      ;;
    *) keel_die "Invalid firewall choice." ;;
  esac

  echo
  keel_ui_section 'Preparation plan'
  keel_ui_field Hostname "$KEEL_HOST"
  keel_ui_field Administrator "$KEEL_ADMIN"
  keel_ui_field Tailscale "$KEEL_TS"
  keel_ui_field 'SSH authentication' "$(keel_access_label "$KEEL_TS" "$KEEL_TS_MODE")"
  keel_ui_field 'Application profile' "$KEEL_PROFILE"
  keel_ui_status INFO 'Current SSH access is retained during preparation. Restrictive changes happen only after verification.'
  keel_ui_status WARN 'Valid original-account keys will receive access to the destination administrator, which has sudo.'
  if command -v docker >/dev/null 2>&1; then
    keel_warn 'Docker-published ports can bypass UFW; Keel does not manage Docker networking.'
  fi
  keel_yes "Apply preparation?" || exit 0

  keel_atomic_write "$KEEL_STATE/preparation-status" 'applying (additive steps may have completed; rerun init to resume)'
  keel_log "Installing prerequisites and unattended upgrades"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server sudo curl ca-certificates ufw unattended-upgrades jq iproute2 util-linux
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UPDATES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
UPDATES
  cat > /etc/apt/apt.conf.d/99-keel-no-reboot <<'REBOOT'
Unattended-Upgrade::Automatic-Reboot "false";
REBOOT
  keel_updates_check || keel_die 'Effective APT configuration conflicts with security-update/no-reboot policy.'
  keel_systemctl enable --now apt-daily-upgrade.timer
  keel_install_recovery

  keel_log "Setting hostname and preserving cloud-init hostname"
  hostnamectl set-hostname "$KEEL_HOST"
  install -d /etc/cloud/cloud.cfg.d
  printf '#cloud-config\npreserve_hostname: true\n' \
    > /etc/cloud/cloud.cfg.d/99-keel-hostname.cfg
  if grep -Eq '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^(127\.0\.1\.1[[:space:]]+).*/\1$KEEL_HOST/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$KEEL_HOST" >> /etc/hosts
  fi

  keel_log "Creating or updating administrator"
  if ! id "$KEEL_ADMIN" >/dev/null 2>&1; then
    echo 'Set a local account password for sudo. SSH passwords will be disabled during secure.'
    adduser --gecos "" "$KEEL_ADMIN"
  fi
  usermod -aG sudo "$KEEL_ADMIN"
  keel_keys_setup "$old_user" "$KEEL_ADMIN"

  if [[ "$KEEL_TS" == yes ]]; then
    keel_log "Installing/configuring Tailscale"
    if ! command -v tailscale >/dev/null 2>&1; then
      local installer
      installer="$(mktemp)"
      curl -fsSL https://tailscale.com/install.sh -o "$installer"
      echo "Review the downloaded installer at $installer before execution."
      if keel_yes "Run the official Tailscale installer?"; then
        sh "$installer"
        rm -f "$installer"
      else
        keel_die "Tailscale installation skipped; preparation incomplete."
      fi
    fi
    keel_systemctl enable --now tailscaled
    local args=(--hostname="$KEEL_HOST")
    [[ -z "$ts_tag" ]] || args+=(--advertise-tags="$ts_tag")
    if tailscale ip -4 >/dev/null 2>&1; then
      tailscale set "${args[@]}"
    else
      tailscale up "${args[@]}"
    fi
  fi

  keel_save_config
  keel_atomic_write "$KEEL_STATE/tailscale-tag" "$ts_tag" || return 1
  keel_atomic_write "$KEEL_STATE/prepared" "$(keel_record_boundary)"
  keel_atomic_write "$KEEL_STATE/preparation-status" complete
  rm -f "$KEEL_STATE/verified" "$KEEL_STATE/secured"
  keel_log "Preparation complete"
  keel_preparation_next_steps
}

keel_preparation_next_steps() {
  local -a policy_args=()
  keel_ui_section 'Next steps'
  keel_ui_status WARN 'Keep your original SSH session open.'
  if [[ "$KEEL_TS" == yes ]]; then
    keel_tailscale_policy "${policy_args[@]}" || return 1
  fi
  if [[ "$KEEL_TS_MODE" == tailscale-ssh ]]; then
    echo 'Tailscale SSH setup is incomplete until an authorized fresh login is verified.'
    echo '1. Merge the template into your tailnet policy: both TCP 22 network access and an SSH rule are required.'
    echo "   The SSH rule must include the destination server tag and local user $KEEL_ADMIN."
    echo '2. Keep tested public SSH or provider-console recovery access.'
    echo '3. Run: sudo keel tailscale-ssh (this may disconnect the current session).'
    echo "4. From a NEW terminal: ssh -o ControlMaster=no -o ControlPath=none $KEEL_ADMIN@$KEEL_HOST"
    echo '   Use the Tailscale address or MagicDNS name, not the public IP.'
    echo '   If Tailscale denies SSH, fix the tailnet SSH rule; reconnecting alone will not help.'
    echo '5. At the new remote prompt, run without sudo: keel verify'
    echo 'Only after verification: keel secure. Do not reboot or bypass verification to resolve a policy denial.'
    return 0
  fi
  if [[ "$KEEL_TS" == yes ]]; then
    echo "From a NEW terminal, connect as $KEEL_ADMIN using the Tailscale address or MagicDNS name."
    echo 'Use OpenSSH public-key authentication; Tailscale SSH identity authentication was not selected.'
  else
    echo "From a NEW terminal, connect as $KEEL_ADMIN using the public server address and actual OpenSSH port."
  fi
  echo 'Disable SSH multiplexing for verification: ssh -o ControlMaster=no -o ControlPath=none USER@HOST'
  echo "Then run (without sudo): keel verify"
  echo "Only after verification: keel secure"
}

# Output only: no policy API calls, state changes, or assumptions about identity.
keel_tailscale_policy() {
  local tag=tag:replace-with-server-tag port=REPLACE_WITH_OPENSSH_PORT arg
  keel_validate_config || { printf 'ERROR: Invalid prepared configuration.\n' >&2; return 1; }
  # Saved intent is advisory only; it never authorizes authentication or policy.
  if [[ -e "$KEEL_STATE/tailscale-tag" || -L "$KEEL_STATE/tailscale-tag" ]]; then
    keel_trusted_path "$KEEL_STATE/tailscale-tag" || { printf 'ERROR: Unsafe saved Tailscale tag.\n' >&2; return 1; }
    arg="$(cat "$KEEL_STATE/tailscale-tag")" || return 1
    [[ -z "$arg" || "$arg" =~ ^tag:[a-z0-9][a-z0-9-]*$ ]] || { printf 'ERROR: Invalid saved Tailscale tag.\n' >&2; return 1; }
    [[ -z "$arg" ]] || tag="$arg"
  fi
  while (( $# )); do
    arg="$1"
    case "$arg" in
      --tag)
        if ! { (( $# >= 2 )) && [[ "$2" =~ ^tag:[a-z0-9][a-z0-9-]*$ ]]; }; then
          printf 'ERROR: --tag requires tag:NAME.\n' >&2; return 1
        fi
        tag="$2"; shift 2 ;;
      --port)
        if ! { (( $# >= 2 )) && [[ "$2" =~ ^[0-9]{1,5}$ ]] &&
          (( 10#$2 >= 1 && 10#$2 <= 65535 )); }; then
          printf 'ERROR: --port requires a TCP port from 1 to 65535.\n' >&2; return 1
        fi
        port="$((10#$2))"; shift 2 ;;
      *) printf 'ERROR: Unknown policy option: %s\n' "$arg" >&2; return 1 ;;
    esac
  done
  [[ "$KEEL_TS" == yes ]] || {
    printf 'Public OpenSSH selected; no Tailscale policy template is needed.\n' >&2
    return 0
  }
  if [[ "$KEEL_TS_MODE" == tailscale-ssh ]]; then
    [[ "$port" == REPLACE_WITH_OPENSSH_PORT || "$port" == 22 ]] || {
      printf 'ERROR: Tailscale SSH uses port 22; --port applies to OpenSSH only.\n' >&2; return 1;
    }
    port=22
  fi
  keel_ui_section 'Tailscale policy template' >&2
  cat >&2 <<'GUIDANCE'
Tailscale policy TEMPLATE: replace every REPLACE_WITH value and placeholder tag.
Merge entries into your existing groups/tagOwners/grants/ssh sections; do not
replace the entire policy or duplicate top-level sections. Review existing broad
rules: adding these entries does not restrict access granted elsewhere.
Tag ownership permits assigning this access to devices. Choose tag owners
separately from SSH users, and apply the destination tag only to intended servers.
Tagging changes device identity; review existing policy before assigning tags.
For OpenSSH, replace the port with the actual listener port (or pass --port).
OpenSSH still requires authorized public keys; an SSH policy rule does not grant
OpenSSH login. Tailscale SSH uses a separate server and a check-mode SSH rule.
Validate the merged policy in Tailscale's editor, then test a fresh connection.
Keep existing recovery access. Keel has not applied or verified this template.
GUIDANCE
  cat <<POLICY
{
  "groups": {
    "group:keel-ssh-users": ["REPLACE_WITH_ALLOWED_TAILNET_USER"]
  },
  "tagOwners": {
    "$tag": ["REPLACE_WITH_TRUSTED_TAG_OWNER"]
  },
  "grants": [
    {"src": ["group:keel-ssh-users"], "dst": ["$tag"], "ip": ["tcp:$port"]}
  ]
POLICY
  if [[ "$KEEL_TS_MODE" == tailscale-ssh ]]; then
    cat <<POLICY
  ,"ssh": [
    {"action": "check", "src": ["group:keel-ssh-users"], "dst": ["$tag"], "users": ["$KEEL_ADMIN"]}
  ]
POLICY
  fi
  printf '}\n'
}

keel_updates_check() {
  local policy
  policy="$(apt-config dump)" || return 1
  grep -qx 'APT::Periodic::Update-Package-Lists "1";' <<< "$policy" &&
    grep -qx 'APT::Periodic::Unattended-Upgrade "1";' <<< "$policy" &&
    grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' <<< "$policy"
}
