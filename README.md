# kbridge

A bridge between the tools you work in and your personal knowledge base. One install lets
**Claude Code**, **Pi** and **Emacs** talk to the same Obsidian-style markdown vault — query it,
scan the current folder for material that belongs in it, or ingest a source — from *any*
directory, without `cd`-ing into the vault.

The harness is decoupled from the vault: it carries no notes of its own, just the wiring. Point
it at any vault with `setup.sh`.

## Why

A personal knowledge base is only useful if it's frictionless to reach. kbridge makes the vault a
first-class target for the tools you already work in:

- **Claude Code** — a `/kb` skill.
- **Pi** — a `/kb` command plus `kb_search` / `kb_sync` tools the model can call directly.
- **Emacs** — a streaming, multi-turn **chat with the vault** (`kb.el`), backed by a persistent
  Pi process — point it at a local model for a fully private KB. See [Emacs](#emacs).

All three resolve the **same recorded vault path**, so they never drift apart.

## Install

```bash
git clone git@github.com:bes-dev/kbridge.git
cd kbridge
./setup.sh /path/to/vault          # defaults to ~/.obsidian
```

`setup.sh` is idempotent. It:

1. symlinks the Claude Code skills into `~/.claude/skills/`,
2. records the vault path (read by all three integrations),
3. installs the Pi extension globally via `pi install ./pi` (if `pi` is on `PATH`).

For the Emacs layer, see [Emacs](#emacs) — it needs only a `load-path` entry on top of this.

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
  - **ingest** — write pages, update `index.md`, append to `log.md`, cross-reference.
- `kb_search` — a tool the model can call to find pages by content or filename, scoped to the
  vault, from anywhere.
- `kb_sync` — a tool to push/pull the vault to its (optionally encrypted) remote (see below).
- `/kb-index-chats` — toggle whether `chats/` (saved transcripts) is included in search; **off by default** (see [Saved chats](#saved-chats)).

**Emacs** — `C-c k k` opens the chat; select a region and `C-c k i` files it into the vault;
`C-c k b` / `C-c k d` attach the current buffer or directory as context. Full tour below.

The vault's own `AGENTS.md` is the source of truth for conventions — kbridge points the agent at
it rather than duplicating the rules.

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
   mirrors the script), so it works in Claude Code, Pi and the Emacs chat alike.

Any format works — PDF, DOCX, PPTX, HTML, URLs, plain text; only the conversion step knows the
difference. And since the compiled source is just markdown in the vault, you can **compile once
with your strongest agent** (e.g. Claude Code, with parallel subagents) **and query from
anywhere** — including a fully-local model in Pi/Emacs.

## Emacs

`emacs/kb.el` adds an *agent* layer on top of your editor. Browsing, reading, editing and
`[[wikilinks]]` are already handled far better by `obsidian.el`/`markdown-mode` — this module
adds what they can't: a **streaming, multi-turn chat** with the vault, backed by a persistent
`pi --mode rpc` process. That buys you:

- **privacy** — run a local model; the vault never leaves your machine,
- **memory** — the session survives across turns, so the conversation has context,
- **liveness** — tokens stream in as they're generated; the single-threaded Emacs UI never
  blocks while the model thinks.

### Setup

Requirements:

- **Emacs 28+** (uses `json-serialize`/`json-parse-string`; developed on 30).
- **`pi` on `PATH`** — for GUI Emacs on macOS, [`exec-path-from-shell`](https://github.com/purcell/exec-path-from-shell) imports it.
- kbridge installed (`./setup.sh`), so `~/.claude/skills/kb/vault_path` exists.
- a Pi provider/model configured — point Pi at a **local model** for a fully private KB.

Minimal (vanilla). `kb.el` ships commands only — bind them under a free prefix (`C-c k` keeps
clear of `obsidian.el`'s `C-c n` map):

```elisp
(add-to-list 'load-path "/path/to/kbridge/emacs")
(require 'kb)
(setq kb-pi-model '("--model" "qwen/qwen3.6-27b"))   ; your local model; omit for Pi's default
(global-set-key (kbd "C-c k k") #'kb-chat)
(global-set-key (kbd "C-c k i") #'kb-ingest-region)
(global-set-key (kbd "C-c k b") #'kb-discuss-buffer)
(global-set-key (kbd "C-c k d") #'kb-discuss-directory)
(global-set-key (kbd "C-c k s") #'kb-sync)
```

With `use-package` + `straight.el` (deferred — loads on first use):

```elisp
(use-package kb
  :straight nil
  :load-path "/path/to/kbridge/emacs"
  :commands (kb-open-page)
  :bind (("C-c k k" . kb-chat)              ; open the chat (alias: M-x kb-ask)
         ("C-c k i" . kb-ingest-region)     ; file the region into the vault
         ("C-c k b" . kb-discuss-buffer)    ; attach this buffer/region (read-only)
         ("C-c k d" . kb-discuss-directory) ; attach this dir (works in dired)
         ("C-c k s" . kb-sync))             ; push / pull / status
  :init (setq kb-pi-model '("--model" "qwen/qwen3.6-27b")))
```

### Commands

- `C-c k k` `kb-chat` — open the chat (a normal, splittable window by default). Type a message,
  `RET` sends, `C-j` inserts a newline, `C-c C-k` aborts the current turn (the session stays
  alive). Answers stream in live, get lightweight markdown rendering (headings, bold, italics,
  inline code, bullets), and `[[wikilinks]]` are clickable — they open the vault page.
- `C-c k b` `kb-discuss-buffer` — attach the current buffer (or active region) to the chat as
  **read-only** context. The chat shows `🔒 read-only`; press `C-c C-e` to flip to `✎ edit` —
  the source file gets `auto-revert` and the agent may edit it in place (your next message
  carries the grant). `C-c C-e` again returns to read-only.
- `C-c k d` `kb-discuss-directory` — attach the current directory (a dired folder, else
  `default-directory`) plus a one-level listing, so the agent works in it by absolute path.
- `C-c k i` `kb-ingest-region` — hand the region to the chat agent to file into the vault.
- `C-c k s` `kb-sync` — push / pull / status via the same `kb-sync` script, asynchronously.

### Inside the chat

- `C-c C-m` — **switch the Pi model live**, mid-conversation, no process restart: pick from
  Pi's available models with completion.
- The **mode line** shows the active model and its context budget (e.g. `Qwen 3.6 27B
  (12K/131K)`), a spinner while a turn streams, and the tool currently running (`kb_search`,
  `read`, …) — tool activity stays out of the transcript.
- The **header line** is a legend of the active keys, including `chats:on/off` — `C-c C-i`
  toggles whether `chats/` is searched (the flag is shared with Pi and Claude).
- `C-x C-s` — save the transcript into the vault's `chats/`, suggesting a `<date>-<slug>.md`
  name derived from your first message; after the first save the buffer visits that file, so
  further saves just update it.

Attached context shows as a `📎` line and rides your **next** message, so the transcript shows
only your question.

### Placement, lifecycle, vault resolution

The chat opens in a normal, splittable window by default. Route it wherever you like with
`display-buffer-alist` (or set `kb-chat-display-action`) — e.g. a right side window:

```elisp
(add-to-list 'display-buffer-alist
             '("\\*kb-chat\\*"
               (display-buffer-in-side-window) (side . right) (window-width . 0.5)))
```

The process lifecycle is automatic: the persistent `pi --mode rpc` starts on first use, survives
across turns (keeping conversation memory), and is killed when you close the `*kb-chat*` buffer
or quit Emacs — no orphaned processes.

The vault is resolved like everywhere else in kbridge — `kb-vault-directory` if you set it, else
the recorded `vault_path`, else `obsidian.el`'s `obsidian-directory` as a last resort — so
Emacs, Pi and Claude always operate on the same vault. Browsing/editing stay with
`obsidian.el`/`markdown-mode`.

## Saved chats

Chats are ephemeral by default — the value is what you *distill* into the vault, not the raw
transcript. But you can keep a session when you want: in the Emacs chat, `C-x C-s` writes the
buffer to `<vault>/chats/` (created on first save), suggesting a `<date>-<slug>.md` name derived
from your first message.

`chats/` is a **manual drop-spot, not a managed layer** — and it's **excluded from search by
default** so old chatter doesn't dilute retrieval. Toggle it into the index when you want to recall
from past chats, via a shared flag (`~/.claude/skills/kb/index_chats`) that all three agents read:

- **Pi** — `/kb-index-chats`
- **Emacs** — `C-c C-i` in the chat (header shows `chats:on/off`)
- **Claude** — ask `/kb` to include/exclude chats

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

All three integrations expose this: a `kb_sync` tool and `/kb-sync` command in Pi, `C-c k s`
(`kb-sync`) in Emacs, and the same `~/.claude/skills/kb/kb-sync` script driven from the Claude
`/kb` skill.

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

In Emacs the same chain applies via `kb-vault-path-file`, overridable with `kb-vault-directory`
(and falling back to `obsidian-directory` if you use `obsidian.el`).

The sync remote is resolved the same way: `$KB_SYNC_REMOTE`, else the `sync_remote` file that
`kb-sync init` records next to `vault_path`. A `gcrypt::` URL means encrypted; absent means plain
local-only.

## Layout

```
kbridge/
├── setup.sh                       # installs the harnesses, records vault_path
├── setup.ps1                      # Windows: copies the Claude skill per-user, no admin
├── .claude/skills/kb/
│   ├── SKILL.md                   # Claude Code /kb skill
│   ├── kb-convert                 # any document/URL → greppable raw/ sections + _map.md
│   ├── kb-sync                    # shared sync script (plain / gcrypt-encrypted remote)
│   ├── vault_path                 # recorded vault path (gitignored; read by all)
│   ├── sync_remote                # recorded remote URL (gitignored; read by all)
│   └── index_chats                # flag: include chats/ in search (gitignored; toggle)
├── pi/
│   ├── package.json
│   └── kb-harness.mjs             # Pi ext: /kb /kb-sync commands + kb_search/kb_sync tools
└── emacs/
    └── kb.el                      # Emacs: streaming chat, live model switch, context attach
```

## License

Apache-2.0
