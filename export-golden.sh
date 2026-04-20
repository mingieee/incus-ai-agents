#!/bin/bash
# Capture "golden" exports of every agent container as a known-good baseline.
# Run on the Incus host as ops.
#
# Targets every container with the agent-base profile attached (i.e. anything
# bootstrap.sh created). Override by passing names as arguments:
#   ./export-golden.sh alpha beta
#
# Output: /srv/incus-exports/<name>-golden.tar.gz plus a timestamped copy.
# Timestamped copy is for forensics if a later golden breaks something.

set -euo pipefail

EXPORT_DIR="/srv/incus-exports"
STAMP="$(date +%F_%H%M%S)"

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  mapfile -t TARGETS < <(incus list --format json | jq -r '.[] | select(.profiles | index("agent-base")) | .name')
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no containers found with the agent-base profile, and no names given on the command line."
  exit 1
fi

echo "==> Exporting: ${TARGETS[*]}"

sudo mkdir -p "$EXPORT_DIR"
sudo chown "$(id -u):$(id -g)" "$EXPORT_DIR"

for name in "${TARGETS[@]}"; do
  echo "==> Snapshotting $name"
  # Take a named snapshot so the export is consistent even if container keeps running
  incus snapshot create "$name" "pre-golden-$STAMP"

  echo "==> Exporting $name (this takes a minute, depends on container size)"
  incus export "$name" "$EXPORT_DIR/${name}-${STAMP}.tar.gz"

  # Symlink as the current golden
  ln -sf "${name}-${STAMP}.tar.gz" "$EXPORT_DIR/${name}-golden.tar.gz"

  echo "==> $name done: $EXPORT_DIR/${name}-golden.tar.gz -> ${name}-${STAMP}.tar.gz"
done

echo
echo "Golden images written:"
ls -lh "$EXPORT_DIR"
