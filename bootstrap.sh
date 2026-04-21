#!/bin/bash
# Post-login host bootstrap.
# Run as ops (or any incus-admin user) after first SSH login into the
# newly-rebuilt VPS.
#
# Safe to re-run: existing containers aren't recreated, profiles and
# cloud-init user-data are re-applied at the Incus layer. Note that
# cloud-init's users/write_files/runcmd modules only execute on first
# boot of a container, so re-running bootstrap.sh won't re-run those
# inside existing containers — delete the container (or its cloud-init
# state) first if you need a full rebuild.
#
# Interactive by default. All prompts can be skipped by setting the
# corresponding env var, which is what makes non-interactive scripted runs
# work too.
#
# Prereqs (all handled by host-cloud-init.yaml):
#   - incus package installed, daemon running
#   - current user in incus-admin group
#   - /etc/subuid + /etc/subgid include root:1000000:1000000000
#   - UFW configured to trust incusbr0
#   - ~/.ssh/authorized_keys populated with the key you'll SSH from
#
# Env vars (all optional — prompted if unset and stdin is a TTY):
#   SSH_PUBLIC_KEY       — one or more SSH public key lines (newline-separated)
#                          to install in each container. Default: every valid
#                          key line in the operator's ~/.ssh/authorized_keys.
#   VM_COUNT             — number of agent VMs (default: 2)
#   VM_NAMES             — space-separated names (default: alpha beta gamma …,
#                          falling back to vm25 vm26 … past the Greek alphabet)
#   VM_RAM               — space-separated GiB values, same order as VM_NAMES.
#                          Integer or .5 increments (e.g. "4 4.5"). Default:
#                          equal split of available host RAM, rounded down
#                          to the nearest 0.5 GiB.
#   HOST_RESERVE_GB      — GiB to leave for the host when computing the
#                          default RAM split (default: 2)
#   IP_BASE              — last octet of the first VM's IP on incusbr0
#                          (default: 11; subsequent VMs get base+1, base+2, ...)
#   GITHUB_PAT_SECRET_NAME
#                        — Doppler secret name holding the GitHub PAT
#                          (default: GITHUB_TOKEN). The PAT is used at
#                          bootstrap time to register each VM's pre-generated
#                          SSH key on GitHub and to enumerate your verified
#                          GitHub emails so the identity prompt can offer
#                          them as choices.
#   GIT_USER_EMAIL_<NAME>— per-VM git user.email. Skips the interactive
#                          picker for that VM and uses this value directly.
#   GIT_USER_NAME        — default git user.name applied to every VM (used
#                          as the per-VM prompt default). Blank skips that
#                          VM unless GIT_USER_NAME_<NAME> is set.
#   GIT_USER_NAME_<NAME> — per-VM override for user.name (same <NAME> encoding
#                          as DOPPLER_TOKEN_<NAME>).
#   DOPPLER_TOKEN_<NAME> — service token for VM <NAME> (uppercase, hyphens
#                          become underscores), scope=/
#   ASSUME_YES=1         — skip the final confirmation prompt
#   INIT_ONLY=1          — only run `incus admin init --preseed` and exit
#                          (for the disaster-recovery flow where you want the
#                          Incus bridge + storage pool in place before running
#                          ./restore-golden.sh, without creating empty containers)
#
# If you see "user not in incus-admin group": log out and back in, then re-run.

set -euo pipefail

# -------- Static config --------
BRIDGE_NAME="incusbr0"
BRIDGE_CIDR="10.88.0.1/24"
BRIDGE_NETWORK="10.88.0"
STORAGE_POOL="default"
IMAGE="images:ubuntu/24.04/cloud"

DEFAULT_VM_COUNT=2
DEFAULT_HOST_RESERVE_GB=2
DEFAULT_IP_BASE=11

# -------- Helpers --------
is_tty() { [ -t 0 ]; }

# Prompt with a default. If stdin isn't a TTY, just echo the default.
prompt() {
  local question="$1" default="${2:-}" reply
  if ! is_tty; then
    echo "$default"
    return
  fi
  if [ -n "$default" ]; then
    read -r -p "$question [$default]: " reply >&2
    echo "${reply:-$default}"
  else
    read -r -p "$question: " reply >&2
    echo "$reply"
  fi
}

# Prompt for a secret (no echo). Returns empty string if not a TTY.
prompt_secret() {
  local question="$1" reply
  if ! is_tty; then
    echo ""
    return
  fi
  read -r -s -p "$question: " reply >&2
  echo >&2
  echo "$reply"
}

# Convert a VM name to the upper-case suffix we use for env-var lookup.
# vm-1 -> VM_1, alpha -> ALPHA
env_suffix() {
  local s="${1^^}"
  echo "${s//-/_}"
}

# -------- Host-side REST helpers (Doppler + GitHub) --------
# Using curl+jq avoids needing to install doppler/gh CLIs on the host; both
# are present in host-cloud-init.yaml's package list.

# Retry a command a few times with a short backoff. Each call gets its own
# output; only the final attempt's exit code is propagated. Used to tolerate
# transient DNS/proxy/TLS hiccups against api.doppler.com and api.github.com.
retry() {
  local attempts="${1:-3}" delay="${2:-2}"
  shift 2
  local n=0
  while :; do
    n=$((n + 1))
    if "$@"; then return 0; fi
    [ "$n" -ge "$attempts" ] && return 1
    sleep "$delay"
  done
}

# Write a 0600 curl config file containing the Authorization bearer header
# for a given token. Caller is responsible for rm'ing the returned path.
# Prevents tokens from showing up in `ps aux` (they would if passed via -H).
host_curl_auth_cfg() {
  local token="$1" cfg
  cfg="$(mktemp)"
  chmod 600 "$cfg"
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$cfg"
  echo "$cfg"
}

# HTTP-aware fetcher: wraps curl so transient failures retry but auth /
# not-found responses do NOT (no point waiting 6s to confirm a bad PAT).
# Auth token goes through a curl --config file so it isn't visible in
# `ps aux` output. Writes response body to stdout; returns 0 on 2xx, 1
# otherwise.
host_http_get() {
  local url="$1" token="$2" ; shift 2   # extra curl opts come after
  local attempts=3 delay=2 n=0 status
  local tmpbody authcfg
  tmpbody="$(mktemp)"
  authcfg="$(host_curl_auth_cfg "$token")"
  while :; do
    n=$((n + 1))
    status="$(curl -sSL -o "$tmpbody" -w '%{http_code}' --config "$authcfg" "$@" "$url" 2>/dev/null || echo "000")"
    case "$status" in
      2*) cat "$tmpbody"; rm -f "$tmpbody" "$authcfg"; return 0 ;;
      4*) rm -f "$tmpbody" "$authcfg"; return 1 ;;   # auth / not-found — don't retry
      *)
        if [ "$n" -ge "$attempts" ]; then
          rm -f "$tmpbody" "$authcfg"; return 1
        fi
        sleep "$delay"
        ;;
    esac
  done
}

