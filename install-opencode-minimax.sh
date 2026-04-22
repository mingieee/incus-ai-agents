#!/usr/bin/env bash
# Install and configure opencode against the MiniMax Coding Plan
# (Anthropic-compatible endpoint). Designed to run on any container
# provisioned by this repo's bootstrap.sh — expects Doppler already
# configured for the `agent` user and the shared project to contain
# `MINIMAX_CODING_PLAN_API_KEY`.
#
# Usage:  ssh agent@<container> 'bash -s' < install-opencode-minimax.sh
#    or:  scp install-opencode-minimax.sh agent@<container>:~/ && ssh agent@<container> bash install-opencode-minimax.sh

set -euo pipefail

SECRET_NAME="MINIMAX_CODING_PLAN_API_KEY"
CONFIG_DIR="$HOME/.config/opencode"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
LAUNCHER="$HOME/.local/bin/oc"

# --- Preflight ------------------------------------------------------------

command -v doppler >/dev/null || {
  echo "ERROR: doppler CLI not found. Run bootstrap.sh first." >&2
  exit 1
}

# Verify the coding-plan key is actually in Doppler. The *general* key
# (MINIMAX_API_KEY) draws from a different quota pool and will return a
# misleading "insufficient balance (1008)" error for coding-plan models.
if ! doppler secrets get "$SECRET_NAME" --plain >/dev/null 2>&1; then
  echo "ERROR: Doppler secret $SECRET_NAME is missing." >&2
  echo "Add it from your MiniMax console (Coding Plan / Highspeed key, NOT the general Pay-as-you-go key)." >&2
  exit 1
fi

# --- Install --------------------------------------------------------------

# Put opencode's install target on PATH *before* the existence check so we
# don't reinstall when it's already there but PATH hasn't been reloaded yet.
grep -q 'opencode/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
grep -q '.local/bin'   "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"'   >> "$HOME/.bashrc"
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"

if ! command -v opencode >/dev/null; then
  curl -fsSL https://opencode.ai/install | bash
fi

opencode --version

# --- Config ---------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "minimax/MiniMax-M2.7-highspeed",
  "autoupdate": true,
  "share": "manual",
  "provider": {
    "minimax": {
      "npm": "@ai-sdk/anthropic",
      "name": "MiniMax",
      "options": {
        "baseURL": "https://api.minimax.io/anthropic/v1",
        "apiKey": "{env:${SECRET_NAME}}"
      },
      "models": {
        "MiniMax-M2.7-highspeed": { "name": "MiniMax M2.7 (highspeed)" },
        "MiniMax-M2.7":           { "name": "MiniMax M2.7" }
      }
    }
  }
}
JSON

# --- Launcher -------------------------------------------------------------

# Doppler injects the key at launch. ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN
# are unset so nothing else in the environment can hijack the endpoint opencode
# is configured to use (Minimax's Anthropic-compatible mirror).
mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<'SH'
#!/usr/bin/env bash
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
exec doppler run -- opencode "$@"
SH
chmod +x "$LAUNCHER"

echo
echo "Done. Launch opencode with:  oc"
