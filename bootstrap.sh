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
#   VM_NAMES             — space-separated names (default: vm1 vm2 ...)
#   VM_RAM               — space-separated GiB values, same order as VM_NAMES.
#                          Integer or .5 increments (e.g. "4 4.5"). Default:
#                          equal split of available host RAM, rounded down
#                          to the nearest 0.5 GiB.
#   HOST_RESERVE_GB      — GiB to leave for the host when computing the
#                          default RAM split (default: 2)
#   IP_BASE              — last octet of the first VM's IP on incusbr0
#                          (default: 11; subsequent VMs get base+1, base+2, ...)
#   GIT_USER_EMAIL_BASE  — base git user.email. Each VM gets its own email
#                          via plus-addressing: base `you@example.com` →
#                          `you+alpha@example.com`, `you+beta@example.com`, …
#                          Leave unset/blank to skip git identity entirely.
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

# -------- Git identity (optional, per-VM via plus-addressing) --------
# One base email (e.g. you@example.com) gets expanded per VM using
# plus-addressing: `you+alpha@example.com`, `you+beta@example.com`, etc.
# user.name is prompted per VM so you can tag commits distinctly if you want.
# Leave the base blank to skip git identity setup entirely.
GIT_USER_EMAIL_BASE="${GIT_USER_EMAIL_BASE-__UNSET__}"
if [ "$GIT_USER_EMAIL_BASE" = "__UNSET__" ]; then
  GIT_USER_EMAIL_BASE="$(prompt 'Base git user.email (blank to skip git identity)' '')"
fi
if [ -n "$GIT_USER_EMAIL_BASE" ]; then
  [[ "$GIT_USER_EMAIL_BASE" == *@*.* ]] || { echo "ERROR: base email must look like 'user@host.tld' (got: '$GIT_USER_EMAIL_BASE')"; exit 1; }
  GIT_EMAIL_LOCAL="${GIT_USER_EMAIL_BASE%@*}"
  GIT_EMAIL_DOMAIN="${GIT_USER_EMAIL_BASE##*@}"
fi

declare -A GIT_USER_NAMES=()
declare -A GIT_USER_EMAILS=()
if [ -n "$GIT_USER_EMAIL_BASE" ]; then
  echo
  echo "Git user.name per VM (Enter to skip a VM; email auto-derived as ${GIT_EMAIL_LOCAL}+<vm>@${GIT_EMAIL_DOMAIN}):"
  for name in "${VM_NAME_ARR[@]}"; do
    envvar="GIT_USER_NAME_$(env_suffix "$name")"
    if [ "${!envvar-__UNSET__}" != "__UNSET__" ]; then
      user_name="${!envvar}"
    else
      user_name="$(prompt "  Git user.name for $name" "${GIT_USER_NAME:-}")"
    fi
    if [ -n "$user_name" ]; then
      GIT_USER_NAMES[$name]="$user_name"
      GIT_USER_EMAILS[$name]="${GIT_EMAIL_LOCAL}+${name}@${GIT_EMAIL_DOMAIN}"
    fi
  done
fi

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
echo
echo "==> Plan:"
printf "  %-16s %-8s %-14s %s\n" "NAME" "RAM" "IP" "EXTRAS"
for ((i=0; i<VM_COUNT; i++)); do
  n="${VM_NAME_ARR[$i]}"
  extras=""
  [ -n "${DOPPLER_TOKENS[$n]}" ] && extras+="+Doppler "
  [ -n "${GIT_USER_NAMES[$n]:-}" ] && extras+="+Git "
  printf "  %-16s %-8s %-14s %s\n" "$n" "$(format_gib "${VM_RAM_HALF_GIB[$i]}")GiB" "${VM_IPS[$n]}" "${extras% }"
done
if [ -n "$GIT_USER_EMAIL_BASE" ]; then
  echo
  echo "  Git identities:"
  for name in "${VM_NAME_ARR[@]}"; do
    if [ -n "${GIT_USER_NAMES[$name]:-}" ]; then
      printf "    %-16s %s <%s>\n" "$name" "${GIT_USER_NAMES[$name]}" "${GIT_USER_EMAILS[$name]}"
    else
      printf "    %-16s <skipped>\n" "$name"
    fi
  done
fi
echo

