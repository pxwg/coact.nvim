/**
 * Coact mode for Pi: the pinned main card is the conversation.
 *
 * coact.nvim starts Pi in RPC mode with this extension for Coact mode; it is
 * not meant to be installed as a user extension. The OCaml language server
 * exports the pinned card as Pi-native messages (the artifact); this
 * extension makes every model request see exactly
 *
 *   artifact + this run's own messages after the submit boundary
 *
 * so Pi's history never overrides a card the user has revised. It also
 * routes compaction into a reviewed synthesis card and file writes into
 * Neovim review.
 *
 * Neovim and the extension talk over RPC extension-UI "editor" dialogs titled
 * "coact-mode": the prefill is a JSON request, the reply a JSON answer.
 *
 * Card tools (thread_view, card_read, card_search, card_create, card_edit,
 * thread_arrange) let the agent work on the cards by ID; Neovim plans them
 * with the language server and reviews every change to an existing card.
 *
 * Environment:
 *   COACT_MODE_WORKSPACE           absolute path of the chat workspace; new
 *                                  files there are written directly, cards
 *                                  only through the card tools, every other
 *                                  write is reviewed
 *   COACT_MODE_PROMPT              the system prompt section; empty for none
 *   COACT_MODE_TITLE_MODEL         "provider/id" naming cards; default: the
 *                                  thread's model
 *   COACT_MODE_KEEP_RECENT_TOKENS  recent context kept verbatim when compacting
 */

import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	calculateContextTokens,
	convertToLlm,
	createEditToolDefinition,
	createWriteToolDefinition,
	DEFAULT_COMPACTION_SETTINGS,
	findCutPoint,
	SessionManager,
	serializeConversation,
	shouldCompact,
} from "@earendil-works/pi-coding-agent";

const CHANNEL = "coact-mode";
const SUBMIT = "coact.submit";
const FINISH = "coact.finish";

const PROMPT = process.env.COACT_MODE_PROMPT ?? "";

const SUMMARY_SYSTEM =
	"You rewrite a conversation as a knowledge card. Do not continue the conversation and do not answer its questions; output only the card's text.";

const SUMMARY_INSTRUCTIONS = [
	"Rewrite the conversation below as one self-contained knowledge card that will replace it in later context.",
	"- State what was established, with the reasoning that supports it.",
	"- Keep open questions, unresolved conflicts and interpretations the user has not accepted, and label them as such; never present an unconfirmed interpretation as settled.",
	"- Keep exact names, definitions, file paths and code that later discussion depends on.",
	"- Write Org markup: '-' for list items, *bold*, ~code~, #+begin_src blocks for code. Never start a line with '*' followed by a space. Do not add a title.",
].join("\n");

/** One summary call over the summarized cards. */
async function summarize(ctx: ExtensionContext, messages: Message[], extra: string | undefined, signal?: AbortSignal) {
	const model = ctx.model;
	if (!model) throw new Error("no model is selected");
	const conversation = serializeConversation(convertToLlm(messages as any) as any);
	const request = [SUMMARY_INSTRUCTIONS, extra ? `\nThe user asks: ${extra}` : "", `\n<conversation>\n${conversation}\n</conversation>`].join("\n");
	const response: any = await ctx.modelRegistry.complete(
		model,
		{ systemPrompt: SUMMARY_SYSTEM, messages: [{ role: "user", content: [{ type: "text", text: request }], timestamp: Date.now() }] } as any,
		{ maxTokens: 8192, signal } as any,
	);
	if (response.stopReason === "error" || response.stopReason === "aborted") {
		throw new Error(response.errorMessage || `the summary call ${response.stopReason === "aborted" ? "was aborted" : "failed"}`);
	}
	const summary = (response.content ?? [])
		.filter((block: any) => block?.type === "text")
		.map((block: any) => block.text)
		.join("")
		.trim();
	if (!summary) throw new Error("the model returned an empty summary");
	return summary;
}

