#!/bin/bash
# Runs the app and the vault helper as the current user against ./build/devroot.
# Nothing is installed system-wide and no administrator password is needed.
# In this mode the vault is NOT protected from deletion: use install.sh for the real setup.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh debug
export FOCUSSPRINT_ROOT="$PWD/build/devroot"
mkdir -p "$FOCUSSPRINT_ROOT"
pkill -f "build/focussprint-vaultd" 2>/dev/null || true
nohup build/focussprint-vaultd >> build/vaultd.log 2>&1 &
echo "helper pid $! (log: build/vaultd.log)"
open -n --env "FOCUSSPRINT_ROOT=$FOCUSSPRINT_ROOT" "build/YoungWonks Focus.app"