if is_tty && [ "${ASSUME_YES:-}" != "1" ]; then
  read -r -p "Proceed? [Y/n]: " answer
  [[ -z "$answer" || "$answer" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
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
# Git identity is per-VM (distinct user.name + plus-addressed email), so the
# user-data is rebuilt for each container rather than shared.

AGENT_USER_DATA=$(mktemp)
trap 'rm -f "$AGENT_USER_DATA"' EXIT

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

apt:
  sources:
    doppler:
      source: "deb [signed-by=\$KEY_FILE] https://packages.doppler.com/public/cli/deb/debian any-version main"
      keyid: 34A57C7CD1CF2DDA57B3B9D1DE2A7741A397C129

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
  - doppler

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
    content: |
      set -g mouse on
      set -g history-limit 100000
      set -g set-clipboard on

EOF

  # Only emit the .gitconfig file if this VM has an identity configured.
  # cloud-init will happily write an empty file otherwise, which git treats
  # as a valid (empty) config — fine, but pointless noise.
  if [ -n "$gitconfig_block" ]; then
    cat >> "$out" <<EOF
  - path: /home/agent/.gitconfig
    owner: agent:agent
    permissions: '0644'
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
  # Generate an ed25519 key for GitHub if one doesn't exist yet.
  - [sudo, -u, agent, sh, -c, "test -f /home/agent/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f /home/agent/.ssh/id_ed25519 -N '' -C agent@\$(hostname)"]
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

echo "==> Waiting for cloud-init inside containers (2–4 min — extra packages this time)"
for name in "${VM_NAME_ARR[@]}"; do
  incus exec "$name" -- cloud-init status --wait
done

# -------- Doppler service token injection (per-container, post-boot) --------
# Token is piped via stdin end-to-end so it never appears in ps output, the
# host's shell history, or the container's sudo audit log. Doppler CLI reads
# the token from stdin when no value is passed on the command line.
inject_doppler() {
  local name="$1" token="$2"
  if [ -z "$token" ]; then
    echo "==> Skipping Doppler token for $name (none provided)"
    return
  fi
  echo "==> Injecting Doppler token for $name"
  printf '%s' "$token" \
    | incus exec "$name" -- sudo -iu agent sh -c 'doppler configure set token --scope=/ >/dev/null'
}

for name in "${VM_NAME_ARR[@]}"; do
  inject_doppler "$name" "${DOPPLER_TOKENS[$name]}"
done

# -------- GitHub SSH key registration (post-Doppler, optional) --------
# For each VM with a Doppler token, read GITHUB_TOKEN from whatever Doppler
# project/config the service token is scoped to, then use that PAT to upload
# the container's auto-generated ed25519 pubkey to the GitHub user's account.
# Installs `gh` CLI on-demand (once per container) so re-runs on existing
# containers also work. Silently skips VMs where Doppler wasn't configured
# or GITHUB_TOKEN isn't present.
#
# Required PAT scopes: admin:public_key (to add SSH keys) or write:public_key.
declare -A GH_KEY_REGISTERED=()
register_github_key() {
  local vm="$1"
  if [ -z "${DOPPLER_TOKENS[$vm]}" ]; then
    echo "==> Skipping GitHub SSH key registration for $vm (no Doppler token)"
    GH_KEY_REGISTERED[$vm]="skipped"
    return
  fi
  echo "==> Registering $vm's SSH key on GitHub (via Doppler GITHUB_TOKEN)"

  # Run everything inside the container as the agent user so the token never
  # touches the host. Write output to a tmpfile rather than capturing via
  # $(...) to keep the heredoc easy to read.
  local tmpout rc
  tmpout="$(mktemp)"
  incus exec "$vm" -- sudo -iu agent bash -s >"$tmpout" 2>&1 <<'INNER'
set -e

if ! command -v gh >/dev/null 2>&1; then
  echo "  Installing gh CLI (one-time)..."
  sudo install -d -m 755 /usr/share/keyrings
  sudo curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  arch="$(dpkg --print-architecture)"
  echo "deb [arch=$arch signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
fi

token="$(doppler secrets get GITHUB_TOKEN --plain 2>/dev/null || true)"
if [ -z "$token" ]; then
  echo "STATUS=no-token"
  exit 0
fi

if ! echo "$token" | gh auth login --with-token 2>/dev/null; then
  echo "STATUS=auth-failed"
  exit 0
fi

if add_output="$(gh ssh-key add /home/agent/.ssh/id_ed25519.pub --title "$(hostname)" 2>&1)"; then
  echo "STATUS=added"
elif echo "$add_output" | grep -qiE 'already|key is in use'; then
  echo "STATUS=exists"
else
  echo "STATUS=error"
  echo "$add_output"
fi
INNER
  rc=$?
  local output
  output="$(cat "$tmpout")"
  rm -f "$tmpout"

  local status="unknown"
  if [ "$rc" -ne 0 ]; then
    status="error"
  elif echo "$output" | grep -q '^STATUS=added$'; then
    status="added"
  elif echo "$output" | grep -q '^STATUS=exists$'; then
    status="exists"
  elif echo "$output" | grep -q '^STATUS=no-token$'; then
    status="no-token"
  elif echo "$output" | grep -q '^STATUS=auth-failed$'; then
    status="auth-failed"
  fi
  GH_KEY_REGISTERED[$vm]="$status"

  case "$status" in
    added)       echo "  $vm: SSH key uploaded to GitHub" ;;
    exists)      echo "  $vm: SSH key already on GitHub" ;;
    no-token)    echo "  $vm: GITHUB_TOKEN not found in Doppler — paste the pubkey manually" ;;
    auth-failed) echo "  $vm: gh auth login failed — check PAT scopes" ;;
    *)           echo "  $vm: registration failed"; echo "$output" | sed 's/^/    /' ;;
  esac
}

for name in "${VM_NAME_ARR[@]}"; do
  register_github_key "$name"
done

# -------- Verify --------
echo
echo "==> Final state"
incus list
echo
echo "==> Service checks"
for name in "${VM_NAME_ARR[@]}"; do
  printf "%-16s ssh=%s  agent-tmux=%s\n" \
    "$name" \
    "$(incus exec "$name" -- systemctl is-active ssh)" \
    "$(incus exec "$name" -- systemctl is-active agent-tmux)"
done

echo
echo "==> GitHub SSH pubkeys"
for name in "${VM_NAME_ARR[@]}"; do
  status="${GH_KEY_REGISTERED[$name]:-unknown}"
  case "$status" in
    added|exists)
      echo "--- $name (registered on GitHub automatically — no action needed) ---"
      ;;
    *)
      echo "--- $name (paste into GitHub → Settings → SSH keys) ---"
      ;;
  esac
  incus exec "$name" -- cat /home/agent/.ssh/id_ed25519.pub
done

echo
echo "Bootstrap complete."
echo "Connect from your client (assuming ProxyJump via the host):"
for name in "${VM_NAME_ARR[@]}"; do
  printf "    ssh %-16s # agent@%s\n" "$name" "${VM_IPS[$name]}"
done
