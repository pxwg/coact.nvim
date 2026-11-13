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
 * Environment:
 *   COACT_MODE_WORKSPACE           absolute path of the chat workspace; new
 *                                  files there are written directly, every
 *                                  other write is reviewed
 *   COACT_MODE_KEEP_RECENT_TOKENS  recent context kept verbatim when compacting
 */

import { existsSync, readFileSync, realpathSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
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

const PROMPT = [
	"You are talking with the user through Coact mode in Neovim. The conversation is a set of Org-mode cards that the user edits freely; the messages you receive are rebuilt from the current cards before every request, so the cards, not your memory of earlier turns, are authoritative.",
	"A coact.revision message lists what the user changed since your last reply. A coact.synthesis message is knowledge the user distilled from earlier discussion; a coact.note message is reference material.",
	"Write your final answer in Org markup: '-' for list items, *bold*, ~code~, and #+begin_src/#+end_src blocks for code. Never start a line with '*' followed by a space: that starts a new card. Your final answer is placed into the answer card for you; do not edit the conversation cards to deliver it.",
	"When you are unsure, or interpretations conflict, say so plainly instead of presenting them as settled.",
].join("\n\n");

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

export default function (pi: ExtensionAPI) {
	reviewedTools(pi);

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
				run = { submitId: String(request.submitId), answer: String(request.answer), artifact };
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
					entriesJson: JSON.stringify(entries),
				});
				pi.appendEntry(FINISH, { submitId: current.submitId, answer: current.answer });
			} catch (error) {
				await report(ctx, "finish", error);
			} finally {
				if (run === current) run = undefined;
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
		if (!run) return;
		const options: any = event.systemPromptOptions;
		options.sections = options.sections ?? {};
		options.sections.coact_mode = PROMPT;
	});

	pi.on("context", async (_event, ctx) => {
		if (!run) return;
		return { messages: [...run.artifact.messages, ...runDelta(ctx.sessionManager, run).messages] as any };
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