# Same shape as host_http_get but writes response headers to stdout instead
# of the body — used by host_gh_pat_scopes to read X-OAuth-Scopes.
host_http_get_headers() {
  local url="$1" token="$2" ; shift 2
  local attempts=3 delay=2 n=0 status
  local tmpheaders authcfg
  tmpheaders="$(mktemp)"
  authcfg="$(host_curl_auth_cfg "$token")"
  while :; do
    n=$((n + 1))
    status="$(curl -sSL -D "$tmpheaders" -o /dev/null -w '%{http_code}' --config "$authcfg" "$@" "$url" 2>/dev/null || echo "000")"
    case "$status" in
      2*) cat "$tmpheaders"; rm -f "$tmpheaders" "$authcfg"; return 0 ;;
      4*) rm -f "$tmpheaders" "$authcfg"; return 1 ;;
      *)
        if [ "$n" -ge "$attempts" ]; then
          rm -f "$tmpheaders" "$authcfg"; return 1
        fi
        sleep "$delay"
        ;;
    esac
  done
}

# Fetch a single Doppler secret by name using a service token.
# Writes the decrypted value to stdout; returns 1 if the secret can't be
# resolved (bad token, missing secret, network down after retries).
host_doppler_get() {
  local service_token="$1" secret_name="$2" body
  body="$(host_http_get \
    "https://api.doppler.com/v3/configs/config/secret?name=${secret_name}" \
    "$service_token" \
  )" || return 1
  jq -r '.value.computed // empty' <<< "$body"
}

# List verified email addresses on the GitHub user the PAT authenticates as,
# one per line. Returns 1 on API error, 0 otherwise (even if the list is
# empty — that's a valid state).
host_gh_list_emails() {
  local pat="$1" body
  body="$(host_http_get \
    "https://api.github.com/user/emails" \
    "$pat" \
    -H "Accept: application/vnd.github+json" \
  )" || return 1
  jq -r '.[] | select(.verified == true) | .email' <<< "$body"
}

# Return the comma-separated list of OAuth scopes granted to the PAT via
# the X-OAuth-Scopes response header. Empty output if the header isn't
# present (fine-grained PATs don't expose scopes) OR if the request failed.
host_gh_pat_scopes() {
  local pat="$1"
  host_http_get_headers \
    "https://api.github.com/user" \
    "$pat" \
    -H "Accept: application/vnd.github+json" \
    | awk -F': ' 'tolower($1) == "x-oauth-scopes" { sub(/\r$/, "", $2); print $2 }'
}

# Register an SSH public key on the GH user's account. Treats "already in
# use" as success. Prints a one-line status to stdout; returns 0/1.
# Like the GET helpers, the PAT goes through a curl config file so it isn't
# visible in `ps aux`. The request body (SSH pubkey + title) isn't sensitive.
host_gh_add_ssh_key() {
  local pat="$1" title="$2" pubkey="$3"
  local tmpbody authcfg status body
  tmpbody="$(mktemp)"
  authcfg="$(host_curl_auth_cfg "$pat")"
  status="$(
    retry 3 2 curl -sSL -o "$tmpbody" -w '%{http_code}' --config "$authcfg" \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/user/keys" \
      -d "$(jq -n --arg t "$title" --arg k "$pubkey" '{title: $t, key: $k}')"
  )" || status="network-error"
  body="$(cat "$tmpbody")"
  rm -f "$tmpbody" "$authcfg"
  case "$status" in
    2*) echo "registered"; return 0 ;;
    422)
      if echo "$body" | grep -q "already in use"; then
        echo "already-registered"; return 0
      fi
      echo "rejected: $(echo "$body" | jq -r '.errors[0].message // .message // "unknown"' 2>/dev/null)"; return 1
      ;;
    401) echo "auth-failed"; return 1 ;;
    network-error) echo "network-error"; return 1 ;;
    *)   echo "http-$status"; return 1 ;;
  esac
}

# True when bridge + storage pool + default profile all exist. That's the
# minimum state required for the rest of the script (and restore-golden.sh)
# to work, so "bridge exists" alone isn't enough.
incus_initialised() {
  incus network show "$BRIDGE_NAME"   >/dev/null 2>&1 \
    && incus storage show "$STORAGE_POOL" >/dev/null 2>&1 \
    && incus profile show default         >/dev/null 2>&1
}

# Run the idempotent one-shot preseed. Called from INIT_ONLY and the main flow.
incus_preseed() {
  cat <<EOF | incus admin init --preseed
config: {}
networks:
- name: $BRIDGE_NAME
  type: bridge
  config:
    ipv4.address: $BRIDGE_CIDR
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: $STORAGE_POOL
  driver: dir
profiles:
- name: default
  description: Default Incus profile
  devices:
    eth0:
      name: eth0
      network: $BRIDGE_NAME
      type: nic
    root:
      path: /
      pool: $STORAGE_POOL
      type: disk
cluster: null
EOF
}

# -------- Sanity checks --------
echo "==> Checking prerequisites"
command -v incus >/dev/null || { echo "ERROR: incus not installed"; exit 1; }
id -nG | tr ' ' '\n' | grep -qx incus-admin || {
  echo "ERROR: $(id -un) not in incus-admin group. Log out and back in, then re-run."
  exit 1
}
grep -q '^root:1000000:' /etc/subuid || { echo "ERROR: /etc/subuid missing root range"; exit 1; }
grep -q '^root:1000000:' /etc/subgid || { echo "ERROR: /etc/subgid missing root range"; exit 1; }

# SSH keys to install in each container. By default, pick every valid-looking
# key line from the operator's authorized_keys (skipping blanks and comments).
# Override wholesale with SSH_PUBLIC_KEY (one or more key lines, newline-separated).
SSH_KEY_RE='^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[^[:space:]]+|sk-(ssh-ed25519|ecdsa-sha2-[^[:space:]]+)@openssh\.com) '
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  AGENT_PUBKEYS="$SSH_PUBLIC_KEY"
elif [ -f "$HOME/.ssh/authorized_keys" ]; then
  AGENT_PUBKEYS="$(grep -E "$SSH_KEY_RE" "$HOME/.ssh/authorized_keys" || true)"
