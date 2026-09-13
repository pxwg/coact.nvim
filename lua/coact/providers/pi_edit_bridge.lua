local config = require("coact.config")
local directory_allowlist = require("coact.directory_allowlist")
local util = require("coact.util")

local M = {}

local nonce = nil
local server_address = nil
local nvim_bin = nil
local extension_path = nil
local configured_options = nil
local direct_write_allowlist = nil
local direct_write_enabled = false

local function bridge_opts()
  local opts = config.get()
  local providers = opts.providers or {}
  local pi = providers.pi or {}
  return pi.edit_bridge or {}
end

local function direct_write_context()
  local ok_uname, uname = pcall(vim.uv.os_uname)
  uname = ok_uname and type(uname) == "table" and uname or {}
  local ok_tmpdir, os_tmpdir = pcall(vim.uv.os_tmpdir)
  os_tmpdir = ok_tmpdir and type(os_tmpdir) == "string" and os_tmpdir or nil
  local ok_tempname, tempname = pcall(vim.fn.tempname)
  local nvim_tmpdir = ok_tempname and type(tempname) == "string" and vim.fs.dirname(tempname) or nil
  return {
    cwd = config.cwd(),
    sysname = uname.sysname,
    uname = uname,
    os_tmpdir = os_tmpdir,
    nvim_tmpdir = nvim_tmpdir,
    env = {
      TMPDIR = vim.env.TMPDIR,
      TMP = vim.env.TMP,
      TEMP = vim.env.TEMP,
      LOCALAPPDATA = vim.env.LOCALAPPDATA,
    },
  }
end

-- This is deliberately the same callback contract exposed by
-- providers.pi.edit_bridge.direct_write, so this implementation is also a
-- complete configuration example.
local function configure_system_temp_direct_write(allowlist, context)
  allowlist:add(context.os_tmpdir)
  allowlist:add(context.nvim_tmpdir)
  allowlist:add(context.env.TMPDIR)
  allowlist:add(context.env.TMP)
  allowlist:add(context.env.TEMP)

  if context.sysname == "Windows_NT" then
    if context.env.LOCALAPPDATA and context.env.LOCALAPPDATA ~= "" then
      allowlist:add(vim.fs.joinpath(context.env.LOCALAPPDATA, "Temp"))
    end
  else
    allowlist:add("/tmp")
    allowlist:add("/var/tmp")
  end
end

local function run_direct_write_configurator(label, configure, allowlist, context)
  local ok, result = pcall(configure, allowlist, context)
  if not ok then
    error(("providers.pi.edit_bridge.direct_write %s failed: %s"):format(label, tostring(result)), 0)
  end
  if result ~= nil and result ~= allowlist then
    allowlist:add(result)
  end
end

local function ensure_direct_write_allowlist()
  if configured_options ~= config.get() then
    M.setup()
  end
end

local function enabled()
  local opts = bridge_opts()
  local ok, providers = pcall(require, "coact.providers")
  local provider_is_pi = ok and providers.is("pi")
  return provider_is_pi and config.edit_mode() == "pair" and opts.enabled ~= false
end

local function trim_trailing_slash(path)
  path = tostring(path or "")
  path = path:gsub("/+$", "")
  if path == "" then
    return "/tmp"
  end
  return path
end

local function ensure_server_address()
  if server_address and server_address ~= "" then
    return server_address
  end
  if vim.v.servername and vim.v.servername ~= "" then
    server_address = vim.v.servername
    return server_address
  end
  local root = vim.fn.tempname()
  local ok, address = pcall(vim.fn.serverstart, root .. ".sock")
  if ok and address and address ~= "" then
    server_address = address
    return server_address
  end
  return nil, address
end

local function ensure_nonce()
  if nonce then
    return nonce
  end
  nonce = vim.fn.sha256(tostring(vim.uv.hrtime()) .. ":" .. tostring(math.random()))
  return nonce
end

local function ensure_nvim_bin()
  if nvim_bin and nvim_bin ~= "" then
    return nvim_bin
  end
  local progpath = vim.v.progpath or "nvim"
  local resolved = vim.fn.exepath(progpath)
  nvim_bin = resolved ~= "" and resolved or progpath
  return nvim_bin
end

