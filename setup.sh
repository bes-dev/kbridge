#!/usr/bin/env bash
# Install the knowledge-base harness for both Claude Code and Pi.
#
# Usage:  setup.sh [vault-path]
#   vault-path  absolute or relative path to the knowledge base vault.
#               Defaults to ~/.obsidian if present, else fails (the harness is
#               now separate from the vault, so it can't default to its own dir).
#
# What it does:
#   - symlinks .claude/skills/* into ~/.claude/skills/      (Claude Code skills)
#   - records the vault path in the kb skill's vault_path    (read by BOTH harnesses)
#   - installs the Pi extension globally via `pi install`    (Pi coding agent)
#
# Idempotent: re-running refreshes symlinks, the recorded path, and the Pi install.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="${1:-$HOME/.obsidian}"

if [ ! -d "$VAULT_DIR" ]; then
  echo "Error: vault path '$VAULT_DIR' is not a directory. Pass it explicitly: setup.sh <vault-path>" >&2
  exit 1
fi
VAULT_DIR="$(cd "$VAULT_DIR" && pwd)"

if [ ! -f "$VAULT_DIR/CLAUDE.md" ]; then
  echo "Warning: $VAULT_DIR has no CLAUDE.md — is this really a knowledge base vault?" >&2
fi

# --- Claude Code skills ------------------------------------------------------
SRC_SKILLS_DIR="$HARNESS_DIR/.claude/skills"
DST_SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$DST_SKILLS_DIR"

installed=()
for src in "$SRC_SKILLS_DIR"/*/; do
  [ -d "$src" ] || continue
  name="$(basename "$src")"
  src="${src%/}"
  dst="$DST_SKILLS_DIR/$name"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    echo "Skip $name: $dst exists and is not a symlink. Remove it manually to reinstall." >&2
    continue
  fi
  ln -s "$src" "$dst"
  installed+=("$name")
done

# --- single recorded vault path (read by the Claude skill AND the Pi ext) ----
KB_SRC="$SRC_SKILLS_DIR/kb"
if [ -d "$KB_SRC" ]; then
  echo "$VAULT_DIR" > "$KB_SRC/vault_path"
fi

# --- Pi extension ------------------------------------------------------------
PI_STATUS="skipped (pi not on PATH)"
if command -v pi >/dev/null 2>&1; then
  pi install "$HARNESS_DIR/pi" >/dev/null 2>&1 && PI_STATUS="installed globally" || PI_STATUS="failed — run: pi install $HARNESS_DIR/pi"
fi

echo "Vault:            $VAULT_DIR"
echo "Claude skills:    ${installed[*]:-<none>}"
echo "Pi extension:     $PI_STATUS"
echo
echo "Claude Code — use /kb from any folder. Optional shell helper for ~/.zshrc:"
echo '  kb() { claude "/kb $*"; }'
echo
echo "Pi — /kb and the kb_search tool are now available. Override vault with: export KB_VAULT=<path>"
