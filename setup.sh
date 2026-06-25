#!/usr/bin/env bash
# Install the knowledge-base harness for both Claude Code and Pi.
#
# Usage:  setup.sh [vault-path] [gcrypt-remote-url] [gpg-key-id]
#   vault-path         absolute or relative path to the knowledge base vault.
#                      Defaults to ~/.obsidian if present, else fails (the harness is
#                      now separate from the vault, so it can't default to its own dir).
#   gcrypt-remote-url  optional — if given, export the vault to this end-to-end-encrypted
#                      remote via git-remote-gcrypt (e.g. gcrypt::/path/in/Dropbox/kb.git).
#   gpg-key-id         optional — encrypt to this GPG key; omit for a symmetric passphrase.
#
# What it does:
#   - symlinks .claude/skills/* into ~/.claude/skills/       (Claude Code skills)
#   - records the vault path in the kb skill's vault_path     (read by BOTH harnesses)
#   - installs the Pi extension globally via `pi install`     (Pi coding agent)
#   - optionally exports the vault to an encrypted remote      (when a gcrypt URL is given)
#
# Idempotent: re-running refreshes symlinks, the recorded path, the Pi install, and the remote.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="${1:-$HOME/.obsidian}"

if [ ! -d "$VAULT_DIR" ]; then
  echo "Error: vault path '$VAULT_DIR' is not a directory. Pass it explicitly: setup.sh <vault-path>" >&2
  exit 1
fi
VAULT_DIR="$(cd "$VAULT_DIR" && pwd)"

if [ ! -f "$VAULT_DIR/AGENTS.md" ]; then
  echo "Warning: $VAULT_DIR has no AGENTS.md — is this really a knowledge base vault?" >&2
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
  [ -f "$KB_SRC/kb-sync" ] && chmod +x "$KB_SRC/kb-sync"
fi

# --- Pi extension ------------------------------------------------------------
PI_STATUS="skipped (pi not on PATH)"
if command -v pi >/dev/null 2>&1; then
  pi install "$HARNESS_DIR/pi" >/dev/null 2>&1 && PI_STATUS="installed globally" || PI_STATUS="failed — run: pi install $HARNESS_DIR/pi"
fi

# --- optional encrypted sync (git-remote-gcrypt) -----------------------------
SYNC_REMOTE="${2:-}"
GPG_KEY="${3:-}"

if command -v git-remote-gcrypt >/dev/null 2>&1; then
  GCRYPT_STATUS="available"
else
  GCRYPT_STATUS="not installed (optional — brew install git-remote-gcrypt gnupg)"
fi

# If a remote was passed, export the vault now (the local copy stays plaintext; only the
# remote is encrypted). gpg-agent prompts for the passphrase — kb-sync never sees it.
SYNC_STATUS="not configured"
if [ -n "$SYNC_REMOTE" ] && [ -x "$KB_SRC/kb-sync" ]; then
  echo
  if KB_VAULT="$VAULT_DIR" "$KB_SRC/kb-sync" init "$SYNC_REMOTE" ${GPG_KEY:+"$GPG_KEY"}; then
    SYNC_STATUS="exported to $SYNC_REMOTE"
  else
    SYNC_STATUS="failed — fix the above, then: kb-sync init $SYNC_REMOTE"
  fi
fi

echo
echo "Vault:             $VAULT_DIR"
echo "Claude skills:     ${installed[*]:-<none>}"
echo "Pi extension:      $PI_STATUS"
echo "git-remote-gcrypt: $GCRYPT_STATUS"
echo "Encrypted sync:    $SYNC_STATUS"
echo
echo "Claude Code — use /kb from any folder. Optional shell helper for ~/.zshrc:"
echo '  kb() { claude "/kb $*"; }'
echo
echo "Pi — /kb and the kb_search tool are now available. Override vault with: export KB_VAULT=<path>"
if [ "$SYNC_STATUS" = "not configured" ]; then
  echo
  echo "Optional — export the vault to an end-to-end-encrypted remote (cloud sees only ciphertext):"
  echo "  re-run: setup.sh \"$VAULT_DIR\" gcrypt::<remote-url> [gpg-key-id]"
  echo "  or:     $DST_SKILLS_DIR/kb/kb-sync init gcrypt::<remote-url> [gpg-key-id]"
fi
