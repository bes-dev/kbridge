/**
 * KB harness for Pi — talk to the personal knowledge-base vault from any folder.
 *
 * Mirrors the Claude Code `/kb` skill: the agent operates on the vault with its native
 * file tools using ABSOLUTE paths under $VAULT (never cd), driven by the vault's own
 * AGENTS.md rules. This extension adds the two things the agent can't get for free:
 *   - `kb_search`  — ranked page search anywhere in the vault (via the shared kb-wiki script);
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

// chats/ holds saved raw transcripts. It's EXCLUDED from search by default (noise),
// included only when the shared `index_chats` flag file exists (kb-wiki reads it).
// Toggled via /kb-index-chats; shared with the kb skill.
const indexChatsFile = () => path.join(HOME, ".claude/skills/kb/index_chats");
const text = (s) => ({ content: [{ type: "text", text: String(s).slice(0, 8000) || "(no output)" }], details: {} });

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

const KICKOFF = (vault, req) => `You have access to the personal knowledge-base vault at \`${vault}\` — a markdown wiki. Operate on it from the current working directory using ABSOLUTE paths under that root — never cd.

First read \`${vault}/AGENTS.md\` (the authority on structure, article format, links and workflows) and \`${vault}/index.md\` (project map), then follow them strictly. Find pages with the \`kb_search\` tool; \`kb-wiki\` (toc / lint / mv) runs via bash at \`${resolveSkillBin("kb-wiki", "KB_WIKI_BIN") || "~/.claude/skills/kb/kb-wiki"}\`. \`chats/\` is excluded from search by default — ignore it unless I ask. Detect the mode from my request:
- QUERY (a question about the vault): the Query workflow. Do NOT write unless I ask.
- SCAN ("осмотрись тут" / material in the CWD that belongs in the vault): survey the CWD and output a PLAN only (what goes to raw/, which articles are extended or created, which links are added) — wait for my confirmation.
- INGEST (a source to record, or my confirmation of a plan): the article-first Ingest workflow — full detail in the articles; compression only in context.md.

Large documents (PDF/DOCX/HTML/URL — anything you can't cheaply read whole): NEVER load them into this conversation. Compile once with the \`kb_convert\` tool (action "convert" → sections in \`raw/<name>/\`, then action "distill" → \`raw/<name>/_map.md\`), then work map-first: read \`_map.md\`, grep the section files, read ONLY the sections that matched.

My request: ${req || "(none given — ask what I want, or default to QUERY mode)"}`;

export default function install(pi) {
	pi.registerTool({
		name: "kb_search",
		label: "kb_search",
		description: "Ranked search of the personal knowledge-base wiki from any working directory: title/aliases/tags rank above description and body; all terms must match (falls back to any). Lists pages and raw/ sources separately. Read-only — try 2–3 reformulations, incl. the other language.",
		parameters: {
			type: "object",
			properties: { query: { type: "string", description: "space-separated search terms (case-insensitive)" } },
			required: ["query"],
		},
		executionMode: "parallel",
		execute: async (_id, p) => text(await runScript(resolveSkillBin("kb-wiki", "KB_WIKI_BIN"), ["search", ...p.query.split(/\s+/).filter(Boolean)], 30000)),
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