local function list_copy(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  if type(value) == "string" and value ~= "" then
    return { value }
  end
  return {}
end

local function append_command_args(command, args)
  if type(command) == "string" then
    if #args == 0 then
      return command
    end
    return command .. " " .. table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
  end
  local out = list_copy(command)
  vim.list_extend(out, args)
  return out
end

local function timeout_ms()
  local opts = bridge_opts()
  local value = tonumber(opts.timeout_ms or opts.timeout)
  if value == nil then
    value = (tonumber(opts.timeout_sec) or 600) * 1000
  end
  return math.max(1000, math.floor(value))
end

local function extension_source()
  return [=[
import { spawnSync } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { Type } from "typebox";

const treeSummaryStatusKey = "coact.nvim.tree-summary";

const replaceEditSchema = Type.Object({
  oldText: Type.String({
    description: "Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call.",
  }),
  newText: Type.String({ description: "Replacement text for this targeted edit." }),
}, { additionalProperties: false });

const editSchema = Type.Object({
  path: Type.String({ description: "Path to the file to edit (relative or absolute)" }),
  edits: Type.Array(replaceEditSchema, {
    description: "One or more targeted replacements. Each edit is matched against the original file, not incrementally.",
  }),
}, { additionalProperties: false });

const writeSchema = Type.Object({
  path: Type.String({ description: "Path to the file to write (relative or absolute)" }),
  content: Type.String({ description: "Content to write to the file" }),
}, { additionalProperties: false });

function normalizeToLF(text) {
  return String(text ?? "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function stripBom(content) {
  return content.startsWith("\uFEFF") ? { bom: "\uFEFF", text: content.slice(1) } : { bom: "", text: content };
}

function normalizeForFuzzyMatch(text) {
  return String(text ?? "")
    .normalize("NFKC")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .replace(/[\u2018\u2019\u201A\u201B]/g, "'")
    .replace(/[\u201C\u201D\u201E\u201F]/g, "\"")
    .replace(/[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]/g, "-")
    .replace(/[\u00A0\u2002-\u200A\u202F\u205F\u3000]/g, " ");
}

function fuzzyFindText(content, oldText) {
  const exactIndex = content.indexOf(oldText);
  if (exactIndex !== -1) {
    return { found: true, index: exactIndex, matchLength: oldText.length, usedFuzzyMatch: false };
  }
  const fuzzyContent = normalizeForFuzzyMatch(content);
  const fuzzyOldText = normalizeForFuzzyMatch(oldText);
  const fuzzyIndex = fuzzyContent.indexOf(fuzzyOldText);
  if (fuzzyIndex === -1) {
    return { found: false, index: -1, matchLength: 0, usedFuzzyMatch: false };
  }
  return { found: true, index: fuzzyIndex, matchLength: fuzzyOldText.length, usedFuzzyMatch: true };
}

function countOccurrences(content, oldText) {
  const fuzzyContent = normalizeForFuzzyMatch(content);
  const fuzzyOldText = normalizeForFuzzyMatch(oldText);
  if (fuzzyOldText.length === 0) {
    return 0;
  }
  return fuzzyContent.split(fuzzyOldText).length - 1;
}

function editError(path, index, total, message) {
  if (total === 1) {
    return new Error(message.replace("edits[INDEX]", "the text").replace("edits[].oldText", "the text"));
  }
  return new Error(message.replace("INDEX", String(index)));
}

function applyEditsToNormalizedContent(normalizedContent, rawEdits, path) {
  const edits = rawEdits.map((edit) => ({
    oldText: normalizeToLF(edit.oldText),
    newText: normalizeToLF(edit.newText),
  }));
  if (edits.length === 0) {
    throw new Error("Edit tool input is invalid. edits must contain at least one replacement.");
  }
  for (let i = 0; i < edits.length; i += 1) {
    if (edits[i].oldText.length === 0) {
      throw editError(path, i, edits.length, "edits[INDEX].oldText must not be empty in " + path + ".");
    }
  }

  const initialMatches = edits.map((edit) => fuzzyFindText(normalizedContent, edit.oldText));
  const baseContent = initialMatches.some((match) => match.usedFuzzyMatch)
    ? normalizeForFuzzyMatch(normalizedContent)
    : normalizedContent;
  const matchedEdits = [];

  for (let i = 0; i < edits.length; i += 1) {
    const edit = edits[i];
    const match = fuzzyFindText(baseContent, edit.oldText);
    if (!match.found) {
      throw editError(
        path,
        i,
        edits.length,
        "Could not find edits[INDEX] in " + path + ". The oldText must match exactly including all whitespace and newlines.",
      );
    }
    const occurrences = countOccurrences(baseContent, edit.oldText);
    if (occurrences > 1) {
      throw editError(
        path,
        i,
        edits.length,
        "Found " + occurrences + " occurrences of edits[INDEX] in " + path + ". Each oldText must be unique. Please provide more context to make it unique.",
      );
    }
    matchedEdits.push({
      editIndex: i,
      matchIndex: match.index,
      matchLength: match.matchLength,
      newText: edit.newText,
    });
  }

  matchedEdits.sort((a, b) => a.matchIndex - b.matchIndex);
  for (let i = 1; i < matchedEdits.length; i += 1) {
    const previous = matchedEdits[i - 1];
    const current = matchedEdits[i];
    if (previous.matchIndex + previous.matchLength > current.matchIndex) {
      throw new Error(
        "edits[" + previous.editIndex + "] and edits[" + current.editIndex + "] overlap in " + path + ". Merge them into one edit or target disjoint regions.",
      );
    }
  }

  let newContent = baseContent;
  for (let i = matchedEdits.length - 1; i >= 0; i -= 1) {
    const edit = matchedEdits[i];
    newContent = newContent.slice(0, edit.matchIndex) + edit.newText + newContent.slice(edit.matchIndex + edit.matchLength);
  }

  if (newContent === baseContent) {
    throw new Error("No changes made to " + path + ". The replacement produced identical content.");
  }

  return { baseContent, newContent };
}

function prepareEditArguments(input) {
  if (!input || typeof input !== "object") {
    return input;
  }
  const args = { ...input };
  if (typeof args.edits === "string") {
    try {
      const parsed = JSON.parse(args.edits);
      if (Array.isArray(parsed)) {
        args.edits = parsed;
      }
    } catch {}
  }
  if (typeof args.oldText === "string" && typeof args.newText === "string") {
    const edits = Array.isArray(args.edits) ? [...args.edits] : [];
    edits.push({ oldText: args.oldText, newText: args.newText });
    delete args.oldText;
    delete args.newText;
    args.edits = edits;
  }
  return args;
}

function assertBridgeEnv() {
  const addr = process.env.COACT_NVIM_PI_EDIT_BRIDGE_ADDR;
  const nonce = process.env.COACT_NVIM_PI_EDIT_BRIDGE_NONCE;
  const nvim = process.env.COACT_NVIM_PI_EDIT_BRIDGE_NVIM || "nvim";
  const clientId = process.env.COACT_NVIM_PI_CLIENT_ID;
  if (!addr) {
    throw new Error("coact.nvim Pi edit bridge is not connected to a Neovim RPC server.");
  }
  if (!nonce) {
    throw new Error("coact.nvim Pi edit bridge is missing its Neovim nonce.");
  }
  if (!clientId) {
    throw new Error("coact.nvim Pi edit bridge is missing its execution-unit id.");
  }
  return { addr, nonce, nvim, clientId };
}

function luaSingleQuote(value) {
  return "'" + String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\n/g, "\\n").replace(/\r/g, "\\r") + "'";
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

async function resultFileReady(path) {
  try {
    const info = await stat(path);
    return info.size > 0;
  } catch {
    return false;
  }
}

async function reviewWithNeovim(payload, signal) {
  const { addr, nonce, nvim, clientId } = assertBridgeEnv();
  const dir = await mkdtemp(join(tmpdir(), "coact-nvim-pi-edit-"));
  const payloadPath = join(dir, "payload.json");
  const resultPath = join(dir, "result.json");
  const argsJson = JSON.stringify({ payload: payloadPath, nonce, result: resultPath, clientId });
  const expr =
    "luaeval('require(\"coact.providers.pi_edit_bridge\").review_file_async(_A)', " + luaSingleQuote(argsJson) + ")";

  try {
    await writeFile(payloadPath, JSON.stringify(payload), "utf8");
    const spawned = spawnSync(nvim, ["--server", addr, "--remote-expr", expr], {
      encoding: "utf8",
      input: "",
      stdio: ["pipe", "pipe", "pipe"],
    });
    if (spawned.error) {
      throw spawned.error;
    }
    if (spawned.status !== 0) {
      throw new Error((spawned.stderr || spawned.stdout || "failed to reach the target Neovim RPC server").trim());
    }

    const configured = Number(process.env.COACT_NVIM_PI_EDIT_BRIDGE_TIMEOUT_MS || "600000");
    const timeoutMs = Number.isFinite(configured) && configured > 0 ? configured : 600000;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (signal?.aborted) {
        throw new Error("Operation aborted");
      }
      if (await resultFileReady(resultPath)) {
        const raw = await readFile(resultPath, "utf8");
        return JSON.parse(raw);
      }
      await sleep(100);
    }
    throw new Error("Timed out waiting for Neovim Pi edit review.");
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

function resultSummary(result, fallback) {
  const summary = typeof result?.summary === "string" && result.summary.trim() ? result.summary : fallback;
  if (result?.success) {
    return summary;
  }
  return "Neovim patch review did not apply all proposed changes.\n\n" + summary;
}

function editDetails(result) {
  return {
    diff: result?.diff || "",
    patch: result?.patch || result?.diff || "",
    firstChangedLine: result?.firstChangedLine,
  };
}

async function readExistingFile(path) {
  const raw = await readFile(path, "utf8");
  const stripped = stripBom(raw);
  return normalizeToLF(stripped.text);
}

function textContent(content) {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return "";
  }
  return content
    .map((block) => {
      if (!block || typeof block !== "object") {
        return "";
      }
      if (block.type === "text") {
        return block.text || "";
      }
      if (block.type === "thinking") {
        return block.thinking || "";
      }
      if (block.type === "image") {
        return "[image]";
      }
      if (block.type === "toolCall") {
        return "[" + (block.name || "tool") + " tool call]";
      }
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

function entryEditorText(entry) {
  if (!entry || typeof entry !== "object") {
    return undefined;
  }
  if (entry.type === "message" && entry.message?.role === "user") {
    return textContent(entry.message.content);
  }
  if (entry.type === "custom_message") {
    return textContent(entry.content);
  }
  return undefined;
}

// Only picker metadata crosses RPC: no recursive children, images, thinking,
// full tool results, retained compaction tails, or arbitrary extension data.
function treeTextContent(content) {
  if (typeof content === "string") return content.slice(0, 2000);
  return (Array.isArray(content) ? content : [])
    .filter((block) => block?.type === "text")
    .map((block) => String(block.text || "").slice(0, 2000)).join("").slice(0, 2000);
}

function treePickerNodes(roots) {
  const nodes = [];
  const entriesById = new Map();
  const stack = [...roots].reverse();
  while (stack.length) {
    const node = stack.pop();
    const source = node.entry;
    entriesById.set(String(source.id), source);
    const entry = {};
    for (const key of ["id", "parentId", "type", "timestamp", "customType", "display",
      "tokensBefore", "modelId", "thinkingLevel", "name", "label"]) {
      if (source[key] != null) entry[key] = source[key];
    }
    if (source.summary !== undefined) entry.summary = String(source.summary).slice(0, 2000);
    if (source.content !== undefined) entry.content = treeTextContent(source.content);
    if (source.message) {
      const message = source.message;
      entry.message = {};
      for (const key of ["role", "stopReason", "toolCallId", "toolName", "isError"]) {
        if (message[key] != null) entry.message[key] = message[key];
      }
      for (const key of ["command", "errorMessage"]) {
        if (message[key] !== undefined) entry.message[key] = String(message[key]).slice(0, 2000);
      }
      entry.message.content = [{ type: "text", text: treeTextContent(message.content) }];
      for (const block of Array.isArray(message.content) ? message.content : []) {
        if (block.type !== "toolCall") continue;
        const args = block.arguments || block.args || {};
        const argumentsPreview = {};
        for (const key of ["path", "file_path", "offset", "limit", "command", "pattern"]) {
          if (typeof args[key] === "string") argumentsPreview[key] = args[key].slice(0, 2000);
          else if (typeof args[key] === "number") argumentsPreview[key] = args[key];
        }
        entry.message.content.push({ type: "toolCall", id: block.id ?? block.toolCallId,
          name: block.name, arguments: argumentsPreview });
      }
    }
    nodes.push({ entry, label: node.label });
    const children = node.children || [];
    for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
  }
  return { nodes, entriesById };
}

function parseTreeArgs(args) {
  const raw = String(args || "").trim();
  if (!raw) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return { initialSelectedId: raw };
  }
}

function treeAction(action, id, extra = {}) {
  return {
    __coactNvimPiTreeAction: true,
    action,
    id,
    ...extra,
  };
}

function normalizeTreeSelection(selection) {
  if (selection && typeof selection === "object" && selection.__coactNvimPiTreeAction) {
    const id = selection.id ?? selection.entryId ?? selection.entry_id;
    return {
      action: selection.action || "navigateTree",
      id: id === undefined || id === null ? undefined : String(id),
      fallbackReason: selection.fallbackReason ?? selection.fallback_reason,
    };
  }
  if (selection === undefined || selection === null || selection === "") {
    return { action: "cancel" };
  }
  return { action: "navigateTree", id: String(selection) };
}

function branchSnapshotPayload(ctx) {
  const branch = typeof ctx.sessionManager.buildContextEntries === "function"
    ? ctx.sessionManager.buildContextEntries()
    : ctx.sessionManager.getBranch();
  const entries = (branch || [])
    .map((entry) => {
      if (entry?.type === "message" && (entry.message?.role === "user" || entry.message?.role === "assistant")) {
        return {
          id: String(entry.id),
          parentId: entry.parentId ?? undefined,
          role: entry.message.role,
          text: textContent(entry.message.content),
          timestamp: entry.timestamp,
        };
      }
      if (entry?.type === "branch_summary") {
        return {
          id: String(entry.id),
          parentId: entry.parentId ?? undefined,
          role: "branchSummary",
          text: String(entry.summary ?? ""),
          timestamp: entry.timestamp,
          fromId: entry.fromId,
        };
      }
      if (entry?.type === "compaction") {
        return {
          id: String(entry.id),
          parentId: entry.parentId ?? undefined,
          role: "compactionSummary",
          text: String(entry.summary ?? ""),
          timestamp: entry.timestamp,
          tokensBefore: entry.tokensBefore,
        };
      }
      return undefined;
    })
    .filter(Boolean);
  return {
    __coactNvimPiBranchSnapshot: true,
    leafId: ctx.sessionManager.getLeafId(),
    entries,
  };
}

async function handleBranchSnapshotCommand(ctx) {
  await ctx.ui.select("Coact Pi branch snapshot", [branchSnapshotPayload(ctx)]);
}

async function handleTreeCommand(args, ctx) {
  await ctx.waitForIdle();
  const parsedArgs = parseTreeArgs(args);
  const initialSelectedId = parsedArgs.initialSelectedId ? String(parsedArgs.initialSelectedId) : undefined;
  const tree = ctx.sessionManager.getTree() || [];
  if (!tree.length) {
    ctx.ui.notify("No entries in session", "warning");
    return treeAction("cancel");
  }

  const leafId = ctx.sessionManager.getLeafId();
  const branchIds = new Set(ctx.sessionManager.getBranch().map((entry) => entry.id));
  const { nodes, entriesById } = treePickerNodes(tree);
  const selection = normalizeTreeSelection(await ctx.ui.select("Pi session tree", [
    {
      __coactNvimPiTree: true,
      nodes,
      leafId,
      activePathIds: Array.from(branchIds),
      initialSelectedId,
    },
  ]));
  if (selection.action === "cancel" || !selection.id) {
    ctx.ui.notify("Tree navigation cancelled", "info");
    return treeAction("cancel", selection.id);
  }
  if (selection.action === "reveal") {
    ctx.ui.notify("Revealed selected point in Neovim", "info");
    return treeAction("reveal", selection.id);
  }
  const target = entriesById.get(String(selection.id));
  if (!target) {
    ctx.ui.notify("Tree navigation target not found", "error");
    return treeAction("cancel", selection.id, { fallbackReason: "target not found" });
  }
  if (target.id === leafId) {
    ctx.ui.notify("Already at this point", "info");
    return treeAction("noop", target.id);
  }

  let summarize = false;
  let customInstructions;
  const summaryChoice = await ctx.ui.select("Summarize branch?", [
    "No summary",
    "Summarize",
    "Summarize with custom prompt",
  ]);
  if (!summaryChoice) {
    ctx.ui.notify("Tree navigation cancelled", "info");
    return treeAction("cancel", target.id);
  }
  summarize = summaryChoice !== "No summary";
  if (summaryChoice === "Summarize with custom prompt") {
    customInstructions = await ctx.ui.editor("Custom summarization instructions");
    if (customInstructions === undefined) {
      ctx.ui.notify("Tree navigation cancelled", "info");
      return treeAction("cancel", target.id);
    }
  }

  const editorText = entryEditorText(target);
  if (summarize) {
    ctx.ui.setStatus(treeSummaryStatusKey, "summarizing");
  }
  let result;
  try {
    result = await ctx.navigateTree(target.id, { summarize, customInstructions });
  } finally {
    if (summarize) {
      ctx.ui.setStatus(treeSummaryStatusKey, undefined);
    }
  }
  if (result?.cancelled) {
    ctx.ui.notify("Tree navigation cancelled", "warning");
    return treeAction("cancel", target.id);
  }
  if (editorText !== undefined) {
    ctx.ui.setEditorText(editorText);
  }
  ctx.ui.notify("Navigated to selected point", "info");
  return treeAction("navigateTree", target.id);
}

export default function (pi) {
  pi.registerCommand("coact-nvim-tree", {
    description: "Navigate the current session tree from coact.nvim",
    handler: async (args, ctx) => {
      return await handleTreeCommand(args, ctx);
    },
  });

  pi.registerCommand("coact-nvim-branch-snapshot", {
    description: "Synchronize Pi session tree entry ids with coact.nvim",
    handler: async (_args, ctx) => {
      await handleBranchSnapshotCommand(ctx);
    },
  });

  pi.registerTool({
    name: "edit",
    label: "edit",
    description:
      "Edit a single file using exact text replacement. coact.nvim opens the proposed changes in Neovim for interactive approval before anything is written.",
    promptSnippet: "Make precise, small cooperative file edits with exact text replacement, reviewed by coact.nvim in Neovim before write",
    promptGuidelines: [
      "Direct file edits happen inside the user's active editing environment; treat it as a user-owned, in-progress workspace.",
      "Default to small cooperative deltas: continue the user's current partial work, refine a local block, fill a narrow TODO or stub, or add lightweight scaffolding that helps the user continue.",
      "Edit the smallest useful region, make one conceptual change at a time, and preserve the user's structure, naming, style, and unfinished intent.",
      "Avoid autonomous bulk generation: do not replace the user's structure, generate large modules, perform broad rewrites, or make multi-file implementations unless explicitly requested.",
      "If a useful change seems large or architectural, first split it into small slices, explain the next proposed slice, and ask before applying it.",
      "After applying a meaningful edit, stop and return control to the user instead of continuing to generate more changes.",
      "Use edit for precise changes (edits[].oldText must match exactly).",
      "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls.",
      "Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits.",
    ],
    parameters: editSchema,
    prepareArguments: prepareEditArguments,
    executionMode: "sequential",

    async execute(toolCallId, params, signal, _onUpdate, ctx) {
      const { path, edits } = params;
      if (!Array.isArray(edits) || edits.length === 0) {
        throw new Error("Edit tool input is invalid. edits must contain at least one replacement.");
      }
      const cwd = ctx?.cwd || process.cwd();
      const absolutePath = resolve(cwd, path);
      await access(absolutePath, constants.R_OK);
      const oldContent = await readExistingFile(absolutePath);
      const { baseContent, newContent } = applyEditsToNormalizedContent(oldContent, edits, path);
      const result = await reviewWithNeovim(
        {
          toolName: "edit",
          toolCallId,
          cwd,
          path,
          absolutePath,
          oldContent: baseContent,
          newContent,
          kind: "update",
        },
        signal,
      );
      if (!result?.success) {
        throw new Error(resultSummary(result, "Edit rejected in Neovim."));
      }
      return {
        content: [{ type: "text", text: resultSummary(result, "Successfully reviewed and applied edit to " + path + ".") }],
        details: editDetails(result),
      };
    },
  });

  pi.registerTool({
    name: "write",
    label: "write",
    description:
      "Write content to a file. coact.nvim opens the proposed create/overwrite change in Neovim for interactive approval before anything is written.",
    promptSnippet: "Create or overwrite files, reviewed by coact.nvim in Neovim before write",
    promptGuidelines: ["Use write only for new files or complete rewrites."],
    parameters: writeSchema,
    executionMode: "sequential",

    async execute(toolCallId, { path, content }, signal, _onUpdate, ctx) {
      const cwd = ctx?.cwd || process.cwd();
      const absolutePath = resolve(cwd, path);
      let oldContent = "";
      let kind = "add";
      try {
        oldContent = await readExistingFile(absolutePath);
        kind = "update";
      } catch (error) {
        if (!error || error.code !== "ENOENT") {
          throw error;
        }
        const dir = dirname(absolutePath);
        await access(dir, constants.W_OK).catch(() => {});
      }
      const result = await reviewWithNeovim(
        {
          toolName: "write",
          toolCallId,
          cwd,
          path,
          absolutePath,
          oldContent,
          newContent: normalizeToLF(content),
          kind,
        },
        signal,
      );
      if (!result?.success) {
        throw new Error(resultSummary(result, "Write rejected in Neovim."));
      }
      return {
        content: [{ type: "text", text: resultSummary(result, "Successfully reviewed and wrote " + content.length + " bytes to " + path + ".") }],
        details: undefined,
      };
    },
  });
}
]=]
end

local function ensure_extension_path()
  if extension_path and vim.fn.filereadable(extension_path) == 1 then
    return extension_path
  end
  local tmpdir = trim_trailing_slash(vim.env.TMPDIR or "/tmp")
  local path = vim.fn.tempname() .. "-coact-nvim-pi-edit-bridge.ts"
  if not path:match("^/") then
    path = vim.fs.joinpath(tmpdir, path)
  end
  local ok, err = pcall(vim.fn.writefile, vim.split(extension_source(), "\n", { plain = true }), path)
  if not ok or (err ~= 0 and err ~= nil) then
    return nil, "failed to write Pi edit bridge extension: " .. tostring(err)
  end
  extension_path = path
  return extension_path
end

function M.setup()
  configured_options = config.get()
  direct_write_enabled = false
  direct_write_allowlist = nil

  local setting = bridge_opts().direct_write
  if setting ~= nil and type(setting) ~= "boolean" and type(setting) ~= "function" then
    error("providers.pi.edit_bridge.direct_write must be true, false, or a function", 0)
  end
  if setting == false then
    return
  end

  local context = direct_write_context()
  local builder = directory_allowlist.new({ base = context.cwd })
  run_direct_write_configurator(
    "default temp-directory initializer",
    configure_system_temp_direct_write,
    builder,
    context
  )
  if type(setting) == "function" then
    run_direct_write_configurator("callback", setting, builder, context)
  end

  direct_write_allowlist = directory_allowlist.new({ base = context.cwd })
  direct_write_allowlist:add(builder:paths())
  direct_write_enabled = true
end

function M.prepare_command(command, env, launch)
  ensure_direct_write_allowlist()
  if not enabled() then
    return command, env
  end
  local address, address_err = ensure_server_address()
  if not address then
    return nil, nil, "failed to start Neovim RPC server for Pi edit bridge: " .. tostring(address_err)
  end
  local path, path_err = ensure_extension_path()
  if not path then
    return nil, nil, path_err
  end
  env = env or {}
  env.COACT_NVIM_PI_EDIT_BRIDGE_ADDR = address
  env.COACT_NVIM_PI_EDIT_BRIDGE_NONCE = ensure_nonce()
  env.COACT_NVIM_PI_CLIENT_ID = launch and launch.client_id or env.COACT_NVIM_PI_CLIENT_ID or "pi-legacy"
  env.COACT_NVIM_PI_EDIT_BRIDGE_NVIM = ensure_nvim_bin()
  env.COACT_NVIM_PI_EDIT_BRIDGE_TIMEOUT_MS = tostring(timeout_ms())
  return append_command_args(command, { "--extension", path }), env
end

local function read_payload(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "failed to read Pi edit bridge payload: " .. tostring(lines)
  end
  local ok_decode, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(payload) ~= "table" then
    return nil, "failed to decode Pi edit bridge payload: " .. tostring(payload)
  end
  return payload
end

local function write_result(path, result)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local ok, encoded = pcall(vim.json.encode, result or {})
  if not ok then
    encoded = vim.json.encode({
      success = false,
      summary = "failed to encode Pi edit bridge result: " .. tostring(encoded),
    })
  end
  local ok_write = pcall(vim.fn.writefile, { encoded }, path)
  return ok_write
end

local function parse_args(args)
  if type(args) == "string" then
    local ok, decoded = pcall(vim.json.decode, args)
    if ok and type(decoded) == "table" then
      return decoded
    end
    return { payload = args }
  end
  return type(args) == "table" and args or {}
end

local function normalize_text(value)
  value = tostring(value or "")
  value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
  return value
end

local function absolute_path(cwd, path)
  path = util.value(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fn.expand(path)
  if path:match("^/") or path:match("^%a:[/\\]") or path:match("^[/\\][/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(cwd or config.cwd(), path))
end

local function direct_write_allowed(cwd, path)
  ensure_direct_write_allowlist()
  if not direct_write_enabled or not direct_write_allowlist then
    return false
  end
  local absolute = absolute_path(cwd, path)
  return absolute ~= nil and direct_write_allowlist:contains(absolute)
end

local function relative_path(cwd, path)
  local absolute = absolute_path(cwd, path)
  if not absolute then
    return tostring(path or "")
  end
  cwd = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  if absolute == cwd then
    return vim.fn.fnamemodify(absolute, ":t")
  end
  local prefix = cwd:gsub("/+$", "") .. "/"
  if absolute:sub(1, #prefix) == prefix then
    return absolute:sub(#prefix + 1)
  end
  return vim.fn.fnamemodify(absolute, ":.")
end

local function first_changed_line(diff)
  local old_line = nil
  local new_line = nil
  for _, line in ipairs(util.split_lines(diff or "")) do
    local old_start, new_start = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if old_start and new_start then
      old_line = tonumber(old_start)
      new_line = tonumber(new_start)
    elseif new_line then
      local prefix = line:sub(1, 1)
      if prefix == " " then
        old_line = old_line + 1
        new_line = new_line + 1
      elseif prefix == "-" then
        return new_line
      elseif prefix == "+" then
        return new_line
      end
    end
  end
  return nil
end

local function build_patch(cwd, payload)
  local path = util.value(payload.path) or util.value(payload.absolutePath)
  if not path or path == "" then
    return nil, nil, "Pi edit bridge payload did not include a path."
  end
  local old_text = normalize_text(payload.oldContent)
  local new_text = normalize_text(payload.newContent)
  local hunks = vim.diff(old_text, new_text, {
    result_type = "unified",
    ctxlen = 4,
  }) or ""
  if util.trim(hunks) == "" then
    return "", {
      kind = payload.kind or "update",
      path = path,
      diff = "",
    }, nil
  end
  local rel = relative_path(cwd, path)
  local kind = payload.kind or "update"
  if kind ~= "add" and kind ~= "delete" then
    kind = "update"
  end
  local old_label = kind == "add" and "/dev/null" or ("a/" .. rel)
  local new_label = kind == "delete" and "/dev/null" or ("b/" .. rel)
  local patch = table.concat({
    "diff --git a/" .. rel .. " b/" .. rel,
    "--- " .. old_label,
    "+++ " .. new_label,
    hunks:gsub("\n+$", ""),
  }, "\n")
  return patch, {
    kind = kind,
    path = path,
    diff = patch,
  }, nil
end

local function payload_thread_id(payload)
  local client_id = util.value(payload.__coactClientId or payload.clientId or payload.client_id)
  if client_id then
    local ok, pi_rpc = pcall(require, "coact.providers.pi_rpc")
    local thread_id = ok and pi_rpc.thread_id_for_client(client_id) or nil
    if thread_id then
      return thread_id
    end
    return nil
  end
  local explicit = util.value(payload.threadId) or util.value(payload.thread_id)
  if explicit then
    return explicit
  end
  local ok, pi = pcall(require, "coact.providers.pi")
  if ok and pi._runtime and pi._runtime.current_thread_id then
    return pi._runtime.current_thread_id
  end
  return require("coact.state").active_thread_id
end

function M.review_payload_async(payload, done)
  done = type(done) == "function" and done or function() end
  payload = type(payload) == "table" and payload or {}
  local cwd = util.value(payload.cwd) or config.cwd()
  local thread_id = payload_thread_id(payload)
  if util.value(payload.__coactClientId or payload.clientId or payload.client_id) and not thread_id then
    done({
      success = false,
      summary = "Rejected Pi edit bridge request from a stale execution unit.",
    })
    return
  end
  local patch, change, err = build_patch(cwd, payload)
  if not patch then
    done({
      success = false,
      summary = err or "Pi edit bridge could not build a patch.",
    })
    return
  end
  if patch == "" then
    done({
      success = true,
      summary = "No file changes to review.",
      noChange = true,
      diff = "",
      patch = "",
    })
    return
  end

  vim.schedule(function()
    local interactive = not direct_write_allowed(cwd, change.path)
    local session, open_err = require("coact.patch_session").open({
      request_id = util.value(payload.toolCallId) or util.value(payload.tool_call_id) or tostring(vim.uv.hrtime()),
      thread_id = thread_id,
      cwd = cwd,
      changes = { change },
      diagnostics_settle_ms = (config.get().edit or {}).diagnostics_settle_ms,
      interactive = interactive,
      on_complete = function(summary, success, session_result)
        done({
          success = success,
          summary = summary,
          diff = patch,
          patch = patch,
          firstChangedLine = first_changed_line(patch),
          acceptedBlocks = session_result and session_result.accepted_blocks,
          rejectedBlocks = session_result and session_result.rejected_blocks,
          acceptedHunks = session_result and session_result.accepted_hunks,
          rejectedHunks = session_result and session_result.rejected_hunks,
          writeOk = session_result and session_result.write_ok,
          writeError = session_result and session_result.write_error,
        })
      end,
    })
    if not session then
      done({
        success = false,
        summary = "Neovim Pi edit review could not be opened: " .. tostring(open_err),
        diff = patch,
        patch = patch,
        firstChangedLine = first_changed_line(patch),
      })
    end
  end)
end

function M.review_file_async(args)
  args = parse_args(args)
  local result_path = args.result
  local function finish(result)
    write_result(result_path, result)
  end
  if nonce and args.nonce ~= nonce then
    finish({
      success = false,
      summary = "Rejected Pi edit bridge request with invalid Neovim nonce.",
    })
    return "queued"
  end
  local payload, err = read_payload(args.payload)
  if not payload then
    finish({
      success = false,
      summary = err,
    })
    return "queued"
  end
  payload.__coactClientId = util.value(args.clientId or args.client_id)
  local ok, async_err = pcall(M.review_payload_async, payload, finish)
  if not ok then
    finish({
      success = false,
      summary = "Neovim Pi edit bridge failed: " .. tostring(async_err),
    })
  end
  return "queued"
end

function M.enabled()
  return enabled()
end

function M.runtime_config()
  if not enabled() then
    return nil
  end
  return {
    extension_path = extension_path,
    server_address = server_address,
    nvim_bin = nvim_bin,
    timeout_ms = timeout_ms(),
  }
end

function M._extension_source()
  return extension_source()
end

M._payload_thread_id = payload_thread_id

function M._build_patch(cwd, payload)
  return build_patch(cwd, payload)
end

return M
