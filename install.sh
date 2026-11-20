#!/usr/bin/env bash
# Links this folder into WoW Forever's AddOns folder, so edits here show up in-game after /reload.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WOW="$HOME/Faugus/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_"
ADDONS="$WOW/Interface/AddOns"
LINK="$ADDONS/$(basename "$SRC")"

if [ ! -d "$WOW" ]; then
    echo "WoW Forever not found at: $WOW" >&2
    exit 1
fi

mkdir -p "$ADDONS"
if [ -L "$LINK" ]; then
    echo "Already linked: $LINK -> $(readlink "$LINK")"
elif [ -e "$LINK" ]; then
    echo "Something else already exists at $LINK; not touching it." >&2
    exit 1
else
    ln -s "$SRC" "$LINK"
    echo "Linked $LINK -> $SRC"
fi
