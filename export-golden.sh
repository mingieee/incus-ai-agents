#!/bin/bash
# Capture "golden" exports of alpha and beta as a known-good baseline.
# Run on the Incus host as ops.
#
# Output: /srv/incus-exports/<name>-golden.tar.gz plus a timestamped copy.
# Timestamped copy is for forensics if a later golden breaks something.

set -euo pipefail

EXPORT_DIR="/srv/incus-exports"
STAMP="$(date +%F_%H%M%S)"

sudo mkdir -p "$EXPORT_DIR"
sudo chown "$(id -u):$(id -g)" "$EXPORT_DIR"

for name in alpha beta; do
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
