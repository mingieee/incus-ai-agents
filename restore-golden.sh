#!/bin/bash
# Restore alpha and beta from their golden Incus exports.
# Run on a fresh Incus host (after host-cloud-init.yaml + `incus admin init` via bootstrap.sh).
#
# Expects /srv/incus-exports/{alpha,beta}-golden.tar.gz to exist.
# Faster than the fresh-install path: no package downloads, no secret re-entry.

set -euo pipefail

EXPORT_DIR="/srv/incus-exports"

for name in alpha beta; do
  GOLDEN="$EXPORT_DIR/${name}-golden.tar.gz"
  [ -f "$GOLDEN" ] || { echo "ERROR: $GOLDEN not found"; exit 1; }

  if incus info "$name" >/dev/null 2>&1; then
    echo "==> $name already exists — skipping import. Delete it first if you want to restore."
    continue
  fi

  echo "==> Importing $name from $GOLDEN"
  incus import "$GOLDEN"
  incus start "$name"
done

echo
incus list
echo
echo "Restore complete. Verify with:"
echo "    ssh agent@10.88.0.11   # alpha"
echo "    ssh agent@10.88.0.12   # beta"
