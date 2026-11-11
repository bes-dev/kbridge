---
name: kb
description: Talk to the personal knowledge base from any folder. Query the vault, scan the current folder for material that fits the vault, or write new entries. Works without changing CWD.
user-invocable: true
allowed-tools: "Read, Write, Edit, Glob, Grep, Bash, PowerShell, Agent"
---

# /kb — Knowledge Base Access

The vault is a markdown wiki under one recorded root. This skill only gets you there; **the vault's own `AGENTS.md` is the authority** on structure, article format, links and workflows.

## Step 0 — Resolve the vault path

Read `~/.claude/skills/kb/vault_path` — one line, the absolute vault root. Treat it as `$VAULT`. If the file is missing or empty, tell the user to run `setup.sh [vault-path]` from the harness directory and stop.

## Step 1 — Load vault context

Read `$VAULT/AGENTS.md` (rules) and `$VAULT/index.md` (project map), and follow them strictly. Never change CWD — use absolute paths under `$VAULT/`.

**`chats/` is excluded by default.** If `~/.claude/skills/kb/index_chats` is **absent**, never search or read `$VAULT/chats/`; if present, treat it like any folder. To toggle on request, create (empty file) or delete that flag and confirm — it is shared with Pi's `/kb-index-chats`.

## Step 2 — Detect the mode

- **Query** — a question about vault content ("что у меня есть про…", "найди…"): run the Query workflow from `AGENTS.md`. Don't write unless asked.
- **Scan-and-propose** — "осмотрись тут", "что здесь полезного для проекта X": survey CWD (skip `.git`, `node_modules`, build output, binaries; >50 files → triage with an `Agent`, `subagent_type: Explore`), read the target project's `index.md` and `context.md`, then output a **plan only** — which material goes to `raw/`, which articles are extended or created (title, category), which links are added, the `log.md` line. Wait for confirmation.
- **Write / ingest** — a confirmed plan, "запиши в базу", or a handed-over document/URL: run the article-first Ingest workflow from `AGENTS.md`. Write articles in full detail — compression belongs only in `context.md`.

## Tools (Bash; scripts live next to this file)

- `~/.claude/skills/kb/kb-wiki search <terms…> [--all]` — ranked search; prefer it over raw Grep for finding pages. Also `toc <project-dir>`, `lint [--fix]`, `mv <src> <dst>`, `serve [port]` — see `AGENTS.md`.
- `~/.claude/skills/kb/kb-convert <file-or-url> [name]` — compile a large document into `$VAULT/raw/<name>/`; `kb-convert distill <name>` builds `_map.md`; `kb-convert check` lists converters. Never load a large source whole into the conversation — work map-first and delegate article drafting from big sources to `Agent` subagents, per `AGENTS.md` → Sources. If `kb-convert` fails (no bash, no converter), read the document in ≤20-page batches via subagents that return summaries.
- `~/.claude/skills/kb/kb-sync status|push|pull|init <gcrypt-url> [gpg-key]` — sync the vault with its (optionally end-to-end-encrypted) remote. Only when asked; offer `push` after writing, and check `status` first — unrelated uncommitted changes must not be swept into one commit silently. The passphrase lives in gpg-agent, never here.

On Windows the scripts need Git Bash (`bash ~/.claude/skills/kb/kb-sync …`) and Python (`python ~/.claude/skills/kb/kb-wiki …`); if unavailable, say so and continue with Glob/Grep. Encrypted (`gcrypt::`) remotes are not supported on Windows.
