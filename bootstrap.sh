#!/bin/bash
# Post-login host bootstrap.
# Run as ops after first SSH login into the newly-rebuilt VPS.
# Idempotent: safe to re-run.
#
# Prereqs (all handled by host-cloud-init.yaml):
#   - incus package installed, daemon running
#   - ops user in incus-admin group
#   - /etc/subuid + /etc/subgid include root:1000000:1000000000
#   - UFW configured to trust incusbr0
#
# Optional env vars:
#   GIT_USER_NAME, GIT_USER_EMAIL   — baked into each container's ~/.gitconfig
#   DOPPLER_TOKEN_ALPHA             — service token for alpha, scope=/
#   DOPPLER_TOKEN_BETA              — service token for beta,  scope=/
#
# If you see "ops not in incus-admin group": log out and back in, then re-run.

set -euo pipefail

# -------- Config --------
BRIDGE_NAME="incusbr0"
BRIDGE_CIDR="10.88.0.1/24"
STORAGE_POOL="default"
IMAGE="images:ubuntu/24.04/cloud"

ALPHA_IP="10.88.0.11"
BETA_IP="10.88.0.12"
ALPHA_RAM="6GiB"
BETA_RAM="4GiB"

AGENT_PUBKEY="$(head -1 ~/.ssh/authorized_keys)"

GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
DOPPLER_TOKEN_ALPHA="${DOPPLER_TOKEN_ALPHA:-}"
DOPPLER_TOKEN_BETA="${DOPPLER_TOKEN_BETA:-}"

# -------- Sanity checks --------
echo "==> Checking prerequisites"
command -v incus >/dev/null || { echo "ERROR: incus not installed"; exit 1; }
id -nG | tr ' ' '\n' | grep -qx incus-admin || {
  echo "ERROR: ops not in incus-admin group. Log out and back in, then re-run."
  exit 1
}
grep -q '^root:1000000:' /etc/subuid || { echo "ERROR: /etc/subuid missing root range"; exit 1; }
grep -q '^root:1000000:' /etc/subgid || { echo "ERROR: /etc/subgid missing root range"; exit 1; }
[ -n "$AGENT_PUBKEY" ] || { echo "ERROR: ~/.ssh/authorized_keys is empty"; exit 1; }

# -------- Incus init --------
if ! incus network show "$BRIDGE_NAME" >/dev/null 2>&1; then
  echo "==> Initialising Incus"
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
else
  echo "==> Incus already initialised"
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

incus profile show alpha-profile >/dev/null 2>&1 || incus profile create alpha-profile
incus profile edit alpha-profile <<EOF
config:
  limits.cpu: "2"
  limits.memory: $ALPHA_RAM
  limits.processes: "4096"
  snapshots.schedule: "@daily"
  snapshots.expiry: "7d"
description: Sizing for alpha (primary agent)
devices: {}
EOF

incus profile show beta-profile >/dev/null 2>&1 || incus profile create beta-profile
incus profile edit beta-profile <<EOF
config:
  limits.cpu: "2"
  limits.memory: $BETA_RAM
  limits.processes: "4096"
  snapshots.schedule: "@daily"
  snapshots.expiry: "7d"
description: Sizing for beta (secondary agent)
devices: {}
EOF

# -------- Agent cloud-init user-data --------
# Baked into every container: SSH, tmux service, tmux config (mouse + OSC 52
# clipboard), Doppler CLI, git identity, and an ed25519 key ready for GitHub.
# Per-container Doppler service tokens are injected post-boot (see below).
# Agent CLIs (Claude Code, Codex, etc.) are installed per-container on demand,
# not baked in — keeps rebuilds fast and agent choice flexible.

AGENT_USER_DATA=$(mktemp)
trap 'rm -f "$AGENT_USER_DATA"' EXIT

# Build gitconfig content conditionally
GITCONFIG_CONTENT=""
if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
  GITCONFIG_CONTENT="[user]
          name = $GIT_USER_NAME
          email = $GIT_USER_EMAIL
      [init]
          defaultBranch = main
      [pull]
          rebase = false"
fi

cat > "$AGENT_USER_DATA" <<EOF
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
      - $AGENT_PUBKEY

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

  - path: /home/agent/.gitconfig
    owner: agent:agent
    permissions: '0644'
    content: |
      $GITCONFIG_CONTENT

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

# -------- Containers --------
for name in alpha beta; do
  if ! incus info "$name" >/dev/null 2>&1; then
    echo "==> Creating $name"
    incus init "$IMAGE" "$name"
  else
    echo "==> $name already exists"
  fi
done

incus profile assign alpha default,agent-base,alpha-profile
incus profile assign beta  default,agent-base,beta-profile

# eth0 IP pin (handle fresh create and re-run)
for pair in "alpha:$ALPHA_IP" "beta:$BETA_IP"; do
  name="${pair%:*}"
  ip="${pair#*:}"
  incus config device remove "$name" eth0 2>/dev/null || true
  incus config device override "$name" eth0 ipv4.address="$ip"
done

incus config set alpha cloud-init.user-data - < "$AGENT_USER_DATA"
incus config set beta  cloud-init.user-data - < "$AGENT_USER_DATA"

# -------- Start + wait --------
echo "==> Starting containers"
for name in alpha beta; do
  state=$(incus info "$name" | awk '/^Status:/ {print $2}')
  if [ "$state" = "RUNNING" ]; then
    incus restart "$name"
  else
    incus start "$name"
  fi
done

echo "==> Waiting for cloud-init inside containers (2–4 min — extra packages this time)"
incus exec alpha -- cloud-init status --wait
incus exec beta  -- cloud-init status --wait

# -------- Doppler service token injection (per-container, post-boot) --------
inject_doppler() {
  local name="$1" token="$2"
  if [ -z "$token" ]; then
    echo "==> Skipping Doppler token for $name (DOPPLER_TOKEN_${name^^} not set)"
    return
  fi
  echo "==> Injecting Doppler token for $name"
  incus exec "$name" -- sudo -iu agent bash -c "echo '$token' | doppler configure set token --scope=/ >/dev/null"
}

inject_doppler alpha "$DOPPLER_TOKEN_ALPHA"
inject_doppler beta  "$DOPPLER_TOKEN_BETA"

# -------- Verify --------
echo
echo "==> Final state"
incus list
echo
echo "==> Service checks"
for name in alpha beta; do
  printf "%-8s ssh=%s  agent-tmux=%s\n" \
    "$name" \
    "$(incus exec "$name" -- systemctl is-active ssh)" \
    "$(incus exec "$name" -- systemctl is-active agent-tmux)"
done

echo
echo "==> GitHub SSH pubkeys (paste into GitHub → Settings → SSH keys)"
for name in alpha beta; do
  echo "--- $name ---"
  incus exec "$name" -- cat /home/agent/.ssh/id_ed25519.pub
done

echo
echo "Bootstrap complete."
echo "Connect from your Mac:"
echo "    ssh alpha     # agent@$ALPHA_IP via bl-host"
echo "    ssh beta      # agent@$BETA_IP  via bl-host"
