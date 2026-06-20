# kb-harness

Harness for a personal Obsidian-style knowledge-base vault, decoupled from the vault's
content. One install wires up two coding agents to talk to the same vault from any folder:

- **Claude Code** — the `/kb` skill (`.claude/skills/kb/`).
- **Pi** — the `/kb` command + `kb_search` tool (`pi/`).

Both read a single recorded vault path, so the two agents always point at the same vault.

## Install

```bash
./setup.sh /path/to/vault     # defaults to ~/.obsidian
```

This symlinks the Claude skills into `~/.claude/skills/`, records the vault path, and runs
`pi install ./pi` (if `pi` is on `PATH`). Re-run any time — it's idempotent.

## Use

**Claude Code** (any directory):

```bash
claude "/kb что у меня есть про X"          # query
claude "/kb осмотрись тут, это для проекта Y" # scan the CWD and propose an ingest plan
```

**Pi** (any directory): `/kb <request>` loads the vault rules and detects the mode
(query / scan / ingest); the `kb_search` tool finds pages from anywhere.

Override the vault for a single Pi session with `export KB_VAULT=/path/to/vault`.

## Layout

```
kb-harness/
├── setup.sh                       # installs both harnesses, records vault_path
├── .claude/skills/kb/
│   ├── SKILL.md                   # Claude Code /kb skill
│   └── vault_path                 # the recorded vault path (gitignored; read by both)
└── pi/
    ├── package.json
    └── kb-harness.mjs             # Pi extension: /kb command + kb_search tool
```

The harness carries no vault content — point it at a vault with `setup.sh`.
