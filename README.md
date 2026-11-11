# kbridge

A bridge between the tools you work in and your personal knowledge base. One install lets
**Claude Code**, **Pi**, **Codex**, **elmee** and **Emacs** talk to the same markdown vault — query it,
scan the current folder for material that belongs in it, or ingest a source — from *any*
directory, without `cd`-ing into the vault.

The vault is run as a **wiki**: each project is a set of detailed, categorised, cross-linked
articles with a generated contents page — browsable locally like wiki.js or MkDocs (navigation,
ranked search, backlinks, tags) via `kb-wiki serve`, with no Node or other dependencies. See [Wiki](#wiki).

The harness is decoupled from the vault: it carries no notes of its own, just the wiring. Point
it at any vault with `setup.sh`.

## Why

A personal knowledge base is only useful if it's frictionless to reach. kbridge makes the vault a
first-class target for the tools you already work in:

- **Claude Code** — a `/kb` skill.
- **Pi** — a `/kb` command plus `kb_search` / `kb_sync` tools the model can call directly.
- **Codex** — a user-scope `kb` skill (`~/.codex/skills/kb`), same format as the Claude one;
  Codex loads it when the vault comes up, or say "use the kb skill".
- **elmee** — the same `kb` skill, linked into `~/.agents/skills/`: the agent picks it up when
  the vault comes up, and `/kb …` invokes it.
- **Emacs** — through [genie.el](https://github.com/bes-dev/genie.el), an elmee chat in the
  editor: `/kb …` in any chat, with a region or file attached. See [Emacs](#emacs).

They all resolve the **same recorded vault path**, so they never drift apart.

## Install

```bash
git clone git@github.com:bes-dev/kbridge.git
cd kbridge
./setup.sh /path/to/vault          # defaults to ~/.obsidian
```

`setup.sh` is idempotent. It:

1. symlinks the Claude Code skills into `~/.claude/skills/`,
2. records the vault path (read by every integration),
3. installs the Pi extension globally via `pi install ./pi` (if `pi` is on `PATH`),
4. symlinks the Codex skill into `~/.codex/skills/` (if `~/.codex` exists).

For Emacs, see [Emacs](#emacs) — the skill is all it needs.

### Windows (Claude desktop app / Claude Code)

No admin rights needed. From the cloned repo, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1 -VaultPath C:\path\to\vault
```

`setup.ps1` **copies** the `/kb` skill into `%USERPROFILE%\.claude\skills\` (symlinks need
admin/Developer Mode on Windows) and records the vault path there. Re-run it after a `git pull`
to refresh; your local state (`vault_path`, `sync_remote`, `index_chats`) survives re-runs.

That's the whole setup: `/kb` then works in Claude Code — the CLI and the Claude desktop app
share the same `~\.claude\skills\` — using Claude's built-in cross-platform tools. Note the
skill is a *Claude Code* skill; the plain chat side of the desktop app doesn't load skills.

Optional extras on Windows:

- **Sync & source compilation** — install [Git for Windows](https://gitforwindows.org/) (has a
  per-user, no-admin installer). Claude Code then uses Git Bash for its Bash tool, so `kb-sync`
  (plain git remote) and `kb-convert` work; add a converter (`pip install --user markitdown` or
  `docling`) for best results. Without Git Bash the `/kb` skill still ingests documents — it
  falls back to reading them in batches via subagents. Encrypted `gcrypt::` remotes are **not
  supported** on Windows.
- **Pi / Emacs** — not covered by `setup.ps1`; the Pi extension currently shells out to
  Unix `grep`/`find` and is not Windows-ready.

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
  - **ingest** — merge the material into the project's articles in full detail, cross-link,
    regenerate the contents, append to `log.md`.
- `kb_search` — ranked search the model can call from anywhere (via `kb-wiki search`).
- `kb_sync` — a tool to push/pull the vault to its (optionally encrypted) remote (see below).
- `/kb-index-chats` — toggle whether `chats/` (saved transcripts) is included in search; **off by default** (see [Saved chats](#saved-chats)).

**Codex** — from any directory: mention the vault ("что у меня в базе про X") and Codex loads
the `kb` skill on its own, or say "use the kb skill". Same three modes; the vault's `AGENTS.md`
stays authoritative.

**elmee** — `elmee "/kb что у меня есть про X"`, or `/kb …` in its TUI; same three modes.

**Emacs** — `/kb …` in a genie chat; select a region first and it goes along. See below.

The vault's own `AGENTS.md` is the source of truth for conventions — kbridge points the agent at
it rather than duplicating the rules.

## Wiki

Each project under `projects/<name>/` is a wiki:

```
projects/<name>/
├── index.md              # home: overview + contents generated from front matter
├── context.md            # truth-now: state, decisions, open questions (the only compressed page)
├── <category>/<slug>.md  # articles — one topic each, full detail, See also + Sources
└── notes/                # evidence journal: one dated finding per file
```

Ingest is **article-first**: new material is merged into the article it belongs to rather than
summarised into a new page. The rules live in the vault's `AGENTS.md`; the deterministic half is
one script shared by every integration, `~/.claude/skills/kb/kb-wiki`:

| Command | Does |
|---|---|
| `kb-wiki search <terms…> [--all]` | ranked search: title/aliases/tags > description > body; pages and `raw/` sources listed apart |
| `kb-wiki toc <project-dir>` | regenerate the contents block of the project's `index.md`, grouped by `category` |
| `kb-wiki lint [--fix]` | broken/ambiguous links, missing front matter, orphans; `--fix` repairs links it can resolve uniquely |
| `kb-wiki mv <src> <dst>` | `git mv` a page or folder and rewrite every link to it (archiving no longer breaks links) |
| `kb-wiki serve [port]` | browse the vault at `http://127.0.0.1:8080` — live, no build step |

Links follow one rule, shared by `lint` and the renderer: `[[target]]` is a path from the vault
root or a page name unique in the vault.

`serve` is a Python-stdlib HTTP server (localhost only) plus one self-contained page,
`wiki.html` — plain JS, no dependencies, its own Markdown renderer. It mirrors the agents'
view exactly: search calls the same ranking as `kb-wiki search`, links resolve by the same rule
as `lint`, navigation and per-project sections come from front matter (`category`), each page
shows its contents and backlinks, tags are clickable. Files are read on every request, so an
edit is visible on the next page load; light/dark follows the system.

## Sources — compile once, chat fast

Dropping a huge PDF straight into a chat makes any agent slow and dumb: the raw pages flood the
context window, and every later answer degrades. kbridge instead **compiles** a source once —
NotebookLM-style, but in plain markdown — and then every question is cheap:

1. **Convert + split** — `kb-convert <file-or-url> [name]` converts with the best
   locally-available tool (docling / markitdown / pandoc / pdftotext, each optional —
   `kb-convert check` shows what you have) and splits by structure into
   `<vault>/raw/<name>/NNN-<section>.md`, keeping the untouched `original.*` alongside.
   *Files are the chunks, the filesystem is the index* — no vector store, plain grep.
2. **Distill a map** — `kb-convert distill <name>` writes `raw/<name>/_map.md`: per-section
   summaries produced by one-shot LLM calls in **clean contexts** (default `pi --print`, override
   with `$KB_DISTILL_CMD`). Agents with subagents (Claude Code) can build the map themselves
   in parallel instead.
3. **Chat** — agents follow a map-first contract: read `_map.md`, grep the sections, read only
   what matched. The contract ships in the `/kb` skill and the Pi kickoff (a `kb_convert` tool
   mirrors the script), so it works in Claude Code, Pi, elmee and Emacs alike.

Any format works — PDF, DOCX, PPTX, HTML, URLs, plain text; only the conversion step knows the
difference. And since the compiled source is just markdown in the vault, you can **compile once
with your strongest agent** (e.g. Claude Code, with parallel subagents) **and query from
anywhere** — including a fully-local model in Pi or elmee.

## Emacs

There is no kbridge plugin for Emacs: the vault is reached through
[genie.el](https://github.com/bes-dev/genie.el), which puts the elmee agent in the editor, and
the `kb` skill is everything kbridge adds to it.

- `M-x genie-ask` opens the chat for where you are; type `/kb что у меня про X`. `TAB` completes
  the skill's name.
- Select a region first and it is attached to the message — `/kb запиши это в базу` files it.
  `C-u M-x genie-ask` attaches the whole file, or in Dired the directory, for "осмотрись тут".
- `[[wikilinks]]` in an answer open the page once the vault is named:
  `(setq genie-chat-wiki-roots '("~/path/to/vault"))`.
- The model is switched with `C-c C-m`; the header line shows it and how full its context is.
  Point elmee at a local model for a fully private KB.
- Conversations are kept by elmee per directory and listed with `C-c C-s`, so a chat opened in
  the vault itself is the vault's own history.
- `/kb sync push` (or `pull`, `status`) runs the sync script.

Browsing, reading and editing stay with `obsidian.el`/`markdown-mode`.

## Saved chats

Chats are ephemeral by default — the value is what you *distill* into the vault, not the raw
transcript. To keep one, save it into `<vault>/chats/` as a `<date>-<slug>.md` file, or ask the
agent to write the conversation there.

`chats/` is a **manual drop-spot, not a managed layer** — and it's **excluded from search by
default** so old chatter doesn't dilute retrieval. Toggle it into the index when you want to recall
from past chats, via a shared flag (`~/.claude/skills/kb/index_chats`) that all three agents read:

- **Pi** — `/kb-index-chats`
- **Claude, Codex, elmee, Emacs** — ask `/kb` to include/exclude chats

## Encrypted sync (optional)

By default the vault is plain markdown on local disk — convenient locally, but risky if you sync
it to Dropbox/gdrive in the clear. kbridge can instead back the vault with an **end-to-end-encrypted
remote** via [`git-remote-gcrypt`](https://github.com/spwhitton/git-remote-gcrypt): the local copy
stays plaintext (so the agents keep reading/grepping it natively), and only what is pushed to the
remote is ciphertext — filenames and history included.

Export an existing vault to an encrypted remote (one-time):

```bash
# requires: brew install git-remote-gcrypt gnupg
kb-sync init gcrypt::<remote-url> [gpg-key-id]   # omit the key id for a symmetric passphrase
```

`<remote-url>` is any git/rsync/sftp target — e.g. a folder your native Dropbox/gdrive client
already syncs (`gcrypt::/Users/me/Dropbox/kb.git`). Then keep it in sync:

```bash
kb-sync push      # commit local changes and upload
kb-sync pull      # download remote changes
kb-sync status    # show mode (plain / encrypted) and remote
```

Every integration exposes this: a `kb_sync` tool and `/kb-sync` command in Pi, and the same
`~/.claude/skills/kb/kb-sync` script driven from the `/kb` skill everywhere else.

**Who holds the password:** nobody in kbridge. The passphrase/key lives in gpg-agent and, on macOS,
the Keychain (via `pinentry-mac`) — the harness only runs `git push/pull`.

**Threat model:** this protects the *remote* (the cloud sees only ciphertext). Local device loss is
covered by full-disk encryption (FileVault), not by this layer. The working copy is necessarily
plaintext while you work on it.

## Configuration

The vault location is resolved in this order:

1. `$KB_VAULT` environment variable (override for a single session),
2. the `vault_path` recorded by `setup.sh` (shared by all integrations),
3. the globally-installed Claude skill's `vault_path`.

The sync remote is resolved the same way: `$KB_SYNC_REMOTE`, else the `sync_remote` file that
`kb-sync init` records next to `vault_path`. A `gcrypt::` URL means encrypted; absent means plain
local-only.

## Layout

```
kbridge/
├── setup.sh                       # installs the harnesses, records vault_path
├── setup.ps1                      # Windows: copies the Claude skill per-user, no admin
├── .claude/skills/kb/
│   ├── SKILL.md                   # the /kb skill (Claude Code; elmee and Emacs via ~/.agents)
│   ├── kb-convert                 # any document/URL → greppable raw/ sections + _map.md
│   ├── kb-sync                    # shared sync script (plain / gcrypt-encrypted remote)
│   ├── kb-wiki                    # wiki tooling: search, toc, lint, mv, serve
│   ├── wiki.html                  # the viewer kb-wiki serve hosts (plain JS, no deps)
│   ├── vault_path                 # recorded vault path (gitignored; read by all)
│   ├── sync_remote                # recorded remote URL (gitignored; read by all)
│   └── index_chats                # flag: include chats/ in search (gitignored; toggle)
├── codex/
│   └── skills/kb/SKILL.md         # Codex user-scope skill (~/.codex/skills/kb)
└── pi/
    ├── package.json
    └── kb-harness.mjs             # Pi ext: /kb /kb-sync commands + kb_search/kb_sync tools
```

## License

Apache-2.0
