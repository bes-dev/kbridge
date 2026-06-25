/**
 * KB harness for Pi — talk to the personal knowledge-base vault from any folder.
 *
 * Mirrors the Claude Code `/kb` skill: the agent operates on the vault with its native
 * file tools using ABSOLUTE paths under $VAULT (never cd), driven by the vault's own
 * AGENTS.md rules. This extension adds the two things the agent can't get for free:
 *   - `kb_search`  — find pages by content/filename anywhere, scoped to the vault;
 *   - `kb_sync`    — push/pull the vault to its (optionally gcrypt-encrypted) remote;
 *   - `/kb <req>`  — loads vault context and detects the mode (query / scan / ingest);
 *   - `/kb-sync`   — drive the kb-sync script (init / push / pull / status).
 *
 * Load:  pi install <kb-harness>/pi   (global)   ·   or: pi -e ./kb-harness.mjs
 * Vault: $KB_VAULT, else the vault_path recorded by setup.sh.
 */

import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HOME = os.homedir();

// Single source of truth for the vault location: env override, else the file setup.sh writes
// into the skill dir (shared with the Claude Code skill), else the globally-installed skill.
function resolveVault() {
	if (process.env.KB_VAULT && fs.existsSync(process.env.KB_VAULT)) return process.env.KB_VAULT;
	for (const f of [path.join(HERE, "..", ".claude/skills/kb/vault_path"), path.join(HOME, ".claude/skills/kb/vault_path")]) {
		try {
			const v = fs.readFileSync(f, "utf8").trim();
			if (v && fs.existsSync(v)) return v;
		} catch {}
	}
	return null;
}

// The encrypted-sync layer is shared with the Claude skill: a single `kb-sync` script and a
// `sync_remote` file living in the kb skill dir (same place as vault_path). Resolution mirrors
// resolveVault so both harnesses agree even when the Pi ext is installed globally.
const resolveSyncRemote = () => {
	if (process.env.KB_SYNC_REMOTE) return process.env.KB_SYNC_REMOTE;
	for (const f of [path.join(HERE, "..", ".claude/skills/kb/sync_remote"), path.join(HOME, ".claude/skills/kb/sync_remote")]) {
		try {
			const v = fs.readFileSync(f, "utf8").trim();
			if (v) return v;
		} catch {}
	}
	return null;
};

const resolveSyncBin = () => {
	const cands = process.env.KB_SYNC_BIN ? [process.env.KB_SYNC_BIN] : [];
	cands.push(path.join(HOME, ".claude/skills/kb/kb-sync"), path.join(HERE, "..", ".claude/skills/kb/kb-sync"));
	return cands.find((f) => fs.existsSync(f)) || null;
};

const text = (s) => ({ content: [{ type: "text", text: String(s).slice(0, 8000) || "(no output)" }], details: {} });

function run(cmd, args) {
	return new Promise((res) =>
		execFile(cmd, args, { timeout: 30000, maxBuffer: 8 * 1024 * 1024 }, (err, out) => res({ ok: !err || err.code === 1, out: out || "" })),
	);
}

// Sync can hit the network and writes to stderr on failure — capture both streams, longer timeout.
function runSync(args) {
	const bin = resolveSyncBin();
	if (!bin) return Promise.resolve("kb-sync not installed — run the harness setup.sh.");
	return new Promise((res) =>
		execFile(bin, args, { timeout: 180000, maxBuffer: 8 * 1024 * 1024 }, (err, out, errOut) =>
			res(((out || "") + (errOut || "")).trim() || (err ? String(err.message) : "(no output)")),
		),
	);
}

const listPages = (vault) => {
	try {
		return fs
			.readdirSync(vault, { recursive: true })
			.filter((f) => typeof f === "string" && f.endsWith(".md"))
			.map((f) => path.basename(f, ".md"));
	} catch {
		return [];
	}
};