type Message = { role: string; [key: string]: unknown };
type Source = { item: number; card: string; role: string };
type Artifact = {
	main: string;
	thread: string | null;
	messages: Message[];
	sources: Source[];
	items: { card: string; title: string; kind: string | null; included: boolean }[];
	question: string | null;
};

type Run = {
	submitId: string;
	answer: string;
	artifact: Artifact;
	trigger?: string;
	/** Directives of the question, expanded once: placed before it, kept in the trace. */
	expansions: Message[];
	retryAfterCompaction?: boolean;
	/** This turn's threshold compaction already ran. */
	compactedThisTurn?: boolean;
};

let run: Run | undefined;
let uiContext: ExtensionContext | undefined;

/** Ask Neovim and wait for its answer. */
async function ask(ctx: ExtensionContext, op: string, payload: Record<string, unknown>): Promise<any> {
	const value = await ctx.ui.editor(CHANNEL, JSON.stringify({ op, ...payload }));
	if (value === undefined) throw new Error(`Neovim did not answer ${op}`);
	const reply = JSON.parse(value);
	if (reply && typeof reply.error === "string") throw new Error(reply.error);
	return reply;
}

async function report(ctx: ExtensionContext, stage: string, error: unknown) {
	const message = error instanceof Error ? error.message : String(error);
	try {
		await ask(ctx, "error", { stage, message });
	} catch {
		ctx.ui.notify(`Coact mode ${stage}: ${message}`, "error");
	}
}

function textOf(message: Message): string {
	const content = message.content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((block: any) => block?.type === "text" && typeof block.text === "string")
		.map((block: any) => block.text)
		.join("");
}

/** Reject an artifact that would make a malformed request. */
export function validateArtifact(artifact: any, requireQuestion: boolean): string | undefined {
	if (!artifact || !Array.isArray(artifact.messages)) return "the artifact has no messages";
	if (!Array.isArray(artifact.sources) || artifact.sources.length !== artifact.messages.length) {
		return "artifact sources do not match its messages";
	}
	const calls = new Set<string>();
	for (const message of artifact.messages) {
		if (!message || !["user", "assistant", "toolResult", "custom"].includes(message.role)) {
			return `unsupported message role ${message?.role}`;
		}
		if (message.role === "assistant" && Array.isArray(message.content)) {
			for (const block of message.content) if (block?.type === "toolCall") calls.add(block.id);
		}
		if (message.role === "toolResult" && !calls.has(message.toolCallId)) {
			return `tool result ${message.toolCallId} has no preceding call`;
		}
	}
	if (requireQuestion) {
		const last = artifact.messages[artifact.messages.length - 1];
		if (!last || last.role !== "user" || textOf(last).trim() === "") return "the artifact does not end with a question";
	}
	return undefined;
}

/**
 * Model-visible messages this run produced after its submit boundary, minus
 * the user message that started it. Taken from Pi's canonical projection, so
 * retries and context edits Pi applied are respected.
 */
export function runDelta(sessionManager: ExtensionContext["sessionManager"], current: Run) {
	const branch = sessionManager.getBranch();
	const boundary = branch.findIndex(
		(entry: any) => entry.type === "custom" && entry.customType === SUBMIT && entry.data?.submitId === current.submitId,
	);
	if (boundary < 0) return { messages: [] as Message[], entries: [] as any[] };
	const after = branch.slice(boundary + 1);
	if (!current.trigger) {
		const trigger = after.find((entry: any) => entry.type === "message" && entry.message?.role === "user");
		if (trigger) current.trigger = trigger.id;
	}
	const ids = new Set(after.map((entry: any) => entry.id));
	if (current.trigger) ids.delete(current.trigger);
	const projected = sessionManager
		.buildSessionProjection()
		.entries.filter((entry: any) => ids.has(entry.sourceEntry.id));
	const messages = projected.flatMap((entry: any) => entry.messages).filter((m: Message) => m.role !== "system");
	const entries = projected
		.filter((entry: any) => entry.sourceEntry.type === "message" && entry.messages.length > 0)
		.map((entry: any) => ({ ...entry.sourceEntry, message: entry.messages[0] }));
	return { messages, entries };
}

