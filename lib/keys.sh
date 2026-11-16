#!/usr/bin/env bash
keel_valid_key() {
  local entry="$1" tmp result
  [[ "$entry" != *$'\n'* && "$entry" != *$'\r'* && "$entry" != *'PRIVATE KEY'* ]] || return 1
  [[ "$entry" =~ (^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)(-cert-v01@openssh.com)?[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]]|$) ]] || return 1
  tmp="$(mktemp)" || return 1
  printf '%s\n' "$entry" > "$tmp"
  result=0
  ssh-keygen -lf "$tmp" >/dev/null 2>&1 || result=1
  rm -f "$tmp"
  return "$result"
}
keel_has_keys() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if keel_valid_key "$line"; then return 0; fi
  done < "$1"
  return 1
}
keel_append_key() {
  local dest="$1" entry="$2" last
  keel_valid_key "$entry" || return 1
  grep -Fqx -- "$entry" "$dest" && return 0
  if [[ -s "$dest" ]]; then
    last="$(tail -c 1 "$dest" | od -An -tu1 | tr -d ' ')"
    [[ "$last" == 10 ]] || printf '\n' >> "$dest"
  fi
  printf '%s\n' "$entry" >> "$dest"
}
keel_key_display() {
  if ! ssh-keygen -lf "$1" 2>/dev/null; then echo '(no usable public keys)'; fi
}
keel_add_key() {
  local entry
  while true; do
    echo 'Paste ONE public key (empty line finishes; never paste a private key):'
    IFS= read -r entry || break
    [[ -n "$entry" ]] || break
    if keel_append_key "$1" "$entry"; then echo 'Public key merged.'
    else keel_warn 'Invalid public key; try again.'; fi
  done
}
keel_keys_setup() (
  local original="$1" admin="$2" original_home admin_home stage='' source_keys='' line
  # Scope cleanup to this helper, including early failures and cancelled input.
  # A subshell preserves the caller's EXIT/recovery trap.
  trap 'rm -f -- "$stage" "$source_keys"' EXIT
  original_home="$(getent passwd "$original" | cut -d: -f6)"
  admin_home="$(getent passwd "$admin" | cut -d: -f6)"
  [[ -d "$original_home" && -d "$admin_home" ]] || keel_die 'User home missing.'
  stage="$(mktemp)" || keel_die 'Cannot create key staging file.'
  source_keys="$(mktemp)" || keel_die 'Cannot create original-key staging file.'
  chmod 600 "$stage" "$source_keys" || keel_die 'Cannot protect key staging files.'
  # Read/write user-controlled paths with that user's privileges, never root.
  if runuser -u "$admin" -- test -e "$admin_home/.ssh/authorized_keys"; then
    runuser -u "$admin" -- cat "$admin_home/.ssh/authorized_keys" > "$stage" || keel_die 'Cannot read destination keys.'
  fi
  if runuser -u "$original" -- test -e "$original_home/.ssh/authorized_keys"; then
    runuser -u "$original" -- cat "$original_home/.ssh/authorized_keys" > "$source_keys" || keel_die 'Cannot read original keys.'
  fi
  echo "Original account keys ($original):"; keel_key_display "$source_keys"
  echo "Destination account keys ($admin):"; keel_key_display "$stage"
  echo 'Original valid entries will be copied verbatim, including key restrictions.'
  echo 'These identities will receive access to the destination administrator, which has sudo.'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if keel_valid_key "$line"; then keel_append_key "$stage" "$line"; fi
  done < "$source_keys"
  if ! keel_has_keys "$stage"; then
    echo 'No usable public keys. Paste a key, or generate one on YOUR computer:'
    echo '  ssh-keygen -t ed25519 -C "my-computer"'
    echo '  macOS/Linux: cat ~/.ssh/id_ed25519.pub'
    # shellcheck disable=SC2016
    echo '  Windows PowerShell: Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"'
    keel_add_key "$stage"
  elif keel_yes 'Add another public key?'; then keel_add_key "$stage"; fi
  keel_has_keys "$stage" || keel_die 'No usable public keys; preparation incomplete.'
  # shellcheck disable=SC2016 # Script runs in the unprivileged child shell.
  runuser -u "$admin" -- sh -c '
    set -eu
    home=$1
    test ! -L "$home/.ssh"
    mkdir -p "$home/.ssh"
    chmod 700 "$home/.ssh"
    umask 077
    key_tmp=$(mktemp "$home/.ssh/.keel.XXXXXX")
    trap '\''rm -f "$key_tmp"'\'' EXIT
    cat > "$key_tmp"
    mv -fT "$key_tmp" "$home/.ssh/authorized_keys"
  ' sh "$admin_home" < "$stage" || keel_die 'Cannot install administrator keys.'
  echo "Authorized fingerprints for $admin:"; keel_key_display "$stage"
)
