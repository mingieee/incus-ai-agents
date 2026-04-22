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
- `install-opencode-minimax.sh` — Install opencode + MiniMax Coding Plan config on a container
- `install-opencode-byteplus.sh` — Install opencode + BytePlus ModelArk Coding Plan config on a container

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
   - **Doppler service token per VM** (optional)
   - **GitHub PAT secret name** — which Doppler secret holds your GitHub PAT
     (default `GITHUB_TOKEN`). Used to auto-register each VM's SSH key on
     GitHub and pull down your verified emails as identity options.
   - **Git identity per VM** — pick from a numbered list of your verified
     GitHub emails or enter a custom one; then a `user.name` per VM

   It then prints a plan and asks to confirm before building anything.
   IPs are auto-allocated on the `10.88.0.0/24` bridge starting at
   `10.88.0.11` (one per VM).
4. **GitHub SSH keys** — if the Doppler config pointed at by a VM's service
   token has a secret matching `GITHUB_PAT_SECRET_NAME` (PAT with
   `admin:public_key` scope), bootstrap generates an ed25519 keypair on the
   host for each container, uploads the pubkey to GitHub before ever
   creating the container, and bakes both keys into the container's
   cloud-init. For VMs without a PAT, the pubkey is still printed at the
   end — paste it into GitHub → Settings → SSH keys yourself.
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

   # opencode — MiniMax Coding Plan (see "opencode" section below)
   ssh agent@<container> 'bash -s' < install-opencode-minimax.sh

   # opencode — BytePlus ModelArk Coding Plan
   ssh agent@<container> 'bash -s' < install-opencode-byteplus.sh
   ```

### Non-interactive / scripted runs

Every prompt has a matching env var, so you can skip the prompts entirely:

```bash
VM_COUNT=3 \
VM_NAMES="alpha beta gamma" \
VM_RAM="6 4.5 4.5" \
DOPPLER_TOKEN_ALPHA=... DOPPLER_TOKEN_BETA=... DOPPLER_TOKEN_GAMMA=... \
GITHUB_PAT_SECRET_NAME=GITHUB_TOKEN \
GIT_USER_EMAIL_ALPHA="you+alpha@example.com" \
GIT_USER_EMAIL_BETA="you+beta@example.com" \
GIT_USER_EMAIL_GAMMA="you+gamma@example.com" \
GIT_USER_NAME_ALPHA="Alpha Agent" \
GIT_USER_NAME_BETA="Beta Agent" \
GIT_USER_NAME_GAMMA="Gamma Agent" \
ASSUME_YES=1 \
  ./bootstrap.sh