else
  echo "ERROR: ~/.ssh/authorized_keys missing and SSH_PUBLIC_KEY not set"
  exit 1
fi
[ -n "$AGENT_PUBKEYS" ] || { echo "ERROR: no valid SSH public keys found; set SSH_PUBLIC_KEY or add one to ~/.ssh/authorized_keys"; exit 1; }

# Build the YAML-list fragment for cloud-init: one "      - <key>" per line.
AGENT_PUBKEY_YAML=""
while IFS= read -r key; do
  [ -z "$key" ] && continue
  AGENT_PUBKEY_YAML+="      - ${key}"$'\n'
done <<< "$AGENT_PUBKEYS"
AGENT_PUBKEY_YAML="${AGENT_PUBKEY_YAML%$'\n'}"

# -------- INIT_ONLY: just initialise Incus and exit --------
# Used by the restore-from-golden flow: get the bridge + storage pool in place,
# then hand off to ./restore-golden.sh without creating empty containers that
# would block the import.
if [ "${INIT_ONLY:-}" = "1" ]; then
  if incus_initialised; then
    echo "==> Incus already initialised (bridge + storage pool + default profile present). You can now run ./restore-golden.sh"
  else
    echo "==> Initialising Incus (init-only mode)"
    incus_preseed
    echo "==> Incus initialised. You can now run ./restore-golden.sh"
  fi
  exit 0
fi

# -------- VM count --------
VM_COUNT="${VM_COUNT:-}"
if [ -z "$VM_COUNT" ]; then
  VM_COUNT="$(prompt 'How many agent VMs?' "$DEFAULT_VM_COUNT")"
