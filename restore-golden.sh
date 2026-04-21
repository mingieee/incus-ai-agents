#!/bin/bash
# Restore agent containers from their golden Incus exports.
# Run on a fresh Incus host (after host-cloud-init.yaml + `incus admin init`
# via bootstrap.sh).
#
# Targets every *-golden.tar.gz in /srv/incus-exports/. Override by passing
# names as arguments:
#   ./restore-golden.sh alpha beta
#
# Faster than the fresh-install path: no package downloads, no secret re-entry.

set -euo pipefail

EXPORT_DIR="/srv/incus-exports"

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=()
  shopt -s nullglob
  for f in "$EXPORT_DIR"/*-golden.tar.gz; do
    base="${f##*/}"
    TARGETS+=("${base%-golden.tar.gz}")
  done
  shopt -u nullglob
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no *-golden.tar.gz files found in $EXPORT_DIR, and no names given on the command line."
  exit 1
fi

echo "==> Restoring: ${TARGETS[*]}"

for name in "${TARGETS[@]}"; do
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
echo "Restore complete."