```

Env vars:

| Var | Default | Notes |
|---|---|---|
| `VM_COUNT` | `2` | Number of VMs. |
| `VM_NAMES` | `alpha beta gamma …` | Space-separated names; must match `VM_COUNT`. Greek alphabet in order; falls back to `vm25 vm26 …` past 24. |
| `VM_RAM` | equal split | Space-separated GiB values, same order as `VM_NAMES`. Integer or `.5` increments (e.g. `4 4.5`). |
| `HOST_RESERVE_GB` | `2` | GiB kept for the host when computing the default split (doesn't cap what you can enter for `VM_RAM`). |
| `IP_BASE` | `11` | Last octet of first VM's IP on `incusbr0`. |
| `GITHUB_PAT_SECRET_NAME` | `GITHUB_TOKEN` | Name of the Doppler secret that stores your GitHub PAT. Used to register SSH keys on GitHub and list verified emails. |
| `GIT_USER_EMAIL_<NAME>` | unset | Per-VM `user.email`. Skips the picker for that VM. Same `<NAME>` encoding as `DOPPLER_TOKEN_<NAME>`. |
| `GIT_USER_NAME` | unset | Default `user.name` applied to every VM (used as the per-VM prompt default). |
| `GIT_USER_NAME_<NAME>` | unset | Per-VM override for `user.name`. |
| `DOPPLER_TOKEN_<NAME>` | unset | Per-VM service token. `<NAME>` is the VM name uppercased, hyphens replaced with underscores (e.g. `vm-1` → `DOPPLER_TOKEN_VM_1`). |
| `DOPPLER_TOKEN_<NAME>_FILE` | unset | Alternative: path to a file containing the token. Preferred over the env-var form for scripted runs — keeps the secret out of shell history and `/proc/<pid>/environ`. |
| `ASSUME_YES` | `0` | Set to `1` to skip the final confirmation prompt. |
| `INIT_ONLY` | `0` | Set to `1` to run only `incus admin init` and exit, without creating containers. Used by the restore-from-golden flow. |

## GitHub PAT via Doppler

Once you've given bootstrap a Doppler service token per VM and a `GITHUB_PAT_SECRET_NAME`:

1. Bootstrap hits the Doppler REST API with each VM's service token and pulls
   down the PAT stored under that secret name.
2. With that PAT, it calls the GitHub REST API to list your verified email
   addresses — these show up as numbered options in the git-identity prompt.
3. It generates an ed25519 keypair on the host (per VM, in a mode-700 tempdir
   cleaned up on exit), then uploads each pubkey to your GitHub account
   titled `agent@<vmname>`. Already-registered keys are treated as success.
4. The private + public keys are baked into the container's cloud-init so
   the VM wakes up with them in `/home/agent/.ssh/`.

Additionally, post-boot, bootstrap pipes the same PAT into the container's
`gh auth login --with-token` (stdin-only, never on command line), so the
`agent` user can run `gh`, `gh repo clone`, `gh pr`, etc. without an
interactive login. `git_protocol` is set to `ssh` so git URLs use the
SSH keys we just registered.

Required PAT scopes:
- `admin:public_key` — SSH key upload
- `user:email` — enumerate verified addresses
- `repo` (or finer-grained repo perms) — so the pre-authenticated `gh`
  inside each container can do the work you want it to

Re-runs are idempotent — keys already on GitHub are detected, not duplicated.

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

## opencode (MiniMax / BytePlus Coding Plans)

`install-opencode-minimax.sh` and `install-opencode-byteplus.sh` set up the
[opencode](https://opencode.ai) TUI on a container and wire it to a single
coding-plan provider. They assume the container already has Doppler
configured (by `bootstrap.sh`) and the shared Doppler project contains the
right API key.

### Prerequisites — Doppler secret names

Add the **coding-plan** key (not the general API key) to your shared
Doppler project:

| VM role | Doppler secret name | Source |
|---|---|---|
| MiniMax Coding Plan | `MINIMAX_CODING_PLAN_API_KEY` | platform.minimax.io → API Keys → *Create Token Plan Key* (or your Highspeed plan's key slot) |
| BytePlus Coding Plan | `BYTEPLUS_ARK_CODING_API_KEY` | console.byteplus.com → ModelArk → Coding Plan |

Each provider sells **two separate API keys**: a general Pay-as-you-go key
and a Coding-Plan key. They draw from different quota pools. Using the
wrong one yields a misleading `"insufficient balance"` error (Minimax
returns error code **1008**) even though the key authenticates — see
Troubleshooting below.

### Install

Per container, run one of the scripts from the host:

```bash
ssh agent@gamma 'bash -s' < install-opencode-minimax.sh
ssh agent@delta 'bash -s' < install-opencode-byteplus.sh
```

The script:

1. Verifies `doppler` is present and the required secret exists (fails
   fast if not).
2. Installs opencode via the official one-liner (`opencode.ai/install`).
3. Writes `~/.config/opencode/opencode.json` with the provider wired to
   the right Doppler secret via opencode's `{env:VAR}` substitution —
   no key ever lands on disk.
4. Writes a short `~/.local/bin/oc` launcher that runs opencode under
   `doppler run`, so the key arrives as an env var at launch time only.

### Launch

```bash
ssh agent@gamma -- oc
```

### What the configs pin

- **model** pinned per provider → no picker on every launch
  (`minimax/MiniMax-M2.7-highspeed` on Gamma, `byteplus/ark-code-latest`
  on Delta — the latter auto-selects whichever BytePlus model is
  currently best for coding).
- **autoupdate: true** → opencode self-updates.
- **share: "manual"** → sessions aren't auto-published to opencode.ai.
- **Kimi-K2.5** (BytePlus) has `"thinking": { "type": "enabled" }` so
  Ctrl+P → "Show thinking" surfaces the reasoning trace.

### Troubleshooting

**HTTP 500 with `"insufficient balance (1008)"` from MiniMax.** Your
`MINIMAX_CODING_PLAN_API_KEY` is almost certainly pointing at a general
Pay-as-you-go key. Auth is succeeding; the key just doesn't have access
to the coding-plan quota pool. Regenerate specifically from the Coding
Plan / Token Plan section of the Minimax console and update the secret.

**`oc` says the endpoint is Anthropic's, not MiniMax's.** Something in
the shell has set `ANTHROPIC_BASE_URL` or `ANTHROPIC_AUTH_TOKEN`. The
launcher unsets both, but if you're invoking `opencode` directly
without `oc`, those env vars hijack the config's `baseURL`. Always
launch via `oc`, or add the `unset` to your shell startup.

**`doppler run` says the secret is missing.** The Doppler service
token on the container is scoped to a different project than the one
holding the key. Re-run `bootstrap.sh` on that container with a valid
service token for the shared project, or `doppler configure set token`
manually.

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
