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

const resolveSkillBin = (name, envVar) => {
	const cands = envVar && process.env[envVar] ? [process.env[envVar]] : [];
	cands.push(path.join(HOME, ".claude/skills/kb", name), path.join(HERE, "..", ".claude/skills/kb", name));
	return cands.find((f) => fs.existsSync(f)) || null;
};

// chats/ holds saved raw transcripts. It's EXCLUDED from kb_search by default
// (noise), included only when the shared `index_chats` flag file exists. Toggled
// via /kb-index-chats; read by all three harnesses (Pi, Claude skill, Emacs).
const indexChatsFile = () => path.join(HOME, ".claude/skills/kb/index_chats");
const chatsIndexed = () => {
	for (const f of [path.join(HERE, "..", ".claude/skills/kb/index_chats"), indexChatsFile()]) {
		try { if (fs.existsSync(f)) return true; } catch {}
	}
	return false;
};

const text = (s) => ({ content: [{ type: "text", text: String(s).slice(0, 8000) || "(no output)" }], details: {} });

function run(cmd, args) {
	return new Promise((res) =>
		execFile(cmd, args, { timeout: 30000, maxBuffer: 8 * 1024 * 1024 }, (err, out) => res({ ok: !err || err.code === 1, out: out || "" })),
	);
}

// Skill scripts can hit the network and write to stderr on failure — capture both streams.
function runScript(bin, args, timeout) {
	if (!bin) return Promise.resolve("script not installed — run the harness setup.sh.");
	return new Promise((res) =>
		execFile(bin, args, { timeout, maxBuffer: 8 * 1024 * 1024 }, (err, out, errOut) =>
			res(((out || "") + (errOut || "")).trim() || (err ? String(err.message) : "(no output)")),
		),
	);
}

const runSync = (args) => runScript(resolveSkillBin("kb-sync", "KB_SYNC_BIN"), args, 180000);
// Conversion + distillation of a big source can take minutes — generous timeout.
const runConvert = (args) => runScript(resolveSkillBin("kb-convert", "KB_CONVERT_BIN"), args, 600000);

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

First read \`${vault}/AGENTS.md\` (vault rules) and \`${vault}/index.md\` (project map), then follow them strictly. \`chats/\` holds saved raw transcripts and is excluded from search by default — ignore it unless I ask. Detect the mode from my request and act:
- QUERY (a question about the vault): search, then synthesize an answer with [[wikilink]] citations. Do NOT write unless I ask.
- SCAN ("осмотрись тут" / material in the CWD that belongs in the vault): survey the CWD, map files to vault pages, and output a PLAN only — wait for my confirmation before writing.
- INGEST (a source to record, or my confirmation of a plan): run the ingest workflow — new pages get YAML front matter, append a \`## [YYYY-MM-DD] ingest | <source>\` line to log.md (update index.md only for a new project — it's a project map), cross-reference with [[wikilinks]].

Large documents (PDF/DOCX/HTML/URL — anything you can't cheaply read whole): NEVER load them into this conversation. Compile once with the \`kb_convert\` tool (action "convert" → sections in \`raw/<name>/\`, then action "distill" → \`raw/<name>/_map.md\`), then work map-first: read \`_map.md\`, grep the section files, read ONLY the sections that matched. The same applies to already-compiled sources you find under \`raw/\`.

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
			const gargs = ["-rIn", "-i", "--include=*.md"];
			const fargs = [vault, "-name", "*.md", "-not", "-path", "*/.git/*"];
			if (!chatsIndexed()) { gargs.push("--exclude-dir=chats"); fargs.push("-not", "-path", "*/chats/*"); }
			const content = await run("grep", [...gargs, "-e", q, vault]);
			const files = await run("find", fargs);
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

	pi.registerTool({
		name: "kb_convert",
		label: "kb_convert",
		description:
			"Compile a document or URL (pdf/docx/html/md/…) into greppable markdown sections under the vault's raw/<name>/ ('convert'), or build its per-section retrieval map raw/<name>/_map.md ('distill'). Use for any source too large to read whole; afterwards answer from _map.md plus the matched section files only — never load the entire source.",
		parameters: {
			type: "object",
			properties: {
				action: { type: "string", enum: ["convert", "distill"], description: "convert a new source, or distill an already-converted one into _map.md" },
				source: { type: "string", description: "file path or URL to convert, or the raw/<name> to distill" },
				name: { type: "string", description: "optional folder name under raw/ (convert only)" },
			},
			required: ["action", "source"],
		},
		execute: async (_id, p) =>
			text(await runConvert(p.action === "distill" ? ["distill", p.source] : [p.source, ...(p.name ? [p.name] : [])])),
	});

	pi.registerCommand("kb-sync", {
		description: "Sync the knowledge base with its remote. /kb-sync [push|pull|status|init <gcrypt-url> [gpg-key]]",
		handler: async (args) => {
			const parts = args.trim().split(/\s+/).filter(Boolean);
			const out = await runSync(parts.length ? parts : ["status"]);
			pi.sendUserMessage("```\n" + out.slice(0, 4000) + "\n```");
		},
	});

	pi.registerCommand("kb-index-chats", {
		description: "Toggle whether chats/ is included in kb search (default: excluded).",
		handler: async () => {
			const f = indexChatsFile();
			let on;
			try {
				if (fs.existsSync(f)) { fs.unlinkSync(f); on = false; }
				else { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, "on\n"); on = true; }
			} catch (e) { return void pi.sendUserMessage("kb: couldn't toggle index_chats — " + e.message); }
			pi.sendUserMessage(`kb: chats/ ${on ? "**included in**" : "**excluded from**"} search.`);
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