const KICKOFF = (vault, req) => `You have access to the personal knowledge-base vault at \`${vault}\`. Operate on it from the current working directory using ABSOLUTE paths under that root — never cd. Use the \`kb_search\` tool to find pages from anywhere.

First read \`${vault}/AGENTS.md\` (vault rules) and \`${vault}/index.md\` (project map), then follow them strictly. Detect the mode from my request and act:
- QUERY (a question about the vault): search, then synthesize an answer with [[wikilink]] citations. Do NOT write unless I ask.
- SCAN ("осмотрись тут" / material in the CWD that belongs in the vault): survey the CWD, map files to vault pages, and output a PLAN only — wait for my confirmation before writing.
- INGEST (a source to record, or my confirmation of a plan): run the ingest workflow — new pages get YAML front matter, append a \`## [YYYY-MM-DD] ingest | <source>\` line to log.md (update index.md only for a new project — it's a project map), cross-reference with [[wikilinks]].

My request: ${req || "(none given — ask what I want, or default to QUERY mode)"}`;

export default function install(pi) {
	pi.registerTool({
		name: "kb_search",
		label: "kb_search",
		description: "Search the personal knowledge-base vault (markdown) by content and filename, from any working directory. Read-only.",
		parameters: {
			type: "object",
			properties: { query: { type: "string", description: "case-insensitive text to find in page bodies and filenames" } },
			required: ["query"],
		},
		executionMode: "parallel",
		execute: async (_id, p) => {
			const vault = resolveVault();
			if (!vault) return text("KB vault not configured — run the harness setup.sh (or set $KB_VAULT).");
			const q = p.query;
			const content = await run("grep", ["-rIn", "-i", "--include=*.md", "-e", q, vault]);
			const files = await run("find", [vault, "-name", "*.md", "-not", "-path", "*/.git/*"]);
			const named = files.out.split("\n").filter((f) => f && path.basename(f).toLowerCase().includes(q.toLowerCase()));
			const rel = (s) => s.split(vault + "/").join("");
			const body = content.out.split("\n").slice(0, 60).map(rel).join("\n");
			return text(`vault: ${vault}\n\n# filename matches\n${named.map(rel).join("\n") || "(none)"}\n\n# content matches (file:line)\n${body || "(none)"}`);
		},
	});

	pi.registerTool({
		name: "kb_sync",
		label: "kb_sync",
		description: "Sync the knowledge-base vault with its remote (optionally end-to-end encrypted via gcrypt): push commits local changes and uploads them, pull downloads remote changes, status reports the mode. The local vault stays plaintext; only the remote is encrypted. Offer to push after writing/ingesting.",
		parameters: {
			type: "object",
			properties: { command: { type: "string", enum: ["push", "pull", "status"], description: "push local changes, pull remote changes, or show sync status" } },
			required: ["command"],
		},
		execute: async (_id, p) => text(await runSync([p.command])),
	});

	pi.registerCommand("kb-sync", {
		description: "Sync the knowledge base with its remote. /kb-sync [push|pull|status|init <gcrypt-url> [gpg-key]]",
		handler: async (args) => {
			const parts = args.trim().split(/\s+/).filter(Boolean);
			const out = await runSync(parts.length ? parts : ["status"]);
			pi.sendUserMessage("```\n" + out.slice(0, 4000) + "\n```");
		},
	});

	pi.registerCommand("kb", {
		description: "Talk to the knowledge base: query it, scan the CWD for material, or ingest a source. /kb <request>",
		getArgumentCompletions: (prefix) => {
			const vault = resolveVault();
			if (!vault) return [];
			const last = prefix.split(/\s+/).pop() || "";
			if (last.length < 2) return [];
			return [...new Set(listPages(vault))]
				.filter((n) => n.toLowerCase().includes(last.toLowerCase()))
				.slice(0, 12)
				.map((n) => ({ value: n, label: n, description: "vault page" }));
		},
		handler: async (args) => {
			const vault = resolveVault();
			if (!vault) return void pi.sendUserMessage("KB vault not configured — run the harness setup.sh (or set $KB_VAULT).");
			pi.sendUserMessage(KICKOFF(vault, args.trim()));
		},
	});

	pi.on("session_start", async (_e, ctx) => {
		const vault = resolveVault();
		if (!vault) return void ctx.ui?.setStatus?.("kb", "KB vault not configured — run setup.sh");
		const enc = String(resolveSyncRemote() || "").startsWith("gcrypt::") ? " · 🔒 encrypted" : "";
		ctx.ui?.setStatus?.("kb", `KB ${path.basename(vault)} · ${listPages(vault).length} pages${enc} · /kb`);
	});
}
