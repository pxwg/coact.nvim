/**
 * coact.nvim handoff for Pi.
 *
 * `/nvim [adapter]` opens the current Pi session as a coact.nvim thread.
 *
 * - Inside a Neovim :terminal ($NVIM set): the parent Neovim resumes the
 *   session and this Pi process exits, so only one process writes the session.
 * - Otherwise: the Pi TUI suspends, Neovim runs in the foreground, and Pi
 *   reloads the session file after Neovim exits.
 *
 * Install: symlink or copy this file into ~/.pi/agent/extensions/, or load it
 * with `pi --extension <path>`.
 *
 * Environment:
 *   COACT_NVIM        Neovim executable (default: nvim)
 *   COACT_PI_ADAPTER  coact.nvim adapter name for Pi (default: pi)
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const NVIM = process.env.COACT_NVIM || "nvim";
const DEFAULT_ADAPTER = process.env.COACT_PI_ADAPTER || "pi";

// Arguments reach Lua through environment variables or _A, never through
// command-line quoting. The handoff runs :Coact rather than require("coact")
// so plugin managers load coact.nvim and apply the user's setup() first.
// -c runs before VimEnter, so the foreground handoff waits for it; otherwise
// start screens such as dashboards cover the thread.
const FOREGROUND_LUA = [
	"lua local function open()",
	"vim.cmd({ cmd = 'Coact', args = { 'resume', vim.env.COACT_RESUME_REF, vim.env.COACT_RESUME_ADAPTER } })",
	"end",
	"if vim.v.vim_did_enter == 1 then vim.schedule(open) else",
	"vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function() vim.schedule(open) end })",
	"end",
].join(" ");
const REMOTE_LUA =
	'(function(a) vim.schedule(function() vim.cmd({ cmd = "Coact", args = { "resume", a[1], a[2] } }) end) return 0 end)(_A)';

// JSON string literals are valid Vim script double-quoted strings.
function remoteExpr(ref: string, adapter: string): string {
	return `luaeval('${REMOTE_LUA}', [${JSON.stringify(ref)}, ${JSON.stringify(adapter)}])`;
}

export default function (pi: ExtensionAPI) {
	pi.registerCommand("nvim", {
		description: "Continue this session in Neovim through coact.nvim",
		handler: async (args, ctx) => {
			const adapter = args.trim() || DEFAULT_ADAPTER;
			if (!ctx.isIdle()) {
				ctx.ui.notify("Waiting for the current run to finish…", "info");
				await ctx.waitForIdle();
			}
			const sessionFile = ctx.sessionManager.getSessionFile();
			if (!sessionFile || !existsSync(sessionFile)) {
				ctx.ui.notify("This session has no saved file yet; send a message first", "warning");
				return;
			}

			const server = process.env.NVIM;
			if (server) {
				const result = await pi.exec(NVIM, ["--server", server, "--remote-expr", remoteExpr(sessionFile, adapter)]);
				if (result.code !== 0) {
					ctx.ui.notify(`Neovim handoff failed: ${(result.stderr || result.stdout).trim()}`, "error");
					return;
				}
				ctx.ui.notify("Session opened in the parent Neovim; closing Pi", "info");
				ctx.shutdown();
				return;
			}

			if (ctx.mode !== "tui") {
				ctx.ui.notify("/nvim needs the interactive TUI or a parent Neovim ($NVIM)", "error");
				return;
			}
			const status = await ctx.ui.custom<number | null>((tui, _theme, _keybindings, done) => {
				tui.stop();
				process.stdout.write("\x1b[2J\x1b[H");
				const result = spawnSync(NVIM, ["-c", FOREGROUND_LUA], {
					stdio: "inherit",
					cwd: ctx.cwd,
					env: { ...process.env, COACT_RESUME_REF: sessionFile, COACT_RESUME_ADAPTER: adapter },
				});
				tui.start();
				tui.requestRender(true);
				done(result.error ? null : result.status);
				return { render: () => [], invalidate: () => {} };
			});
			// Neovim appended turns through its own Pi process; reload them.
			await ctx.switchSession(sessionFile, {
				withSession: async (next) => {
					if (status !== 0) {
						next.ui.notify(`Neovim exited with status ${status ?? "unknown"}`, "warning");
					}
				},
			});
		},
	});
}
