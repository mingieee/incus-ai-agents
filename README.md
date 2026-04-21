# incus-ai-agents

Bootstrap a cloud Ubuntu 24.04 VPS as an Incus host running any number of AI
coding agent containers. Each container is a blank Ubuntu 24.04 with:

- SSH, tmux (mouse + OSC 52 clipboard), git, Doppler CLI
- Auto-generated ed25519 key ready to add to GitHub
- Persistent `agent` tmux session via systemd

Agent CLIs (Claude Code, Codex, etc.) are installed per-container on demand,
not baked in — keeps rebuilds fast and lets you pick per container.

## Files

- `host-cloud-init.yaml` — VPS first-boot (paste into cloud-init User Data)
- `bootstrap.sh` — Interactive post-login Incus setup on the host
- `export-golden.sh` — Snapshot + export every agent container as tarballs
- `restore-golden.sh` — Recreate containers from golden tarballs

## First-time setup

1. **Rebuild VPS** with Ubuntu 24.04. Paste `host-cloud-init.yaml` into the
   User Data / Cloud-Init field. Replace `<YOUR_SSH_PUBKEY>` with your
   ed25519 public key first.
2. **SSH in as `ops`**, then log out and back in so the `incus-admin` group
   takes effect.
3. **Copy and run `bootstrap.sh`**:
   ```bash
   scp bootstrap.sh ops@<vps>:~/
   ssh ops@<vps>
   ./bootstrap.sh
   ```

   The script will prompt for:
   - **Number of VMs** (default: 2)
   - **VM names** (default: Greek alphabet in order — `alpha beta gamma …`)
   - **RAM per VM in GiB** — default is an equal split of host RAM minus a
     2 GiB reserve for the host itself
   - **Git user.name / user.email** baked into each container (optional)
   - **Doppler service token per VM** (optional)

   It then prints a plan and asks to confirm before building anything.
   IPs are auto-allocated on the `10.88.0.0/24` bridge starting at
   `10.88.0.11` (one per VM).

### Non-interactive / scripted runs

Every prompt has a matching env var, so you can skip the prompts entirely:

```bash
VM_COUNT=3 \
VM_NAMES="alpha beta gamma" \
VM_RAM="6 4 4" \
GIT_USER_NAME="Agent" GIT_USER_EMAIL="you@example.com" \
DOPPLER_TOKEN_ALPHA=... DOPPLER_TOKEN_BETA=... DOPPLER_TOKEN_GAMMA=... \
ASSUME_YES=1 \
  ./bootstrap.sh
```

Env vars:

| Var | Default | Notes |
|---|---|---|
| `VM_COUNT` | `2` | Number of VMs. |
| `VM_NAMES` | `alpha beta gamma …` | Space-separated names; must match `VM_COUNT`. Greek alphabet in order; falls back to `vm25 vm26 …` past 24. |
| `VM_RAM` | equal split | Space-separated GiB integers, same order as `VM_NAMES`. |
| `HOST_RESERVE_GB` | `2` | GiB kept for the host when computing default split. |
| `IP_BASE` | `11` | Last octet of first VM's IP on `incusbr0`. |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | unset | Baked into `~/.gitconfig` inside each container. |
| `DOPPLER_TOKEN_<NAME>` | unset | Per-VM service token. `<NAME>` is the VM name uppercased, hyphens replaced with underscores (e.g. `vm-1` → `DOPPLER_TOKEN_VM_1`). |
| `DOPPLER_TOKEN_<NAME>_FILE` | unset | Alternative: path to a file containing the token. Preferred over the env-var form for scripted runs — keeps the secret out of shell history and `/proc/<pid>/environ`. |
| `ASSUME_YES` | `0` | Set to `1` to skip the final confirmation prompt. |
| `INIT_ONLY` | `0` | Set to `1` to run only `incus admin init` and exit, without creating containers. Used by the restore-from-golden flow. |

4. **Add each container's GitHub SSH key** (printed at the end of
   `bootstrap.sh`) to your GitHub account.
5. **Install agent CLIs** in each container as needed. Examples:
   ```bash
   # Claude Code
   ssh agent@<container-ip>
   curl -fsSL https://claude.ai/install.sh | bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

   # Codex CLI (via npm, user-local prefix)
   curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
   sudo apt install -y nodejs bubblewrap
   mkdir -p ~/.npm-global
   npm config set prefix ~/.npm-global
   echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
   npm install -g @openai/codex
   ```

