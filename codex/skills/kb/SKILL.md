---
name: kb
description: Work with the personal knowledge base (a markdown wiki vault) from any directory — answer questions from it, survey the current folder for material that belongs in it, or ingest a document, URL or set of notes into it. Use when the user says "база знаний", "в базу", "/kb", or asks what they already know about something.
---

# Knowledge base

The vault is a markdown wiki under one recorded root. This skill only gets you there;
**the vault's own `AGENTS.md` is the authority** on structure, article format, links and
workflows.

## Step 0 — the vault path

Read `~/.claude/skills/kb/vault_path` — one line, an absolute path; it is `$VAULT` for the
rest of this task. If the file is missing, say so and stop: the harness is not installed,
and guessing a vault is how two vaults happen.

## Step 1 — the vault's own rules

Read `$VAULT/AGENTS.md` and `$VAULT/index.md` and follow them over anything here. Never
change directory; use absolute paths under `$VAULT/`. `$VAULT/chats/` is **excluded**
unless the user asks or `~/.claude/skills/kb/index_chats` exists.

## Step 2 — one of three modes

- **Query** — a question about vault content: the Query workflow from `AGENTS.md`. Write
  nothing unless asked.
- **Survey** — "осмотрись", "что здесь полезного для проекта X": look over the current
  directory and the target project's `index.md`/`context.md`, then **present a plan and
  stop** (what goes to `raw/`, which articles are extended or created, which links are
  added). Write only after the user confirms.
- **Ingest** — a confirmed plan, "запиши в базу", a handed-over document or URL: the
  article-first Ingest workflow from `AGENTS.md`, in full detail.

## Tools

```sh
~/.claude/skills/kb/kb-wiki search <terms…> [--all]   # ranked search — use it to find pages
~/.claude/skills/kb/kb-wiki toc <project-dir> | lint [--fix] | mv <src> <dst> | serve
~/.claude/skills/kb/kb-convert <file-or-url> [name]   # large document -> $VAULT/raw/<name>/
~/.claude/skills/kb/kb-convert distill <name>         # build raw/<name>/_map.md
~/.claude/skills/kb/kb-sync status|push|pull          # optional sync; offer push after writing
```

Never read a large document into the conversation — compile it and work map-first. If
`distill` fails, read the sections one at a time, summarising each into `_map.md` and
dropping it from your working set. Before `kb-sync push`, check `status`: unrelated
uncommitted changes must not be swept into one commit without saying so.
