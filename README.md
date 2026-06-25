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
- `kb_sync` — a tool to push/pull the vault to its (optionally encrypted) remote (see below).

The vault's own `AGENTS.md` is the source of truth for conventions — kbridge points the agent at
it rather than duplicating the rules.

## Emacs setup

`emacs/kb.el` requires:

- **Emacs 28+** (uses `json-serialize`/`json-parse-string`; developed on 30).
- **`pi` on `PATH`** — for GUI Emacs on macOS, [`exec-path-from-shell`](https://github.com/purcell/exec-path-from-shell) imports it.
- kbridge installed (`./setup.sh`), so `~/.claude/skills/kb/vault_path` exists.
- a Pi provider/model configured — point Pi at a **local model** for a fully private KB.

Minimal (vanilla):

```elisp
(add-to-list 'load-path "/path/to/kbridge/emacs")
(require 'kb)
(setq kb-pi-model '("--model" "qwen/qwen3.6-27b"))   ; your local model; omit for Pi's default
```

With `use-package` + `straight.el` (deferred — loads on first use):

```elisp
(use-package kb
  :straight nil
  :load-path "/path/to/kbridge/emacs"
  :commands (kb-chat kb-ingest-region kb-sync)
  :bind (("C-c n a" . kb-chat)
         ("C-c n i" . kb-ingest-region)
         ("C-c n y" . kb-sync))
  :init (setq kb-pi-model '("--model" "qwen/qwen3.6-27b")))
```

**Window placement.** The chat opens in a normal, splittable window by default. Route it wherever
you like with `display-buffer-alist` (or set `kb-chat-display-action`) — e.g. a right side window:

```elisp
(add-to-list 'display-buffer-alist
             '("\\*kb-chat\\*"
               (display-buffer-in-side-window) (side . right) (window-width . 0.5)))
```

The process lifecycle is automatic: the persistent `pi --mode rpc` starts on first use, survives
across turns (keeping conversation memory), and is killed when you close the `*kb-chat*` buffer or
quit Emacs — no orphaned processes. Browsing/editing stay with `obsidian.el`/`markdown-mode`; the
vault path is shared via `vault_path`, so Emacs, Pi and Claude operate on the same vault.

**Emacs** — `emacs/kb.el` adds an *agent* layer on top of your editor (browsing, reading,
editing and `[[wikilinks]]` are already handled far better by `obsidian.el`/`markdown-mode`). It
opens a **streaming, multi-turn chat** with the vault, backed by a persistent `pi --mode rpc`
process — so you can run a **local model for privacy**, the conversation keeps its memory across
turns, tokens stream in live, and the single-threaded Emacs UI never blocks. See
[Emacs setup](#emacs-setup) to install it.

- `C-c n a` `kb-chat` — open the chat (a normal, splittable window by default). Type a message,
  `RET` sends, `C-j` inserts a newline, `C-c C-k` aborts the current turn (the session stays
  alive). Answers stream live with a header-line spinner; tool calls (e.g. `kb_search`) show
  inline; `[[wikilinks]]` in answers are clickable and open the page.
- `C-c n i` `kb-ingest-region` — hand the region to the chat agent to file into the vault.
- `C-c n y` `kb-sync` — push / pull / status via the same `kb-sync` script.

The vault path comes from the same recorded `vault_path`, so Emacs, Pi and Claude stay in sync.

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

Both harnesses expose this: a `kb_sync` tool and `/kb-sync` command in Pi, and the same
`~/.claude/skills/kb/kb-sync` script driven from the Claude `/kb` skill.

**Who holds the password:** nobody in kbridge. The passphrase/key lives in gpg-agent and, on macOS,
the Keychain (via `pinentry-mac`) — the harness only runs `git push/pull`.

**Threat model:** this protects the *remote* (the cloud sees only ciphertext). Local device loss is
covered by full-disk encryption (FileVault), not by this layer. The working copy is necessarily
plaintext while you work on it.

## Configuration

The vault location is resolved in this order:

1. `$KB_VAULT` environment variable (override for a single session),
2. the `vault_path` recorded by `setup.sh` (shared by both harnesses),
3. the globally-installed Claude skill's `vault_path`.

The sync remote is resolved the same way: `$KB_SYNC_REMOTE`, else the `sync_remote` file that
`kb-sync init` records next to `vault_path`. A `gcrypt::` URL means encrypted; absent means plain
local-only.

## Layout

```
kbridge/
├── setup.sh                       # installs both harnesses, records vault_path
├── .claude/skills/kb/
│   ├── SKILL.md                   # Claude Code /kb skill
│   ├── kb-sync                    # shared sync script (plain / gcrypt-encrypted remote)
│   ├── vault_path                 # recorded vault path (gitignored; read by both)
│   └── sync_remote                # recorded remote URL (gitignored; read by both)
├── pi/
│   ├── package.json
│   └── kb-harness.mjs             # Pi ext: /kb /kb-sync commands + kb_search/kb_sync tools
└── emacs/
    └── kb.el                      # Emacs: streaming RPC chat (kb-chat / kb-ingest / kb-sync)
```

## License

Apache-2.0
