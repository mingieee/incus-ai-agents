#!/usr/bin/env bash
# Install and configure opencode against the BytePlus ModelArk Coding Plan
# (OpenAI-compatible endpoint). Designed to run on any container provisioned
# by this repo's bootstrap.sh — expects Doppler already configured for the
# `agent` user and the shared project to contain `BYTEPLUS_ARK_CODING_API_KEY`.
#
# Usage:  ssh agent@<container> 'bash -s' < install-opencode-byteplus.sh
#    or:  scp install-opencode-byteplus.sh agent@<container>:~/ && ssh agent@<container> bash install-opencode-byteplus.sh

set -euo pipefail

SECRET_NAME="BYTEPLUS_ARK_CODING_API_KEY"
CONFIG_DIR="$HOME/.config/opencode"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
LAUNCHER="$HOME/.local/bin/oc"

# --- Preflight ------------------------------------------------------------

command -v doppler >/dev/null || {
  echo "ERROR: doppler CLI not found. Run bootstrap.sh first." >&2
  exit 1
}

# The *general* ModelArk key (BYTEPLUS_ARK_API_KEY) draws from a different
# quota pool than the Coding Plan and will fail with a misleading error for
# coding-plan models. Use the Coding Plan key explicitly.
if ! doppler secrets get "$SECRET_NAME" --plain >/dev/null 2>&1; then
  echo "ERROR: Doppler secret $SECRET_NAME is missing." >&2
  echo "Add it from your BytePlus ModelArk console (Coding Plan key, NOT the general ModelArk key)." >&2
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
  "model": "byteplus/ark-code-latest",
  "autoupdate": true,
  "share": "manual",
  "provider": {
    "byteplus": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "BytePlus ModelArk",
      "options": {
        "baseURL": "https://ark.ap-southeast.bytepluses.com/api/coding/v3",
        "apiKey": "{env:${SECRET_NAME}}"
      },
      "models": {
        "ark-code-latest":     { "name": "Auto (latest coding model)" },
        "dola-seed-2.0-pro":   { "name": "Dola Seed 2.0 Pro" },
        "dola-seed-2.0-lite":  { "name": "Dola Seed 2.0 Lite" },
        "dola-seed-2.0-code":  { "name": "Dola Seed 2.0 Code" },
        "bytedance-seed-code": { "name": "ByteDance Seed Code" },
        "glm-5.1":             { "name": "GLM 5.1" },
        "glm-4.7":             { "name": "GLM 4.7" },
        "kimi-k2.5":           { "name": "Kimi K2.5",
                                 "options": { "thinking": { "type": "enabled" } } },
        "gpt-oss-120b":        { "name": "GPT-OSS 120B" }
      }
    }
  }
}
JSON

# --- Launcher -------------------------------------------------------------

mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<'SH'
#!/usr/bin/env bash
exec doppler run -- opencode "$@"
SH
chmod +x "$LAUNCHER"

echo
echo "Done. Launch opencode with:  oc"