fi
[[ "$VM_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: VM_COUNT must be a positive integer (got: '$VM_COUNT')"; exit 1; }

# -------- VM names --------
# Default to the Greek alphabet in order — doubles as a hint when prompting.
# If VM_COUNT exceeds 24, overflow falls back to vm25, vm26, ...
GREEK=(alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu \
       nu xi omicron pi rho sigma tau upsilon phi chi psi omega)
DEFAULT_NAMES=()
for ((i=0; i<VM_COUNT; i++)); do
  if [ "$i" -lt "${#GREEK[@]}" ]; then
    DEFAULT_NAMES+=("${GREEK[$i]}")
  else
    DEFAULT_NAMES+=("vm$((i+1))")
  fi
done

VM_NAMES_INPUT="${VM_NAMES:-}"
if [ -z "$VM_NAMES_INPUT" ]; then
  if is_tty; then
    echo
    echo "Greek alphabet (for reference — pick whichever letters follow your existing VMs):"
    for ((i=0; i<${#GREEK[@]}; i++)); do
      printf "  %2d. %-8s" "$((i+1))" "${GREEK[$i]}"
      (( (i+1) % 6 == 0 )) && echo
    done
    (( ${#GREEK[@]} % 6 == 0 )) || echo
    echo
  fi
  VM_NAMES_INPUT="$(prompt "Names for the $VM_COUNT VM(s), space-separated" "${DEFAULT_NAMES[*]}")"
fi
read -ra VM_NAME_ARR <<< "$VM_NAMES_INPUT"
if [ "${#VM_NAME_ARR[@]}" -ne "$VM_COUNT" ]; then
  echo "ERROR: VM_COUNT=$VM_COUNT but got ${#VM_NAME_ARR[@]} name(s): ${VM_NAME_ARR[*]}"
  exit 1
fi
for n in "${VM_NAME_ARR[@]}"; do
  [[ "$n" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "ERROR: invalid VM name '$n' (must start with a lowercase letter, end with a letter or digit; only lowercase letters, digits, hyphens in between)"; exit 1; }
done
# Check for duplicate names
if [ "$(printf '%s\n' "${VM_NAME_ARR[@]}" | sort -u | wc -l)" -ne "$VM_COUNT" ]; then
  echo "ERROR: duplicate VM names in: ${VM_NAME_ARR[*]}"
  exit 1
fi

# -------- RAM split --------
HOST_RESERVE_GB="${HOST_RESERVE_GB:-$DEFAULT_HOST_RESERVE_GB}"
[[ "$HOST_RESERVE_GB" =~ ^[0-9]+$ ]] || { echo "ERROR: HOST_RESERVE_GB must be a non-negative integer"; exit 1; }

# Work in half-GiB units (512 MiB) internally so users can pass `.5`
# values (e.g. "4.5 4.5" for a 9 GiB host). Format back to "N" / "N.5"
# GiB for display.
format_gib() {
  local h="$1"
  if (( h % 2 == 0 )); then
    printf '%d' $((h / 2))
  else
    printf '%d.5' $((h / 2))
  fi
}

TOTAL_RAM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
TOTAL_RAM_MIB=$(( TOTAL_RAM_KB / 1024 ))
HOST_RESERVE_MIB=$(( HOST_RESERVE_GB * 1024 ))
TOTAL_HALF_GIB=$(( TOTAL_RAM_MIB / 512 ))
AVAILABLE_HALF_GIB=$(( (TOTAL_RAM_MIB - HOST_RESERVE_MIB) / 512 ))
if [ "$AVAILABLE_HALF_GIB" -lt "$VM_COUNT" ]; then
  echo "ERROR: only $(format_gib "$AVAILABLE_HALF_GIB")GiB available after reserving ${HOST_RESERVE_GB}GiB for host — can't fit $VM_COUNT VMs at 0.5 GiB minimum each"
  exit 1
fi
DEFAULT_PER_VM_HALF_GIB=$(( AVAILABLE_HALF_GIB / VM_COUNT ))

echo
echo "Host RAM: $(format_gib "$TOTAL_HALF_GIB")GiB total, reserving ${HOST_RESERVE_GB}GiB for host = $(format_gib "$AVAILABLE_HALF_GIB")GiB for VMs"
echo "Default equal split: $(format_gib "$DEFAULT_PER_VM_HALF_GIB")GiB per VM"

DEFAULT_RAM_LIST=""
for ((i=0; i<VM_COUNT; i++)); do
  DEFAULT_RAM_LIST+="$(format_gib "$DEFAULT_PER_VM_HALF_GIB") "
done
DEFAULT_RAM_LIST="${DEFAULT_RAM_LIST% }"

VM_RAM_INPUT="${VM_RAM:-}"
if [ -z "$VM_RAM_INPUT" ]; then
  VM_RAM_INPUT="$(prompt "RAM in GiB per VM (integer or .5 increments, same order as names)" "$DEFAULT_RAM_LIST")"
fi
read -ra VM_RAM_ARR <<< "$VM_RAM_INPUT"
if [ "${#VM_RAM_ARR[@]}" -ne "$VM_COUNT" ]; then
  echo "ERROR: expected $VM_COUNT RAM values, got ${#VM_RAM_ARR[@]}: ${VM_RAM_ARR[*]}"
  exit 1
fi
declare -a VM_RAM_HALF_GIB=()
TOTAL_REQUESTED_HALF_GIB=0
for r in "${VM_RAM_ARR[@]}"; do
  [[ "$r" =~ ^[0-9]+(\.5)?$ ]] || { echo "ERROR: invalid RAM value '$r' — must be a positive GiB integer or N.5 (e.g. 4, 4.5, 2.5)"; exit 1; }
  if [[ "$r" == *.5 ]]; then
    whole="${r%.5}"
    half=$(( whole * 2 + 1 ))
  else
    half=$(( r * 2 ))
  fi
  [ "$half" -ge 1 ] || { echo "ERROR: RAM must be at least 0.5 GiB (got: '$r')"; exit 1; }
  VM_RAM_HALF_GIB+=("$half")
  TOTAL_REQUESTED_HALF_GIB=$(( TOTAL_REQUESTED_HALF_GIB + half ))
done
if [ "$TOTAL_REQUESTED_HALF_GIB" -gt "$AVAILABLE_HALF_GIB" ]; then
  echo "WARNING: requested $(format_gib "$TOTAL_REQUESTED_HALF_GIB")GiB exceeds available $(format_gib "$AVAILABLE_HALF_GIB")GiB (host has $(format_gib "$TOTAL_HALF_GIB")GiB total)"
  if is_tty && [ "${ASSUME_YES:-}" != "1" ]; then
    read -r -p "Continue anyway? [y/N]: " answer
    [[ "$answer" =~ ^[Yy] ]] || exit 1
  fi
fi

# -------- Doppler tokens per VM (optional) --------
# Asked before git identity because a Doppler token that resolves a
# GITHUB_TOKEN secret gives us two downstream automations: (1) bootstrap
# uploads the container's SSH key to GitHub via gh, and (2) we could
# pre-fill the git email from the GitHub account if the operator wants.
#
# Tokens are read with no-echo so pasted values don't land on screen /
# scrollback, and injected via stdin (not command args) so they don't
# appear in ps / sudo logs. An alternative to env vars:
# DOPPLER_TOKEN_<NAME>_FILE=/path/to/token (one token per file, chmod 600).
# Useful for scripted runs without putting the secret in shell history or
# the environment.
declare -A DOPPLER_TOKENS=()
echo
echo "Doppler service tokens (Enter to skip per VM; input is hidden):"
for name in "${VM_NAME_ARR[@]}"; do
  envvar="DOPPLER_TOKEN_$(env_suffix "$name")"
  filevar="${envvar}_FILE"
  token=""
  if [ -n "${!filevar-}" ]; then
    [ -r "${!filevar}" ] || { echo "ERROR: $filevar=${!filevar} not readable"; exit 1; }
    token="$(tr -d '\r\n' < "${!filevar}")"
  elif [ "${!envvar-__UNSET__}" != "__UNSET__" ]; then
    token="${!envvar}"
  else
    token="$(prompt_secret "  Doppler token for $name")"
  fi
  DOPPLER_TOKENS[$name]="$token"
done

# -------- GitHub PAT secret name + per-VM PAT + email enumeration --------
# Each VM's Doppler service token scopes access to one project/config;
# ask which secret in that config holds the GitHub PAT so we can:
#   1. Pre-register the VM's SSH key on GitHub at prompt time.
#   2. Pull down the operator's verified GitHub emails so the git-identity
#      prompt can offer them as options instead of making them type one.
GITHUB_PAT_SECRET_NAME="${GITHUB_PAT_SECRET_NAME-__UNSET__}"
if [ "$GITHUB_PAT_SECRET_NAME" = "__UNSET__" ]; then
  GITHUB_PAT_SECRET_NAME="$(prompt 'Doppler secret name for the GitHub PAT' 'GITHUB_TOKEN')"
fi

declare -A VM_GITHUB_PATS=()
declare -A VM_GITHUB_EMAILS=()   # newline-separated, per VM
declare -a ALL_GITHUB_EMAILS=()  # dedup'd union across VMs

if [ -n "$GITHUB_PAT_SECRET_NAME" ]; then
  any_doppler=0
  for name in "${VM_NAME_ARR[@]}"; do
    [ -n "${DOPPLER_TOKENS[$name]}" ] && any_doppler=1 && break
  done
  if [ "$any_doppler" = "1" ]; then
    echo
    echo "Resolving $GITHUB_PAT_SECRET_NAME from Doppler and enumerating GitHub emails..."
    for name in "${VM_NAME_ARR[@]}"; do
      token="${DOPPLER_TOKENS[$name]}"
      if [ -z "$token" ]; then
        echo "  $name: no Doppler token — skipping"
        continue
      fi
      pat="$(host_doppler_get "$token" "$GITHUB_PAT_SECRET_NAME" || true)"
      if [ -z "$pat" ]; then
        echo "  $name: Doppler secret '$GITHUB_PAT_SECRET_NAME' not found or unreadable"
        continue
      fi
      VM_GITHUB_PATS[$name]="$pat"

      # Up-front scope check so the user finds out about a bad PAT here,
      # not after plan-confirm. Fine-grained PATs don't expose scopes via
      # X-OAuth-Scopes; classic PATs do. Missing header ≠ missing scope —
      # print a note so the user knows why the check was skipped.
      scopes="$(host_gh_pat_scopes "$pat" 2>/dev/null || true)"
      if [ -n "$scopes" ]; then
        missing=""
        for required in admin:public_key user:email repo; do
          if ! grep -qw "$required" <<< "${scopes//,/ }"; then
            missing+="$required "
          fi
        done
        if [ -n "$missing" ]; then
          echo "  $name: PAT resolved but missing scope(s): ${missing% }"
          echo "         Granted: ${scopes}"
        fi
      else
        echo "  $name: PAT scope check skipped (fine-grained PAT or no X-OAuth-Scopes header) — any missing scopes will surface at upload time"
      fi

      emails="$(host_gh_list_emails "$pat" || true)"
      if [ -z "$emails" ]; then
        echo "  $name: PAT resolved, but no verified GH emails returned"
      else
        VM_GITHUB_EMAILS[$name]="$emails"
        echo "  $name: PAT resolved, $(echo "$emails" | wc -l | tr -d ' ') verified GitHub email(s) available"
      fi
    done
    # Union across VMs (same user usually — merge dedup'd)
    if [ "${#VM_GITHUB_EMAILS[@]}" -gt 0 ]; then
      mapfile -t ALL_GITHUB_EMAILS < <(
        for name in "${VM_NAME_ARR[@]}"; do
          [ -n "${VM_GITHUB_EMAILS[$name]:-}" ] && echo "${VM_GITHUB_EMAILS[$name]}"
        done | sort -u
      )
    fi
  fi
fi

# -------- Git identity (per-VM: pick existing GH email or enter custom) --------
# If we pulled down verified GitHub emails above, present them as a numbered
# menu per VM. Otherwise fall back to a free-form prompt.
declare -A GIT_USER_EMAILS=()
declare -A GIT_USER_NAMES=()

echo
echo "Git identity per VM:"
for name in "${VM_NAME_ARR[@]}"; do
  echo
  echo "  === $name ==="

  # Options list: existing emails + custom + skip.
  local_emails=()
  if [ -n "${VM_GITHUB_EMAILS[$name]:-}" ]; then
    mapfile -t local_emails <<< "${VM_GITHUB_EMAILS[$name]}"
  elif [ "${#ALL_GITHUB_EMAILS[@]}" -gt 0 ]; then
    # If this VM has no PAT but another did, still offer the union list.
    local_emails=("${ALL_GITHUB_EMAILS[@]}")
  fi

  chosen_email=""
  env_email_var="GIT_USER_EMAIL_$(env_suffix "$name")"
  if [ "${!env_email_var-__UNSET__}" != "__UNSET__" ]; then
    # Env var override wins unconditionally.
    chosen_email="${!env_email_var}"
  elif [ "${#local_emails[@]}" -gt 0 ]; then
    echo "  Existing GitHub verified emails:"
    i=1
    for e in "${local_emails[@]}"; do
      printf "    %d. %s\n" "$i" "$e"
      ((i++))
    done
    custom_idx=$i
    skip_idx=$((i + 1))
    printf "    %d. (enter custom)\n" "$custom_idx"
    printf "    %d. (skip — no git identity for %s)\n" "$skip_idx" "$name"
    while true; do
      choice="$(prompt "  Choice" "1")"
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$skip_idx" ]; then
        break
      fi
      echo "  Invalid choice, try again."
    done
    if [ "$choice" -eq "$custom_idx" ]; then
      chosen_email="$(prompt "  Custom email" '')"
    elif [ "$choice" -eq "$skip_idx" ]; then
      chosen_email=""
    else
      chosen_email="${local_emails[$((choice - 1))]}"
    fi
  else
    chosen_email="$(prompt "  Git user.email (blank to skip)" '')"
  fi

  if [ -n "$chosen_email" ]; then
    # Minimal email shape check: non-empty local@domain.tld, no whitespace
    # or stray @s. Not strict RFC 5322 validation — operators who fat-finger
    # their own address spot it quickly anyway; this just rejects the
    # obviously-wrong like '@@..' or 'foo' or 'foo@'.
    if ! [[ "$chosen_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
      echo "ERROR: '$chosen_email' doesn't look like an email for $name"
      exit 1
    fi
    GIT_USER_EMAILS[$name]="$chosen_email"

    name_envvar="GIT_USER_NAME_$(env_suffix "$name")"
    if [ "${!name_envvar-__UNSET__}" != "__UNSET__" ]; then
      user_name="${!name_envvar}"
    else
      user_name="$(prompt "  Git user.name for $name" "${GIT_USER_NAME:-}")"
    fi
    if [ -n "$user_name" ]; then
      GIT_USER_NAMES[$name]="$user_name"
    else
      # user.name required alongside user.email; drop email if skipped.
      unset "GIT_USER_EMAILS[$name]"
      echo "  (no user.name supplied — skipping git identity for $name)"
    fi
  fi
done

# -------- IP allocation --------
IP_BASE="${IP_BASE:-$DEFAULT_IP_BASE}"
if ! [[ "$IP_BASE" =~ ^[0-9]+$ ]] || [ "$IP_BASE" -lt 2 ] || [ "$IP_BASE" -gt 254 ]; then
  echo "ERROR: IP_BASE must be 2..254 (got: '$IP_BASE')"
  exit 1
fi
LAST_OCTET=$(( IP_BASE + VM_COUNT - 1 ))
[ "$LAST_OCTET" -le 254 ] || { echo "ERROR: IP_BASE=$IP_BASE + VM_COUNT=$VM_COUNT overflows /24"; exit 1; }

declare -A VM_IPS=()
for ((i=0; i<VM_COUNT; i++)); do
  VM_IPS[${VM_NAME_ARR[$i]}]="${BRIDGE_NETWORK}.$(( IP_BASE + i ))"
done

# -------- Plan + confirm --------
# Compute column width for the NAME field so long VM names don't misalign.
NAME_W=4  # "NAME" header
for n in "${VM_NAME_ARR[@]}"; do
  [ "${#n}" -gt "$NAME_W" ] && NAME_W="${#n}"
done
echo
echo "==> Plan:"
printf "  %-*s %-8s %-14s %s\n" "$NAME_W" "NAME" "RAM" "IP" "EXTRAS"
for ((i=0; i<VM_COUNT; i++)); do
  n="${VM_NAME_ARR[$i]}"
  extras=""
  [ -n "${DOPPLER_TOKENS[$n]}" ] && extras+="+Doppler "
  [ -n "${GIT_USER_NAMES[$n]:-}" ] && extras+="+Git "
  printf "  %-*s %-8s %-14s %s\n" "$NAME_W" "$n" "$(format_gib "${VM_RAM_HALF_GIB[$i]}")GiB" "${VM_IPS[$n]}" "${extras% }"
done
any_identity=0
for name in "${VM_NAME_ARR[@]}"; do
  [ -n "${GIT_USER_NAMES[$name]:-}" ] && any_identity=1 && break
done
if [ "$any_identity" = "1" ]; then
  echo
  echo "  Git identities:"
  for name in "${VM_NAME_ARR[@]}"; do
    if [ -n "${GIT_USER_NAMES[$name]:-}" ]; then
      printf "    %-*s %s <%s>\n" "$NAME_W" "$name" "${GIT_USER_NAMES[$name]}" "${GIT_USER_EMAILS[$name]}"
    else
      printf "    %-*s <skipped>\n" "$NAME_W" "$name"
    fi
  done
fi
any_gh=0
for name in "${VM_NAME_ARR[@]}"; do
  [ -n "${VM_GITHUB_PATS[$name]:-}" ] && any_gh=1 && break
done
if [ "$any_gh" = "1" ]; then
  echo
  echo "  GitHub SSH key registration (via Doppler $GITHUB_PAT_SECRET_NAME):"
  for name in "${VM_NAME_ARR[@]}"; do
    if [ -n "${VM_GITHUB_PATS[$name]:-}" ]; then
      printf "    %-*s will register pubkey as 'agent@%s'\n" "$NAME_W" "$name" "$name"
    else
      printf "    %-*s <manual paste>\n" "$NAME_W" "$name"
    fi
  done
fi
echo

if is_tty && [ "${ASSUME_YES:-}" != "1" ]; then
  read -r -p "Proceed? [Y/n]: " answer
  [[ -z "$answer" || "$answer" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

# -------- Detect new vs existing containers --------
# Re-runs should be idempotent: don't regenerate keys for containers that
# already exist (their existing key is the one GitHub already knows about).
declare -A VM_IS_NEW=()
for name in "${VM_NAME_ARR[@]}"; do
  if incus info "$name" >/dev/null 2>&1; then
    VM_IS_NEW[$name]="no"
  else
    VM_IS_NEW[$name]="yes"
  fi
done

# -------- Pre-generate SSH keys + register with GitHub (new containers only) --------
# Generate a dedicated ed25519 keypair per NEW VM in a chmod-700 tempdir,
# upload the pubkeys to GitHub via the resolved PATs, then bake the keys
# into each VM's cloud-init user-data so the container wakes up with them
# in place. Existing containers keep their in-container key — we read it
# back at the end for the final summary.
#
# Everything temporary goes under BOOTSTRAP_TMPDIR (0700) so one trap covers
# both the keypairs and the per-VM user-data files without the later trap
# clobbering the earlier one.
BOOTSTRAP_TMPDIR="$(mktemp -d)"
chmod 700 "$BOOTSTRAP_TMPDIR"
trap 'rm -rf "$BOOTSTRAP_TMPDIR"' EXIT
SSH_KEY_DIR="$BOOTSTRAP_TMPDIR/ssh-keys"
mkdir -m 700 "$SSH_KEY_DIR"

declare -A VM_SSH_PRIV_B64=()
declare -A VM_SSH_PUB=()
declare -A GH_KEY_REGISTERED=()  # status per VM; used by final output

any_new=0
for name in "${VM_NAME_ARR[@]}"; do
  [ "${VM_IS_NEW[$name]}" = "yes" ] && any_new=1 && break
done

if [ "$any_new" = "1" ]; then
  echo
  echo "==> Generating ed25519 SSH keypairs for new containers"
  for name in "${VM_NAME_ARR[@]}"; do
    if [ "${VM_IS_NEW[$name]}" = "no" ]; then
      GH_KEY_REGISTERED[$name]="existing-container"
      continue
    fi
    priv="$SSH_KEY_DIR/$name"
    ssh-keygen -t ed25519 -f "$priv" -N '' -C "agent@$name" -q
    VM_SSH_PRIV_B64[$name]="$(base64 -w0 < "$priv")"
    VM_SSH_PUB[$name]="$(cat "${priv}.pub")"
  done

  echo "==> Registering pubkeys with GitHub"
  for name in "${VM_NAME_ARR[@]}"; do
    if [ "${VM_IS_NEW[$name]}" = "no" ]; then
      echo "  $name: container already exists — keeping in-container key"
      continue
    fi
    pat="${VM_GITHUB_PATS[$name]:-}"
    if [ -z "$pat" ]; then
      GH_KEY_REGISTERED[$name]="skipped-no-pat"
      echo "  $name: no PAT → manual paste needed"
      continue
    fi
    status_line="$(host_gh_add_ssh_key "$pat" "agent@$name" "${VM_SSH_PUB[$name]}")"
    case "$status_line" in
      registered)         GH_KEY_REGISTERED[$name]="added";        echo "  $name: key uploaded to GitHub" ;;
      already-registered) GH_KEY_REGISTERED[$name]="exists-on-gh"; echo "  $name: key already on GitHub" ;;
      auth-failed)        GH_KEY_REGISTERED[$name]="auth-failed";  echo "  $name: gh auth failed — check PAT scopes" ;;
      *)                  GH_KEY_REGISTERED[$name]="error";        echo "  $name: registration failed ($status_line)" ;;
    esac
  done
else
  echo
  echo "==> All containers already exist — skipping SSH keygen / GitHub upload"
  for name in "${VM_NAME_ARR[@]}"; do
    GH_KEY_REGISTERED[$name]="existing-container"
  done
fi

# -------- Incus init --------
if incus_initialised; then
  echo "==> Incus already initialised"
else
  echo "==> Initialising Incus"
  incus_preseed
fi

# -------- Profiles --------
echo "==> Creating / updating profiles"

incus profile show agent-base >/dev/null 2>&1 || incus profile create agent-base
incus profile edit agent-base <<EOF
config:
  boot.autostart: "true"
description: Common configuration for AI agent containers
devices: {}
EOF

for ((i=0; i<VM_COUNT; i++)); do
  name="${VM_NAME_ARR[$i]}"
  # Incus memory limits accept MiB but not fractional GiB, so pass MiB.
  ram_mib=$(( VM_RAM_HALF_GIB[i] * 512 ))
  profile="${name}-profile"
  incus profile show "$profile" >/dev/null 2>&1 || incus profile create "$profile"
  incus profile edit "$profile" <<EOF
config:
  limits.cpu: "2"
  limits.memory: ${ram_mib}MiB
  limits.processes: "4096"
  snapshots.schedule: "@daily"
  snapshots.expiry: "7d"
description: Sizing for $name
devices: {}
EOF
done

# -------- Agent cloud-init user-data --------
# Baked into every container: SSH, tmux service, tmux config (mouse + OSC 52
# clipboard), Doppler CLI, git identity, and an ed25519 key ready for GitHub.
# Per-container Doppler service tokens are injected post-boot (see below).
# Agent CLIs (Claude Code, Codex, etc.) are installed per-container on demand,
# not baked in — keeps rebuilds fast and agent choice flexible.
#
# Git identity is per-VM (distinct user.name + user.email — picked from the
# operator's verified GitHub addresses or entered manually), so the user-data
# is rebuilt for each container rather than shared.

# Lives under BOOTSTRAP_TMPDIR so the single trap above cleans it up too.
AGENT_USER_DATA="$BOOTSTRAP_TMPDIR/agent-user-data.yaml"

# Build the user-data YAML for a single VM, writing it to $2.
write_user_data() {
  local vm="$1" out="$2"
  local gitconfig_block=""
  if [ -n "${GIT_USER_NAMES[$vm]:-}" ]; then
    # Cloud-init's write_files content is embedded via `content: |` so the
    # inner lines just need consistent indentation relative to `content:`.
    gitconfig_block="      [user]
          name = ${GIT_USER_NAMES[$vm]}
          email = ${GIT_USER_EMAILS[$vm]}
      [init]
          defaultBranch = main
      [pull]
          rebase = false"
  fi

  cat > "$out" <<EOF
#cloud-config
package_update: true
package_upgrade: true

# Doppler and gh are both installed in runcmd (below) rather than listed
# here — both need an apt repo whose signing key isn't on keyserver.ubuntu.com,
# and cloud-init's apt.sources keyid fetch is unreliable. Fetching the
# keyring binary directly from the vendor's CDN (with retries) is far more
# robust.
packages:
  - openssh-server
  - tmux
  - git
  - curl
  - jq
  - ripgrep
  - fd-find
  - build-essential
  - python3-pip
  - ca-certificates
  - apt-transport-https
  - gnupg

users:
  - default
  - name: agent
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
$AGENT_PUBKEY_YAML

write_files:
  - path: /etc/systemd/system/agent-tmux.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Persistent tmux session for agent
      After=network-online.target
      Wants=network-online.target
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      User=agent
      WorkingDirectory=/workspace
      ExecStart=/bin/sh -lc "tmux has-session -t agent 2>/dev/null || tmux new-session -d -s agent -c /workspace"
      ExecStop=/bin/sh -lc "tmux kill-session -t agent || true"
      [Install]
      WantedBy=multi-user.target

  - path: /home/agent/.tmux.conf
    owner: agent:agent
    permissions: '0644'
    defer: true
    content: |
      set -g mouse on
      set -g history-limit 100000
      set -g set-clipboard on

EOF

  # Only embed SSH keys if we pre-generated them for this VM (i.e. it's a
  # fresh container). For existing containers we leave their keys alone.
  # All agent-owned entries use `defer: true` so they run in
  # write-files-deferred (cloud_final_modules) rather than write-files
  # (cloud_init_modules) — on Ubuntu 24.04 the non-deferred module runs
  # BEFORE users-groups, which makes `owner: agent:agent` fail with
  # "Unknown user or group".
  if [ -n "${VM_SSH_PRIV_B64[$vm]:-}" ]; then
    cat >> "$out" <<EOF
  - path: /home/agent/.ssh/id_ed25519
    owner: agent:agent
    permissions: '0600'
    defer: true
    encoding: b64
    content: ${VM_SSH_PRIV_B64[$vm]}

  - path: /home/agent/.ssh/id_ed25519.pub
    owner: agent:agent
    permissions: '0644'
    defer: true
    content: |
      ${VM_SSH_PUB[$vm]}

EOF
  fi

  # Only emit the .gitconfig file if this VM has an identity configured.
  if [ -n "$gitconfig_block" ]; then
    cat >> "$out" <<EOF
  - path: /home/agent/.gitconfig
    owner: agent:agent
    permissions: '0644'
    defer: true
    content: |
$gitconfig_block

EOF
  fi

  cat >> "$out" <<EOF
runcmd:
  - systemctl enable ssh
  - systemctl restart ssh
  - mkdir -p /workspace
  - chown agent:agent /workspace
  - systemctl daemon-reload
  - systemctl enable --now agent-tmux.service
  # Doppler CLI — apt repo, keyring fetched directly from vendor (avoids
  # unreliable keyserver.ubuntu.com). Post-bootstrap, the host pipes the
  # service token via stdin into `doppler configure set token`.
  - bash -c 'for i in 1 2 3; do curl -fsSL https://packages.doppler.com/public/cli/gpg.key | gpg --dearmor -o /usr/share/keyrings/doppler-archive-keyring.gpg && break; sleep 5; done'
  - chmod go+r /usr/share/keyrings/doppler-archive-keyring.gpg
  - bash -c 'echo "deb [signed-by=/usr/share/keyrings/doppler-archive-keyring.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" > /etc/apt/sources.list.d/doppler-cli.list'
  # GitHub CLI — pre-authenticated post-boot by bootstrap.sh if a PAT was
  # resolvable via Doppler. If not, authenticate manually inside the
  # container with:
  #   doppler secrets get ${GITHUB_PAT_SECRET_NAME:-GITHUB_TOKEN} --plain | gh auth login --with-token
  - bash -c 'for i in 1 2 3; do curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && break; sleep 5; done'
  - chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  - bash -c 'echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list'
  # Single update + install for both new repos.
  - bash -c 'for i in 1 2 3; do apt-get update -qq && break; sleep 5; done'
  - DEBIAN_FRONTEND=noninteractive apt-get install -y -qq doppler gh
EOF
}

# -------- Containers --------
for name in "${VM_NAME_ARR[@]}"; do
  if ! incus info "$name" >/dev/null 2>&1; then
    echo "==> Creating $name"
    incus init "$IMAGE" "$name"
  else
    echo "==> $name already exists"
  fi
done

for name in "${VM_NAME_ARR[@]}"; do
  incus profile assign "$name" "default,agent-base,${name}-profile"
done

# eth0 IP pin (handle fresh create and re-run)
for name in "${VM_NAME_ARR[@]}"; do
  ip="${VM_IPS[$name]}"
  incus config device remove "$name" eth0 2>/dev/null || true
  incus config device override "$name" eth0 ipv4.address="$ip"
done

for name in "${VM_NAME_ARR[@]}"; do
  if [ "${VM_IS_NEW[$name]}" = "no" ]; then
    # Don't overwrite user-data on existing containers — cloud-init won't
    # re-run anyway, and the original user-data is what baked their keys in.
    continue
  fi
  write_user_data "$name" "$AGENT_USER_DATA"
  incus config set "$name" cloud-init.user-data - < "$AGENT_USER_DATA"
done

# -------- Start + wait --------
echo "==> Starting containers"
for name in "${VM_NAME_ARR[@]}"; do
  state=$(incus info "$name" | awk '/^Status:/ {print $2}')
  if [ "$state" = "RUNNING" ]; then
    incus restart "$name"
  else
    incus start "$name"
  fi
done

echo "==> Waiting for cloud-init inside containers (3–6 min on first boot — package install + gh repo fetch)"
for name in "${VM_NAME_ARR[@]}"; do
  incus exec "$name" -- cloud-init status --wait
done

# -------- Doppler service token injection (per-container, post-boot) --------
# Token is piped via stdin end-to-end so it never appears in ps output, the
# host's shell history, or the container's sudo audit log. Doppler CLI reads
# the token from stdin when no value is passed on the command line.
#
# Note: on re-run this overwrites whatever token the container currently has
# configured. Usually harmless, but if you rotated the service token inside
# the container manually, re-running bootstrap will revert to whatever you
# supplied at the prompt.
inject_doppler() {
  local name="$1" token="$2"
  if [ -z "$token" ]; then
    echo "==> Skipping Doppler token for $name (none provided)"
    return
  fi
  echo "==> Injecting Doppler token for $name"
  # Return 0 even on failure so one bad container doesn't abort the loop —
  # we log the failure instead and the user can see which VMs got Doppler.
  if printf '%s' "$token" \
       | incus exec "$name" -- sudo -iu agent sh -c 'doppler configure set token --scope=/ >/dev/null' \
       2>/dev/null; then
    return 0
  fi
  echo "  $name: Doppler injection failed — check the container is running and 'doppler' is on PATH"
  return 0
}

for name in "${VM_NAME_ARR[@]}"; do
  inject_doppler "$name" "${DOPPLER_TOKENS[$name]}"
done

# -------- Pre-authenticate gh CLI in each container (post-Doppler) --------
# Pipes the PAT we already resolved for SSH key registration into
# `gh auth login --with-token` inside the container. After this, the agent
# user can run `gh` / clone private repos / etc. without interactive auth.
# PAT is never written to disk as a flag or env var — only to gh's own
# hosts.yml (mode 0600) after gh persists it.
inject_gh_auth() {
  local name="$1" pat="$2"
  if [ -z "$pat" ]; then
    return
  fi
  echo "==> Authenticating gh CLI in $name"

  # Check gh is actually installed first — runcmd could have failed (apt
  # repo fetch blip, etc.) and the user deserves a clear error instead of
  # a mystery "auth failed".
  if ! incus exec "$name" -- command -v gh >/dev/null 2>&1; then
    echo "  $name: gh not installed — check /var/log/cloud-init-output.log inside the container"
    return
  fi

  # Capture combined stdout+stderr so if gh auth fails (bad PAT, scope
  # mismatch, network hiccup), the operator sees the real error.
  local auth_output
  if auth_output="$(printf '%s' "$pat" \
       | incus exec "$name" -- sudo -iu agent bash -c 'gh auth login --with-token && gh config set -h github.com git_protocol ssh' 2>&1)"; then
    echo "  $name: gh authenticated (git_protocol=ssh)"
  else
    echo "  $name: gh auth failed"
    # Truncate in case gh dumped a long trace.
    local snippet="${auth_output:0:400}"
    [ "${#auth_output}" -gt 400 ] && snippet+=" …"
    echo "    diagnostic: $snippet"
    echo "    try manually: doppler secrets get $GITHUB_PAT_SECRET_NAME --plain | gh auth login --with-token"
  fi
}

for name in "${VM_NAME_ARR[@]}"; do
  inject_gh_auth "$name" "${VM_GITHUB_PATS[$name]:-}"
done

# GitHub SSH key registration already happened on the host (pre-boot).
# GH_KEY_REGISTERED[$vm] was populated there.

# -------- Verify --------
echo
echo "==> Final state"
incus list
echo
echo "==> Service checks"
for name in "${VM_NAME_ARR[@]}"; do
  printf "%-*s ssh=%s  agent-tmux=%s\n" \
    "$NAME_W" "$name" \
    "$(incus exec "$name" -- systemctl is-active ssh)" \
    "$(incus exec "$name" -- systemctl is-active agent-tmux)"
done

echo
echo "==> GitHub SSH pubkeys"
for name in "${VM_NAME_ARR[@]}"; do
  # For existing containers we didn't pre-generate a key — read it from
  # inside so the fingerprint/pubkey display still works.
  if [ -z "${VM_SSH_PUB[$name]:-}" ]; then
    VM_SSH_PUB[$name]="$(incus exec "$name" -- cat /home/agent/.ssh/id_ed25519.pub 2>/dev/null || echo '(unable to read)')"
  fi
  fingerprint="$(ssh-keygen -lf - <<< "${VM_SSH_PUB[$name]}" 2>/dev/null | awk '{print $2}')"
  [ -z "$fingerprint" ] && fingerprint="(no key)"

  status="${GH_KEY_REGISTERED[$name]:-unknown}"
  case "$status" in
    added)
      echo "  $name  $fingerprint  (uploaded to GitHub — no action needed)" ;;
    exists-on-gh)
      echo "  $name  $fingerprint  (already on GitHub — no action needed)" ;;
    existing-container)
      echo "  $name  $fingerprint  (existing container — key not re-uploaded)" ;;
    auth-failed|error)
      echo "  $name  $fingerprint  (registration failed: $status — paste below into GitHub → Settings → SSH keys)"
      echo "    ${VM_SSH_PUB[$name]}" ;;
    *)
      echo "  $name  $fingerprint  (no Doppler PAT — paste below into GitHub → Settings → SSH keys)"
      echo "    ${VM_SSH_PUB[$name]}" ;;
  esac
done

echo
echo "Bootstrap complete."
echo "Connect from your client (assuming ProxyJump via the host):"
for name in "${VM_NAME_ARR[@]}"; do
  printf "    ssh %-*s # agent@%s\n" "$NAME_W" "$name" "${VM_IPS[$name]}"
done
