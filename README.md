# incus-ai-agents

Bootstrap a cloud Ubuntu 24.04 VPS as an Incus host running two AI coding
agent containers. Each container is a blank Ubuntu 24.04 with:

- SSH, tmux (mouse + OSC 52 clipboard), git, Doppler CLI
- Auto-generated ed25519 key ready to add to GitHub
- Persistent `agent` tmux session via systemd

Agent CLIs (Claude Code, Codex, etc.) are installed per-container on demand,
not baked in — keeps rebuilds fast and lets you pick per container.

## Files

- `host-cloud-init.yaml` — VPS first-boot (paste into cloud-init User Data)
- `bootstrap.sh` — Post-login Incus setup on the host
- `export-golden.sh` — Snapshot + export both containers as known-good tarballs
- `restore-golden.sh` — Recreate both containers from golden tarballs

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
   GIT_USER_NAME="Alpha Agent" GIT_USER_EMAIL="you+alpha@example.com" \
   DOPPLER_TOKEN_ALPHA=... DOPPLER_TOKEN_BETA=... \
     ./bootstrap.sh
   ```
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

## Capturing a known-good state

Once everything is configured the way you like, capture golden exports:
```bash
./export-golden.sh
```
This writes timestamped tarballs to `/srv/incus-exports/` and points
`{alpha,beta}-golden.tar.gz` symlinks at the latest.

Copy the tarballs off-box (e.g. iCloud, S3, another VPS) for disaster recovery.

## Recovery on a fresh host

1. Rebuild VPS (same `host-cloud-init.yaml` flow).
2. Copy your golden tarballs back to `/srv/incus-exports/`.
3. Run `bootstrap.sh` to set up Incus (skip — it'll stop early if containers
   already exist, but the initial Incus init is needed). Alternative: extract
   just the `incus admin init --preseed` block and run that.
4. Run `./restore-golden.sh`.

## Container IPs

- alpha: `10.88.0.11`
- beta: `10.88.0.12`

Suggested `~/.ssh/config` on your Mac:
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

- Snapshots are taken daily and expire after 7 days (configured in the
  per-container profile).
- UFW trusts the `incusbr0` bridge; containers can't be reached from the
  public internet, only via the host.
- The host cloud-init hardens SSH (pubkey-only, no root login, `ops`-only).