// ---- turn directives: /skill:name and /template, @context ----

function stripFrontmatter(text: string) {
	if (!text.startsWith("---")) return text;
	const end = text.indexOf("\n---", 3);
	if (end < 0) return text;
	const next = text.indexOf("\n", end + 4);
	return next < 0 ? "" : text.slice(next + 1);
}

/** Pi's prompt-template argument parsing: whitespace-separated, quotes group. */
export function parseCommandArgs(input: string): string[] {
	const args: string[] = [];
	const pattern = /"((?:\\"|[^"])*)"|'([^']*)'|(\S+)/g;
	for (const match of input.matchAll(pattern)) args.push(match[1]?.replace(/\\"/g, '"') ?? match[2] ?? match[3]);
	return args;
}

/** Pi's prompt-template substitution: $1, $@, $ARGUMENTS, ${1:-default}, ${@:2:3}. */
export function substituteArgs(content: string, args: string[]): string {
	const all = args.join(" ");
	return content.replace(
		/\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/g,
		(_m, target, fallback, sliceStart, sliceLength, simple) => {
			if (target) {
				const value = target === "@" || target === "ARGUMENTS" ? all : args[parseInt(target, 10) - 1];
				return value ? value : fallback;
			}
			if (sliceStart) {
				const start = Math.max(0, parseInt(sliceStart, 10) - 1);
				return (sliceLength ? args.slice(start, start + parseInt(sliceLength, 10)) : args.slice(start)).join(" ");
			}
			if (simple === "ARGUMENTS" || simple === "@") return all;
			return args[parseInt(simple, 10) - 1] ?? "";
		},
	);
}

/** Expand /name args as Pi does for a typed prompt: a skill block or a template. */
function expandCommand(pi: ExtensionAPI, name: string, args: string): Message {
	const command: any = pi.getCommands().find((c: any) => c.name === name);
	if (!command) throw new Error(`unknown command /${name}`);
	let path: string = command.sourceInfo?.path ?? "";
	if (path && statSync(path).isDirectory()) path = join(path, "SKILL.md");
	let content: string;
	if (command.source === "skill") {
		const body = stripFrontmatter(readFileSync(path, "utf8")).trim();
		const block = `<skill name="${name.replace(/^skill:/, "")}" location="${path}">\nReferences are relative to ${dirname(path)}.\n\n${body}\n</skill>`;
		content = args ? `${block}\n\n${args}` : block;
	} else if (command.source === "prompt") {
		content = substituteArgs(stripFrontmatter(readFileSync(path, "utf8")), parseCommandArgs(args));
	} else {
		throw new Error(`/${name} is not a skill or prompt template; only those run from cards`);
	}
	return { role: "custom", customType: "coact.command", content, display: true, details: { name, args }, timestamp: Date.now() };
}

function expandDirectives(pi: ExtensionAPI, request: any): Message[] {
	const out: Message[] = [];
	for (const context of request.contexts ?? []) {
		out.push({
			role: "custom",
			customType: "coact.context",
			content: `@${context.name}:\n${context.text}`,
			display: true,
			details: { name: context.name },
			timestamp: Date.now(),
		});
	}
	for (const command of request.commands ?? []) out.push(expandCommand(pi, command.name, command.args ?? ""));
	return out;
}

/** The run's context: the cards, the question's expansions just before it, then the run. */
function runContext(current: Run, delta: Message[]) {
	const messages = current.artifact.messages;
	return [...messages.slice(0, -1), ...current.expansions, ...messages.slice(-1), ...delta];
}

// ---- semantic titles ----

const TITLE_SYSTEM = "You name the cards of a long discussion so a reader can find them. Output only JSON.";

const TITLE_INSTRUCTIONS = [
	"Name each card below. Name each card by what it discusses, not by who wrote it: the title is an index, not a summary.",
	"- user card: the object asked about and what is asked of it.",
	"- assistant card: its central conclusion or mechanism.",
	"- synthesis card: the knowledge it states, as a proposition that stands alone.",
	"Keep the card's own terms exactly; do not replace a technical term with a looser one. Write in the card's language. Keep titles short (at most about twelve words or twenty CJK characters), without markup or a final period.",
	'Reply with one JSON object: {"titles": {"id1": "...", "id2": "..."}}.',
].join("\n");

const ANCHOR_INSTRUCTIONS = [
	"The cards discuss the passage below, quoted from a note. Also pick \"anchor\": a short phrase copied exactly from the passage, on one line, naming what the discussion is about; the note will link that phrase to the discussion.",
	'Add it to the JSON object: {"titles": {...}, "anchor": "..."}.',
].join("\n");

function titleModel(ctx: ExtensionContext) {
	const spec = process.env.COACT_MODE_TITLE_MODEL;
	const slash = spec ? spec.indexOf("/") : -1;
	if (spec && slash > 0) {
		const model = (ctx.modelRegistry as any).find(spec.slice(0, slash), spec.slice(slash + 1));
		if (model) return model;
	}
	if (!ctx.model) throw new Error("no model is selected");
	return ctx.model;
}

/** One background call naming cards ({ id, kind, text, revision }[]) and,
 * for an asked thread, picking the phrase of its passage to link back. */
async function nameCards(ctx: ExtensionContext, cards: any[], link?: { passage: string }) {
	const parts = [TITLE_INSTRUCTIONS];
	if (link) parts.push(ANCHOR_INSTRUCTIONS, `<passage>\n${String(link.passage).slice(0, 4000)}\n</passage>`);
	parts.push(
		cards.map((card) => `<card id="${card.id}" kind="${card.kind}">\n${String(card.text).slice(0, 4000)}\n</card>`).join("\n\n"),
	);
	const body = parts.join("\n\n");
	const response: any = await ctx.modelRegistry.complete(
		titleModel(ctx),
		{
			systemPrompt: TITLE_SYSTEM,
			messages: [{ role: "user", content: [{ type: "text", text: body }], timestamp: Date.now() }],
		} as any,
		{ maxTokens: 2048 } as any,
	);
	if (response.stopReason === "error" || response.stopReason === "aborted") {
		throw new Error(response.errorMessage || "the naming call failed");
	}
	const text = (response.content ?? [])
		.filter((block: any) => block?.type === "text")
		.map((block: any) => block.text)
		.join("");
	const json = text.match(/\{[\s\S]*\}/);
	if (!json) throw new Error("the naming call returned no JSON");
	const reply = JSON.parse(json[0]);
	const names = reply && typeof reply.titles === "object" && reply.titles ? reply.titles : reply;
	return {
		titles: cards
			.filter((card) => typeof names[card.id] === "string")
			.map((card) => ({ id: card.id, revision: card.revision, title: names[card.id] })),
		anchor: link && typeof reply.anchor === "string" ? reply.anchor : undefined,
	};
}

function readJson(path: string) {
	return JSON.parse(readFileSync(path, "utf8"));
}

function compactionSettings(settings?: Partial<typeof DEFAULT_COMPACTION_SETTINGS>) {
	const keep = Number(process.env.COACT_MODE_KEEP_RECENT_TOKENS);
	return {
		...DEFAULT_COMPACTION_SETTINGS,
		...(settings ?? {}),
		...(Number.isFinite(keep) && keep > 0 ? { keepRecentTokens: keep } : {}),
		enabled: true,
	};
}

/**
 * Compact the cards: Pi's cut-point search runs on an in-memory session
 * holding the cards (not Pi's own history), the cut is rounded down to whole
 * conversation items, one model call rewrites them as knowledge, and Neovim
 * reviews the synthesis card. Retried with the user's prompt until accepted
 * or cancelled.
 */
async function compactCards(
	ctx: ExtensionContext,
	artifact: Artifact,
	delta: Message[],
	options: { reason: string; instructions?: string; signal?: AbortSignal; settings?: any },
): Promise<{ accepted: boolean; artifact?: Artifact }> {
	const memory = SessionManager.inMemory(ctx.cwd);
	const ids = [...artifact.messages, ...delta].map((message) => memory.appendMessage(message as any));
	const settings = compactionSettings(options.settings);
	const entries = memory.getBranch();
	const point = findCutPoint(entries, 0, entries.length, settings.keepRecentTokens);
	let cut = ids.indexOf(entries[point.firstKeptEntryIndex]?.id);
	if (cut <= 0) throw new Error("nothing to compact: the conversation fits in the kept recent window");
	// Keep this run's own messages and the question; summarize whole items only.
	const keepFrom = artifact.question ? artifact.messages.length - 1 : artifact.messages.length;
	if (cut < 0 || cut > keepFrom) cut = keepFrom;
	const count = cut < artifact.sources.length ? artifact.sources[cut].item : artifact.items.length;
	const kept = Math.min(count, artifact.items.length - 1);
	if (kept < 1) throw new Error("nothing to compact: no whole card precedes the kept window");
	const summarized = artifact.messages.filter((_, index) => artifact.sources[index].item < kept);
	let extra = options.instructions?.trim() || undefined;
	for (;;) {
		const summary = await summarize(ctx, summarized, extra, options.signal);
		const reply = await ask(ctx, "compact", {
			reason: options.reason,
			main: artifact.main,
			count: kept,
			items: artifact.items.slice(0, kept),
			summary,
		});
		if (reply.decision === "accept") {
			const next = typeof reply.artifactJson === "string" ? (JSON.parse(reply.artifactJson) as Artifact) : undefined;
			if (next) {
				const invalid = validateArtifact(next, artifact.question !== null);
				if (invalid) throw new Error(`re-exported cards are invalid: ${invalid}`);
			}
			return { accepted: true, artifact: next };
		}
		if (reply.decision === "retry") {
			extra = typeof reply.prompt === "string" && reply.prompt.trim() !== "" ? reply.prompt : extra;
			continue;
		}
		return { accepted: false };
	}
}

/** Resolve symlinks through the nearest existing ancestor (e.g. /var -> /private/var). */
function canonical(path: string): string {
	const absolute = resolve(path);
	if (existsSync(absolute)) return realpathSync(absolute);
	const parent = dirname(absolute);
	return parent === absolute ? absolute : join(canonical(parent), basename(absolute));
}

function insideWorkspace(path: string): boolean {
	const root = process.env.COACT_MODE_WORKSPACE;
	if (!root) return false;
	const rel = relative(canonical(root), canonical(path));
	return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}

/** Write through Neovim review; new files in the chat workspace go straight to disk. */
async function reviewedWrite(path: string, content: string) {
	let old: string | undefined;
	try {
		old = await readFile(path, "utf8");
	} catch (error: any) {
		if (error?.code !== "ENOENT") throw error;
	}
	if (insideWorkspace(path) && path.endsWith(".org")) {
		throw new Error(
			"Cards in the chat workspace change through the card tools (card_create, card_edit, thread_arrange), not by writing their files.",
		);
	}
	if (old === undefined && insideWorkspace(path)) {
		await mkdir(dirname(path), { recursive: true });
		await writeFile(path, content, "utf8");
		return;
	}
	if (!uiContext) throw new Error("no Neovim session is available to review this change");
	const reply = await ask(uiContext, "review", {
		path,
		oldContent: old ?? "",
		newContent: content,
		kind: old === undefined ? "add" : "update",
	});
	if (!reply.success) throw new Error(reply.summary || `The change to ${path} was rejected in Neovim review.`);
	if (reply.partial) {
		throw new Error(
			`Only part of the change to ${path} was accepted in Neovim review (${reply.summary}). Read the file again before editing it.`,
		);
	}
}

function reviewedTools(pi: ExtensionAPI) {
	const cwd = process.cwd();
	const edit = createEditToolDefinition(cwd, {
		operations: {
			readFile: (path) => readFile(path),
			access: async (path) => {
				await readFile(path);
			},
			writeFile: reviewedWrite,
		},
	});
	const write = createWriteToolDefinition(cwd, {
		operations: { writeFile: reviewedWrite, mkdir: async () => {} },
	});
	for (const tool of [edit, write] as any[]) {
		pi.registerTool({
			...tool,
			promptGuidelines: [
				...(tool.promptGuidelines ?? []),
				`${tool.name} changes to existing files are reviewed by the user in Neovim before they are written.`,
			],
			async execute(id: string, params: any, signal: any, onUpdate: any, ctx: ExtensionContext) {
				uiContext = ctx;
				return tool.execute(id, params, signal, onUpdate, ctx);
			},
		});
	}
}

const text = (value: unknown) => ({ content: [{ type: "text" as const, text: typeof value === "string" ? value : JSON.stringify(value, null, 1) }], details: undefined });

/** Ask Neovim for a card tool, returning its answer or throwing its error. */
async function cardCall(ctx: ExtensionContext, op: string, payload: Record<string, unknown>) {
	uiContext = ctx;
	if (!run) throw new Error("the card tools work during a Coact turn");
	return ask(ctx, op, payload);
}

function changeReport(reply: any) {
	const lines = [`Accepted ${reply.accepted} change${reply.accepted === 1 ? "" : "s"}, rejected ${reply.rejected}.`];
	for (const reason of reply.reasons ?? []) lines.push(`Rejected because: ${reason}`);
	if ((reply.errors ?? []).length > 0) {
		lines.push("The workspace now has errors:");
		for (const error of reply.errors) lines.push(`- line ${error.range.start.line + 1}: ${error.message}`);
	}
	if (reply.rejected > 0) lines.push("The cards as reviewed are authoritative; read them again before further changes.");
	return lines.join("\n");
}

function cardTools(pi: ExtensionAPI) {
	const query = (method: string) => async (_id: string, params: any, _signal: any, _onUpdate: any, ctx: ExtensionContext) =>
		text((await cardCall(ctx, "query", { method, params })).result);
	pi.registerTool({
		name: "thread_view",
		label: "thread_view",
		description:
			"Outline of a Coact thread: its items in order with card IDs, kinds, titles and estimated tokens, and the traces each answer replays. No card text. Omit main for the current thread.",
		parameters: Type.Object({ main: Type.Optional(Type.String({ description: "The thread's main card ID" })) }),
		execute: query("thread_view"),
	} as any);
	pi.registerTool({
		name: "card_read",
		label: "card_read",
		description:
			"Read one card: metadata, its own text (nested cards appear as one-line placeholders), nested cards, links and backlinks. A trace card reads as a readable account unless raw is true.",
		parameters: Type.Object({
			id: Type.String(),
			offset: Type.Optional(Type.Number({ description: "First line, 1-based" })),
			limit: Type.Optional(Type.Number({ description: "Lines to read (default 200)" })),
			raw: Type.Optional(Type.Boolean({ description: "A trace card's raw record" })),
		}),
		execute: query("card_read"),
	} as any);
	pi.registerTool({
		name: "card_search",
		label: "card_search",
		description: "Find cards of the chat workspace whose title or text contain every word of the query.",
		parameters: Type.Object({ query: Type.String(), limit: Type.Optional(Type.Number()) }),
		execute: query("card_search"),
	} as any);
	pi.registerTool({
		name: "card_create",
		label: "card_create",
		description:
			"Create a card in its own file in the chat workspace; it is written directly and its ID returned. It joins no thread until thread_arrange adds it. kind: user (the user's message), assistant (your message), synthesis (knowledge distilled from discussion; mark open questions and interpretations the user has not accepted as such), trace (a process record) or note (default).",
		parameters: Type.Object({
			title: Type.String(),
			body: Type.String({ description: "Org text; section headings use two or more stars, and no property drawer" }),
			kind: Type.Optional(Type.String({ description: "user, assistant, synthesis, trace or note" })),
		}),
		async execute(_id: string, params: any, _signal: any, _onUpdate: any, ctx: ExtensionContext) {
			const reply = await cardCall(ctx, "create", { params });
			return text(`Created card ${reply.id}.`);
		},
	} as any);
	pi.registerTool({
		name: "card_edit",
		label: "card_edit",
		description:
			"Exact text replacements in one card's own text, never its heading, properties or nested cards. Each oldText must occur exactly once in the card; an empty oldText fills a blank card. newText may contain section headings with more stars than the card's own heading, but no heading at or above its level and no property drawer. The user reviews the change and may accept part of it or edit it.",
		parameters: Type.Object({
			id: Type.String(),
			edits: Type.Array(Type.Object({ oldText: Type.String(), newText: Type.String() })),
		}),
		executionMode: "sequential",
		async execute(_id: string, params: any, _signal: any, _onUpdate: any, ctx: ExtensionContext) {
			return text(changeReport(await cardCall(ctx, "changeset", { method: "card_edit", params })));
		},
	} as any);
	pi.registerTool({
		name: "thread_arrange",
		label: "thread_arrange",
		description:
			"Set a thread's items to an ordered list of card IDs. Cards left out leave the thread but are kept; new IDs are transcluded. Omit main for the current thread. The user reviews the change.",
		parameters: Type.Object({
			items: Type.Array(Type.String()),
			main: Type.Optional(Type.String()),
		}),
		executionMode: "sequential",
		async execute(_id: string, params: any, _signal: any, _onUpdate: any, ctx: ExtensionContext) {
			return text(changeReport(await cardCall(ctx, "changeset", { method: "thread_arrange", params })));
		},
	} as any);
}

export default function (pi: ExtensionAPI) {
	reviewedTools(pi);
	cardTools(pi);

	pi.registerCommand("coact-submit", {
		description: "Coact mode: start a run from an exported card artifact (internal)",
		handler: async (args, ctx) => {
			uiContext = ctx;
			try {
				if (!ctx.isIdle()) throw new Error("Pi is still running");
				const request = readJson(args.trim());
				const invalid = validateArtifact(request.artifact, true);
				if (invalid) throw new Error(invalid);
				const artifact = request.artifact as Artifact;
				const expansions = expandDirectives(pi, request);
				run = { submitId: String(request.submitId), answer: String(request.answer), artifact, expansions };
				pi.appendEntry(SUBMIT, { submitId: run.submitId, main: artifact.main, question: artifact.question, answer: run.answer });
				pi.sendUserMessage(textOf(artifact.messages[artifact.messages.length - 1]));
			} catch (error) {
				run = undefined;
				await report(ctx, "submit", error);
			}
		},
	});

	pi.registerCommand("coact-finish", {
		description: "Coact mode: hand this run's messages to Neovim (internal)",
		handler: async (_args, ctx) => {
			uiContext = ctx;
			const current = run;
			if (!current) {
				await report(ctx, "finish", new Error("no Coact run is active"));
				return;
			}
			try {
				const { entries } = runDelta(ctx.sessionManager, current);
				const last = [...entries].reverse().find((entry: any) => entry.message?.role === "assistant");
				const final = last && !(last.message.content ?? []).some((block: any) => block?.type === "toolCall");
				await ask(ctx, "finish", {
					submitId: current.submitId,
					answer: current.answer,
					text: final ? textOf(last.message) : "",
					stopReason: last?.message?.stopReason ?? null,
					errorMessage: last?.message?.errorMessage ?? null,
					// A string, so the records reach the trace card verbatim.
					entriesJson: JSON.stringify([...current.expansions, ...entries]),
				});
				pi.appendEntry(FINISH, { submitId: current.submitId, answer: current.answer });
			} catch (error) {
				await report(ctx, "finish", error);
			} finally {
				if (run === current) run = undefined;
			}
		},
	});

	pi.registerCommand("coact-title", {
		description: "Coact mode: name cards by what they discuss, in the background (internal)",
		handler: async (args, ctx) => {
			let titles: any[] = [];
			let anchor: string | undefined;
			let error: string | undefined;
			const request = readJson(args.trim());
			try {
				({ titles, anchor } = await nameCards(ctx, request.cards ?? [], request.link ?? undefined));
			} catch (e) {
				error = e instanceof Error ? e.message : String(e);
			}
			try {
				await ask(ctx, "titles", { titles, anchor, main: request.link?.main, error });
			} catch {
				// Neovim went away; titles are optional.
			}
		},
	});

	pi.registerCommand("coact-compact", {
		description: "Coact mode: compact the pinned card into a reviewed synthesis card (internal)",
		handler: async (args, ctx) => {
			uiContext = ctx;
			try {
				if (run) throw new Error("compact between runs, or let Pi compact during the run");
				const request = readJson(args.trim());
				const invalid = validateArtifact(request.artifact, false);
				if (invalid) throw new Error(invalid);
				const controller = new AbortController();
				const result = await compactCards(ctx, request.artifact, [], {
					reason: "manual",
					instructions: request.instructions,
					signal: controller.signal,
				});
				await ask(ctx, "compacted", { accepted: result.accepted });
			} catch (error) {
				await report(ctx, "compact", error);
			}
		},
	});

	pi.on("before_agent_start", async (event) => {
		if (!run || !PROMPT) return;
		const options: any = event.systemPromptOptions;
		options.sections = options.sections ?? {};
		options.sections.coact_mode = PROMPT;
	});

	pi.on("context", async (_event, ctx) => {
		if (!run) return;
		return { messages: runContext(run, runDelta(ctx.sessionManager, run).messages) as any };
	});

	/** Compact during a run; the accepted cards become the run's new baseline. */
	async function compactRun(ctx: ExtensionContext, current: Run, reason: string, extra: any = {}) {
		uiContext = ctx;
		try {
			const result = await compactCards(ctx, current.artifact, runDelta(ctx.sessionManager, current).messages, {
				reason,
				...extra,
			});
			if (result.accepted && result.artifact && run === current) current.artifact = result.artifact;
			return result.accepted;
		} catch (error) {
			await report(ctx, "compact", error);
			return false;
		}
	}

	pi.on("turn_start", async () => {
		if (run) run.compactedThisTurn = false;
	});

	// Pi decides threshold compaction from its own history, which in Coact
	// mode can be small while the cards fill the window. Check the request
	// that was actually sent instead.
	pi.on("turn_end", async (event: any, ctx) => {
		const current = run;
		const message = event.message;
		const window = ctx.model?.contextWindow;
		if (!current || message?.role !== "assistant" || !message.usage || !window) return;
		if (!shouldCompact(calculateContextTokens(message.usage), window, compactionSettings())) return;
		current.compactedThisTurn = true;
		await compactRun(ctx, current, "threshold");
	});

	// Pi's own history is not the context in Coact mode. Its compaction
	// becomes a reviewed synthesis card instead.
	pi.on("session_before_compact", async (event, ctx) => {
		const current = run;
		if (!current) return { cancel: true };
		if (event.reason === "threshold" && current.compactedThisTurn) return { cancel: true };
		const accepted = await compactRun(ctx, current, event.reason, {
			instructions: event.customInstructions,
			signal: event.signal,
			settings: event.preparation?.settings,
		});
		if (accepted && event.reason === "overflow" && event.willRetry) current.retryAfterCompaction = true;
		return { cancel: true };
	});

	pi.on("agent_before_settle", async () => {
		if (run?.retryAfterCompaction) {
			run.retryAfterCompaction = false;
			return { continue: true };
		}
	});
}
