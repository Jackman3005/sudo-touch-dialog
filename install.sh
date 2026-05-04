#!/bin/bash
# Symlink scripts from this repo into ~/.local/bin/ so the repo is the
# source of truth. Idempotent — running twice is fine.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
bin="$HOME/.local/bin"
mkdir -p "$bin"

for f in sudo-askpass sudo-touch-dialog sudo-askpass-bridge; do
    src="$repo/bin/$f"
    dst="$bin/$f"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        echo "ok   $dst -> $src (already linked)"
        continue
    fi
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        backup="$dst.bak.$(date +%s)"
        mv "$dst" "$backup"
        echo "moved existing $dst -> $backup"
    fi
    ln -sfn "$src" "$dst"
    echo "link $dst -> $src"
done

echo
echo "Next steps (manual, one-time):"
echo "  1. Source the Hyprland rules from your hyprland.conf:"
echo "       source = $repo/config/hyprland-windowrules.conf"
echo "     and remove any inline duplicates, then 'hyprctl reload'."
echo
echo "  2. Add the sudo() shim to ~/.bashrc for non-interactive shells."
echo "     See docs/claude-integration.md for the snippet."
