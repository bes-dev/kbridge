---
name: kb
description: Talk to the personal knowledge base from any folder. Query the vault, scan the current folder for material that fits the vault, or write new entries. Works without changing CWD.
user-invocable: true
allowed-tools: "Read, Write, Edit, Glob, Grep, Bash, PowerShell, Agent"
---

# /kb — Knowledge Base Access

This skill makes the personal knowledge base available from any current working directory. The vault location is recorded at install time by `setup.sh`.

## Step 0 — Resolve the vault path

Read `~/.claude/skills/kb/vault_path` — a single line containing the absolute path to the vault root. Treat this value as `$VAULT` for the rest of the session.

If the file is missing or empty, the skill is not installed correctly. Tell the user to run `setup.sh [vault-path]` from the harness directory and stop.

## Step 1 — Load vault context

Always start by reading:
- `$VAULT/AGENTS.md` — vault rules (structure, conventions, ingest/query/lint/distill workflows)
- `$VAULT/index.md` — project map (one line per active project)

These define how to operate on the vault. Follow them strictly for the rest of the session. Never change CWD — use absolute paths under `$VAULT/`.

**Search scope — `chats/` is excluded by default.** `$VAULT/chats/` holds saved raw chat transcripts (noise). Before searching, check whether `~/.claude/skills/kb/index_chats` exists (portable: Glob for it; or `test -f` on Unix, `Test-Path` on Windows): if it is **absent** (the default), NEVER search or read `chats/` — discard any Grep/Glob matches under `chats/`; if it is **present**, the user has opted in — treat `chats/` like any other folder. To **toggle**: if the user asks to include/exclude `chats/` in search, create the flag file (Write an empty file) or delete it (`rm` on Unix, `Remove-Item` on Windows) and confirm (this is the same flag Pi's `/kb-index-chats` and Emacs `C-c C-i` set).

## Step 2 — Detect mode from the user's intent

Pick exactly one mode based on what the user said when invoking `/kb`:

### Query mode
Triggers: "что у меня есть про…", "что я знаю о…", "найди…", a question about vault content.
Behavior: search the vault by filename and content, synthesize an answer with `[[page]]` citations. Do not write unless the user explicitly asks to save the synthesis.

### Scan-and-propose mode
Triggers: "осмотрись тут", "что здесь полезного для проекта X", invocation from a CWD outside the vault with a hint about where the material might belong.
Behavior:
1. Survey CWD with Glob / a depth-limited directory listing. Skip junk (`.git`, `node_modules`, `__pycache__`, build artifacts, large binaries, lockfiles).
2. If the candidate set is large (>50 files) or deeply nested, spawn an `Agent` (`subagent_type: Explore`) to triage and return a compact report — protects the main context.
3. Read `index.md` (the project map) and the relevant `projects/<name>/context.md` to understand the target. If no project hint was given, propose the closest match based on content.
4. Output a **plan only** — do not write anything yet. The plan should specify:
   - which source files map to which vault paths,
   - new pages to create (with proposed titles and YAML front matter),
   - existing pages to update with new `[[wikilinks]]`,
   - the line to add to `index.md`,
   - the line to append to `log.md`.
5. Wait for explicit confirmation before executing.

### Write / ingest mode
Triggers: explicit confirmation of a proposed plan, or direct commands like "запиши это в базу", "добавь в проект X".
Behavior: execute the ingest workflow from the vault AGENTS.md. Every new page gets YAML front matter (`title`, `tags`, `created: YYYY-MM-DD`). Append a `## [YYYY-MM-DD] ingest | <source>` line to `log.md`, and update `index.md` only if a new project was created (it is a project map, not a page catalog). Cross-reference with `[[wikilinks]]`. Route by reuse — project-specific material to `projects/<project>/`; reusable cross-project reference to `resources/<topic>/` and dormant projects to `archive/`, both created on demand (the vault AGENTS.md is authoritative).

## Rules

- CWD never changes — always use absolute paths under `$VAULT/` for vault operations.
- Never modify files in `raw/` — those are immutable source materials.
- All new pages use YAML front matter and relative `[[wikilinks]]`.
- One topic per page; split if a page grows too long.
- Never search or read `chats/` unless the user asks or `~/.claude/skills/kb/index_chats` exists (it's excluded from the index by default — see Step 1).
- In scan-and-propose mode, always present the plan and wait for confirmation before writing.
- If a question is better answered by checking the current state of the vault than by guessing, read the files first.

## Sync (optional, may be unconfigured)

The vault can be backed by a remote — optionally end-to-end-encrypted via `git-remote-gcrypt`. The local vault is always plaintext (so you can read/grep it); only the remote is ciphertext. The passphrase/key is handled by gpg-agent and the OS keychain — never by this skill. Drive it through Bash with the sibling script `~/.claude/skills/kb/kb-sync`:

- `kb-sync status` — show the current mode (plain / encrypted) and remote.
- `kb-sync push` — commit local changes and upload. Offer this after write/ingest mode.
- `kb-sync pull` — download remote changes. Run before a query if the vault may be stale on this device.
- `kb-sync init <gcrypt-remote-url> [gpg-key-id]` — export the existing vault to a new encrypted remote (one-time). Omit the key id for a symmetric passphrase.

Only act on sync when the user asks, or offer it after writing. Note: this protects the remote (cloud sees only ciphertext); local device-loss is covered by full-disk encryption, not by this skill.

`kb-sync` is a bash script: on Windows it needs Git Bash (Git for Windows) — run it as `bash ~/.claude/skills/kb/kb-sync <cmd>`. If bash is unavailable, tell the user sync is not set up on this machine and continue without it; encrypted (`gcrypt::`) remotes are not supported on Windows.
