# kbridge

A bridge between coding agents and your personal knowledge base. One install lets both
**Claude Code** and **Pi** talk to the same Obsidian-style markdown vault — query it, scan the
current folder for material that belongs in it, or ingest a source — from *any* directory,
without `cd`-ing into the vault.

The harness is decoupled from the vault: it carries no notes of its own, just the wiring. Point
it at any vault with `setup.sh`.

## Why

A personal knowledge base is only useful if it's frictionless to reach. kbridge makes the vault a
first-class target for the agents you already work in:

- **Claude Code** — a `/kb` skill.
- **Pi** — a `/kb` command plus a `kb_search` tool the model can call directly.

Both resolve the **same recorded vault path**, so the two agents never drift apart.

## Install

```bash
git clone git@github.com:bes-dev/kbridge.git
cd kbridge
./setup.sh /path/to/vault          # defaults to ~/.obsidian
```

`setup.sh` is idempotent. It:

1. symlinks the Claude Code skills into `~/.claude/skills/`,
2. records the vault path (read by both harnesses),
3. installs the Pi extension globally via `pi install ./pi` (if `pi` is on `PATH`).

## Use

**Claude Code** — from any directory:

```bash
claude "/kb что у меня есть про X"             # query the vault
claude "/kb осмотрись тут, это для проекта Y"  # scan the CWD, propose an ingest plan
```

**Pi** — from any directory:

- `/kb <request>` loads the vault rules and detects the mode automatically:
  - **query** — search and answer with `[[wikilink]]` citations (read-only),
  - **scan** — survey the current folder and propose an ingest plan (waits for confirmation),
  - **ingest** — write pages, update `index.md`, append to `log.md`, cross-reference.
- `kb_search` — a tool the model can call to find pages by content or filename, scoped to the
  vault, from anywhere.

The vault's own `CLAUDE.md` is the source of truth for conventions — kbridge points the agent at
it rather than duplicating the rules.

## Configuration

The vault location is resolved in this order:

1. `$KB_VAULT` environment variable (override for a single session),
2. the `vault_path` recorded by `setup.sh` (shared by both harnesses),
3. the globally-installed Claude skill's `vault_path`.

## Layout

```
kbridge/
├── setup.sh                       # installs both harnesses, records vault_path
├── .claude/skills/kb/
│   ├── SKILL.md                   # Claude Code /kb skill
│   └── vault_path                 # recorded vault path (gitignored; read by both)
└── pi/
    ├── package.json
    └── kb-harness.mjs             # Pi extension: /kb command + kb_search tool
```

## License

Apache-2.0