## Doppler service tokens: persistence & security

### Where the token lives

Once injected, the token is written inside the container to
`/home/agent/.doppler/.doppler.yaml` (mode `0600`, owned by `agent`). From
that point on, `doppler run -- <cmd>` and friends pick it up automatically
for the `agent` user.

Persistence across events:

| Event | Token survives? |
|---|---|
| Container restart / reboot | Yes (part of the container filesystem) |
| Host VPS reboot | Yes |
| Re-running `bootstrap.sh` on an existing container | Yes (not touched unless you pass a new token) |
| Destroying & recreating the container | **No** — re-inject |
| Full VPS rebuild from scratch | **No** — re-inject |
| Restore from a golden tarball captured *after* injection | Yes |

So the durable pattern for disaster recovery is: inject once, then
`./export-golden.sh`. A future `restore-golden.sh` on a fresh VPS brings
the tokens back with the container — no re-entry needed.

### How the token is kept out of logs & history

- The interactive prompt uses silent read — pasted tokens don't echo to
  your terminal or scrollback.
- Injection pipes the token over stdin through `incus exec` → `sudo` →
  `doppler configure set token`. The token never appears in:
  - `ps` output on the host
  - your host shell's history
  - the container's `/var/log/auth.log` (sudo only logs the command, which
    doesn't contain the secret)
- The resulting config file inside the container is `0600` and only
  readable by `agent` (and root). The container is not reachable from the
  public internet — only from the host via `incusbr0`.

### Feeding tokens to a scripted run

For non-interactive bootstraps, prefer the `_FILE` form over inlining the
token in the environment. That keeps it out of shell history and out of
`/proc/<pid>/environ`:

```bash
# Run as the same user you'll run ./bootstrap.sh as (no sudo needed):
install -m 600 /dev/stdin "$HOME/alpha.token" <<< 'dp.st.prod.xxxxx'
install -m 600 /dev/stdin "$HOME/beta.token"  <<< 'dp.st.prod.yyyyy'

DOPPLER_TOKEN_ALPHA_FILE="$HOME/alpha.token" \
DOPPLER_TOKEN_BETA_FILE="$HOME/beta.token"  \
ASSUME_YES=1 \
  ./bootstrap.sh

shred -u "$HOME"/*.token   # once you've confirmed the containers are healthy
```

## Capturing a known-good state

Once everything is configured the way you like, capture golden exports:

```bash
./export-golden.sh            # all containers with the agent-base profile
./export-golden.sh alpha beta # or a specific subset
```

This writes timestamped tarballs to `/srv/incus-exports/` and refreshes
`<name>-golden.tar.gz` as a copy of the latest (real file, not a symlink,
so off-box backups that flatten symlinks still restore cleanly).

Copy the tarballs off-box (e.g. iCloud, S3, another VPS) for disaster recovery.

## Recovery on a fresh host

1. Rebuild VPS (same `host-cloud-init.yaml` flow).
2. Copy your golden tarballs back to `/srv/incus-exports/`.
3. Run `INIT_ONLY=1 ./bootstrap.sh` — initialises Incus (bridge + storage
   pool) without creating any containers, so the restore can import them
   cleanly.
4. Run `./restore-golden.sh` (or pass specific names).

## Network

- Bridge: `incusbr0` (`10.88.0.0/24`)
- IPs are assigned in order: `10.88.0.11`, `10.88.0.12`, … (override with `IP_BASE`)
- UFW trusts the `incusbr0` bridge; containers can't be reached from the
  public internet, only via the host.

Suggested `~/.ssh/config` on your client (adjust names/IPs to what you chose):
```
Host bl-host
  HostName <your-vps-ip>
  User ops

Host alpha
  HostName 10.88.0.11
  User agent
  ProxyJump bl-host

Host beta
  HostName 10.88.0.12
  User agent
  ProxyJump bl-host
```

## Notes

- Snapshots are taken daily and expire after 7 days (configured in each
  per-container profile).
- The host cloud-init hardens SSH (pubkey-only, no root login, `ops`-only).
