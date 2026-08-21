---
name: kb
description: Work with the personal knowledge base (an Obsidian-style markdown vault) from any directory — answer questions from it, survey the current folder for material that belongs in it, or ingest a document, URL or set of notes into it. Load this when the user says "база знаний", "в базу", "/kb", or asks what they already know about something.
---

# Knowledge base

The vault is a markdown tree, not a service. Everything here is ordinary file work
under one recorded root.

## Step 0 — the vault path

Read `~/.claude/skills/kb/vault_path` — one line, an absolute path. That file is the
harness's single record of where the vault is, shared by every tool wired to it; the
path in it is `$VAULT` for the rest of this task. If the file is missing, say so and
stop: the harness is not installed, and guessing a vault is how two vaults happen.

## Step 1 — the vault's own rules

Read `$VAULT/AGENTS.md` (structure, conventions, ingest/query workflows) and
`$VAULT/index.md` (the project map). They are authoritative — follow them over
anything here. Never change directory; use absolute paths under `$VAULT/`.

`$VAULT/chats/` is raw saved transcripts and is **excluded**: never search or read it
unless the user asks.

## Step 2 — one of three modes

**Query** — "что у меня есть про…", "что я знаю о…", a question about vault content.
Search by filename and content, answer with `[[page]]` citations. Write nothing
unless asked.

**Survey** — "осмотрись", "что здесь полезного для проекта X". Look over the current
directory, read `index.md` and the target project's `context.md`, then **present a
plan and stop**: which sources map to which vault paths, which pages are new, which
existing pages gain links, what goes in `index.md` and `log.md`. Write only after the
user confirms.

**Ingest** — a confirmed plan, "запиши в базу", or a handed-over document or URL.
Execute the vault's ingest workflow: every new page gets YAML front matter (`title`,
`tags`, `created: YYYY-MM-DD`); cross-reference with `[[wikilinks]]`; append a
`## [YYYY-MM-DD] ingest | <source>` line to `$VAULT/log.md`; touch `index.md` only if
this created a new **project**.

## Large sources — compile, don't read

Never read a large document into the conversation: it floods the context and degrades
every later answer. Compile it once, then query the pieces.

```sh
~/.claude/skills/kb/kb-convert <file-or-url> [name]   # -> $VAULT/raw/<name>/NNN-*.md
~/.claude/skills/kb/kb-convert check                  # which converters exist here
~/.claude/skills/kb/kb-convert distill <name>         # build raw/<name>/_map.md
```

Every compiled source needs `raw/<name>/_map.md` — two to four sentences per section,
with key terms in the source language and English. Build it with `distill`, or spawn
one subagent per section (`spawn_agent`, mode `research`) that reads exactly one
section and reports a summary — the main conversation sees only the summaries.

To answer from a compiled source: `_map.md` first to pick candidate sections, then
grep across `raw/<name>/` with two or three rephrasings, then read only the sections
that matched. A small source — one file under ~32 KB — may simply be read whole.

## Rules

- `raw/` is immutable; `_map.md` is the one file in it you may create or rebuild.
- One topic per page. Consolidate rather than accrete: a `context.md` that has become
  a pile of dated sections should be rewritten to read as truth-now — the vault is a
  git repo, so nothing is lost.
- Update `index.md` only when a project is added, renamed or archived. It is a project
  map, not a page catalogue.
- Prefer being a thinking partner over being a scribe. Exploratory talk is not a
  reason to write a file; a decision, a fact that will not be reconstructible later,
  or an explicit request is.
- After writing, offer `~/.claude/skills/kb/kb-sync push`. Check
  `kb-sync status` first — a vault with unrelated uncommitted changes should not be
  swept into one commit without saying so.
