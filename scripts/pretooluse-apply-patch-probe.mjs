#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const codexBin = process.env.CODEX_BIN || "codex";
const keep = process.env.KEEP_COACT_NVIM_PROBE === "1";
const hookDecision = process.env.PROBE_HOOK_DECISION || "allow";
const hookSource = process.env.PROBE_HOOK_SOURCE || "config";
const rejectReason =
  process.env.PROBE_REJECT_REASON ||
  "User rejected in Neovim: probe rejection reason";

if (!["allow", "deny"].includes(hookDecision)) {
  throw new Error(`unsupported PROBE_HOOK_DECISION: ${hookDecision}`);
}
if (!["config", "cli"].includes(hookSource)) {
  throw new Error(`unsupported PROBE_HOOK_SOURCE: ${hookSource}`);
}

function sse(events) {
  return events
    .map((event) => {
      const kind = event.type;
      const data = Object.keys(event).length === 1 ? "" : `data: ${JSON.stringify(event)}\n`;
      return `event: ${kind}\n${data}\n`;
    })
    .join("");
}

function evResponseCreated(id) {
  return { type: "response.created", response: { id } };
}

function evCompleted(id) {
  return {
    type: "response.completed",
    response: {
      id,
      usage: {
        input_tokens: 0,
        input_tokens_details: null,
        output_tokens: 0,
        output_tokens_details: null,
        total_tokens: 0,
      },
    },
  };
}

function evApplyPatch(callId, patch) {
  return {
    type: "response.output_item.done",
    item: {
      type: "custom_tool_call",
      name: "apply_patch",
      input: patch,
      call_id: callId,
    },
  };
}

function evAssistantMessage(id, text) {
  return {
    type: "response.output_item.done",
    item: {
      type: "message",
      role: "assistant",
      id,
      content: [{ type: "output_text", text }],
    },
  };
}

function tomlQuote(value) {
  return JSON.stringify(String(value));
}

function hookStateKeyPath(key) {
  return `hooks.state.${tomlQuote(key)}.trusted_hash`;
}

async function trustApplyPatchHook(rpc, workspace, hookCommand) {
  const before = await rpc.request("hooks/list", { cwds: [workspace] });
  const hooks = before.data?.flatMap((entry) => entry.hooks || []) || [];
  const hook = hooks.find(
    (candidate) =>
      candidate.enabled !== false &&
      candidate.eventName === "preToolUse" &&
      candidate.handlerType === "command" &&
      candidate.matcher === "^apply_patch$" &&
      candidate.command === hookCommand,
  );
  if (!hook) {
    throw new Error(`could not find apply_patch hook in hooks/list: ${JSON.stringify(before, null, 2)}`);
  }
  if (hook.trustStatus !== "trusted" && hook.trustStatus !== "managed") {
    await rpc.request("config/batchWrite", {
      edits: [
        {
          keyPath: hookStateKeyPath(hook.key),
          mergeStrategy: "upsert",
          value: hook.currentHash,
        },
      ],
      reloadUserConfig: true,
    });
  }
  const after = await rpc.request("hooks/list", { cwds: [workspace] });
  const trusted = (after.data?.flatMap((entry) => entry.hooks || []) || []).find(
    (candidate) => candidate.key === hook.key,
  );
  if (!trusted || (trusted.trustStatus !== "trusted" && trusted.trustStatus !== "managed")) {
    throw new Error(`apply_patch hook was not trusted after config write: ${JSON.stringify(after, null, 2)}`);
  }
  return { before: hook.trustStatus, after: trusted.trustStatus, key: hook.key };
}

function startMockResponsesServer(responses, requests) {
  const server = createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      requests.push({ method: req.method, url: req.url, body });

      if (req.method !== "POST" || req.url !== "/v1/responses") {
        res.writeHead(404, { "content-type": "text/plain" });
        res.end("not found");
        return;
      }

      const response = responses.shift();
      if (!response) {
        res.writeHead(500, { "content-type": "text/plain" });
        res.end("no queued response");
        return;
      }

      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "close",
      });
      res.end(response);
    });
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({ server, url: `http://127.0.0.1:${address.port}` });
    });
  });
}

function jsonRpcClient(child) {
  let nextId = 1;
  const pending = new Map();
  const notifications = [];
  const serverRequests = [];
  let tail = "";

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    tail += chunk;
    let newline;
    while ((newline = tail.indexOf("\n")) >= 0) {
      const line = tail.slice(0, newline).trim();
      tail = tail.slice(newline + 1);
      if (!line) continue;

      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        throw new Error(`failed to parse app-server JSON line: ${line}\n${error}`);
      }

      if (Object.prototype.hasOwnProperty.call(message, "id") && !message.method) {
        const entry = pending.get(message.id);
        if (entry) {
          pending.delete(message.id);
          if (message.error) entry.reject(message.error);
          else entry.resolve(message.result);
        }
        continue;
      }

      if (Object.prototype.hasOwnProperty.call(message, "id") && message.method) {
        serverRequests.push(message);
        if (message.method === "item/fileChange/requestApproval") {
          respond(message.id, { decision: "accept" });
        } else {
          respond(message.id, {
            code: -32601,
            message: `probe does not handle server request ${message.method}`,
          });
        }
        continue;
      }

      notifications.push(message);
    }
  });

  child.stderr.setEncoding("utf8");
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  function send(message) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  function request(method, params) {
    const id = nextId++;
    send({ id, method, params });
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
    });
  }

  function notify(method, params = {}) {
    send({ method, params });
  }

  function respond(id, result) {
    send({ id, result });
  }

  function waitForNotification(method, predicate = () => true, timeoutMs = 20000) {
    const started = Date.now();
    return new Promise((resolve, reject) => {
      const timer = setInterval(() => {
        for (const notification of notifications) {
          if (notification.method === method && predicate(notification.params || {})) {
            clearInterval(timer);
            resolve(notification.params || {});
            return;
          }
        }
        if (Date.now() - started > timeoutMs) {
          clearInterval(timer);
          reject(new Error(`timed out waiting for ${method}; stderr:\n${stderr}`));
        }
      }, 25);
    });
  }

  return { request, notify, waitForNotification, notifications, serverRequests, stderr: () => stderr };
}

async function main() {
  const root = await mkdtemp(join(tmpdir(), "coact-nvim-pretooluse-"));
  const codexHome = join(root, "codex-home");
  const workspace = join(root, "workspace");
  await mkdir(codexHome, { recursive: true });
  await mkdir(workspace, { recursive: true });

  const originalPatch = [
    "*** Begin Patch",
    "*** Add File: original.txt",
    "+original",
    "*** End Patch",
  ].join("\n");
  const rewrittenPatch = [
    "*** Begin Patch",
    "*** Add File: rewritten.txt",
    "+rewritten",
    "*** End Patch",
  ].join("\n");
  const callId = "probe-apply-patch-call";
  const hookLog = join(codexHome, "pre_tool_use_hook_log.jsonl");
  const hookScript = join(codexHome, "pre_tool_use_hook.mjs");

  const requests = [];
  const { server, url } = await startMockResponsesServer(
    [
      sse([evResponseCreated("resp-1"), evApplyPatch(callId, originalPatch), evCompleted("resp-1")]),
      sse([evResponseCreated("resp-2"), evAssistantMessage("msg-1", "done"), evCompleted("resp-2")]),
    ],
    requests,
  );

  await writeFile(
    join(codexHome, "config.toml"),
    [
      'model = "gpt-5.5"',
      'model_provider = "mock"',
      "",
      "[model_providers.mock]",
      'name = "Mock Responses"',
      `base_url = "${url}/v1"`,
      'env_key = "OPENAI_API_KEY"',
      'wire_api = "responses"',
      "request_max_retries = 0",
      "stream_max_retries = 0",
      "stream_idle_timeout_ms = 10000",
      "",
    ].join("\n"),
  );

  await writeFile(
    hookScript,
    [
      "#!/usr/bin/env node",
      'import { appendFileSync } from "node:fs";',
      `const decision = ${JSON.stringify(hookDecision)};`,
      "const chunks = [];",
      'process.stdin.setEncoding("utf8");',
      'process.stdin.on("data", (chunk) => chunks.push(chunk));',
      'process.stdin.on("end", () => {',
      "  const payload = JSON.parse(chunks.join(''));",
      `  appendFileSync(${JSON.stringify(hookLog)}, JSON.stringify(payload) + "\\n");`,
      '  if (decision === "deny") {',
      "    console.log(JSON.stringify({",
      "      hookSpecificOutput: {",
      '        hookEventName: "PreToolUse",',
      '        permissionDecision: "deny",',
      `        permissionDecisionReason: ${JSON.stringify(rejectReason)},`,
      "      },",
      "    }));",
      "    return;",
      "  }",
      "  console.log(JSON.stringify({",
      "    hookSpecificOutput: {",
      '      hookEventName: "PreToolUse",',
      '      permissionDecision: "allow",',
      `      updatedInput: { command: ${JSON.stringify(rewrittenPatch)} },`,
      '      additionalContext: "probe additional context",',
      "    },",
      "  }));",
      "});",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );

  const hookCommand = `${process.execPath} ${hookScript}`;
  if (hookSource === "config") {
    await writeFile(
      join(codexHome, "hooks.json"),
      JSON.stringify({
        hooks: {
          PreToolUse: [
            {
              matcher: "^apply_patch$",
              hooks: [
                {
                  type: "command",
                  command: hookCommand,
                  timeout: 10,
                  statusMessage: "probing apply_patch hook",
                },
              ],
            },
          ],
        },
      }),
    );
  }

  const hookConfigArg = [
    "hooks.PreToolUse=[{matcher=",
    tomlQuote("^apply_patch$"),
    ",hooks=[{type=",
    tomlQuote("command"),
    ",command=",
    tomlQuote(hookCommand),
    ",timeout=10,statusMessage=",
    tomlQuote("probing apply_patch hook"),
    "}]}]",
  ].join("");
  const appServerArgs =
    hookSource === "cli"
      ? ["app-server", "-c", hookConfigArg, "--listen", "stdio://"]
      : ["app-server", "--listen", "stdio://"];

  const child = spawn(codexBin, appServerArgs, {
    cwd: workspace,
    env: {
      ...process.env,
      CODEX_HOME: codexHome,
      OPENAI_API_KEY: "probe-token",
      RUST_LOG: process.env.RUST_LOG || "error",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const rpc = jsonRpcClient(child);

  try {
    await rpc.request("initialize", {
      clientInfo: {
        name: "coact.nvim-pretooluse-apply-patch-probe",
        title: "coact.nvim PreToolUse apply_patch probe",
        version: "0.1.0",
      },
      capabilities: { experimentalApi: true },
    });
    const hookTrust = await trustApplyPatchHook(rpc, workspace, hookCommand);
    rpc.notify("initialized", {});

    const start = await rpc.request("thread/start", {
      cwd: workspace,
      runtimeWorkspaceRoots: [workspace],
      approvalPolicy: "untrusted",
      sandbox: "workspace-write",
      sessionStartSource: "startup",
    });
    const threadId = start.thread?.id || start.threadId || start.id;
    if (!threadId) {
      throw new Error(`thread/start did not return a thread id: ${JSON.stringify(start)}`);
    }

    await rpc.request("turn/start", {
      threadId,
      input: [{ type: "text", text: "trigger mocked apply_patch" }],
      cwd: workspace,
      runtimeWorkspaceRoots: [workspace],
      approvalPolicy: "untrusted",
      sandboxPolicy: { type: "workspaceWrite", writableRoots: [workspace], networkAccess: true },
    });

    await rpc.waitForNotification("turn/completed", (params) => params.threadId === threadId);

    const hookLogText = await readFile(hookLog, "utf8");
    const hookPayloads = hookLogText
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    let originalExists = true;
    try {
      await readFile(join(workspace, "original.txt"), "utf8");
    } catch {
      originalExists = false;
    }
    let rewritten = null;
    let rewrittenExists = true;
    try {
      rewritten = await readFile(join(workspace, "rewritten.txt"), "utf8");
    } catch {
      rewrittenExists = false;
    }

    const approvals = rpc.serverRequests.filter((request) => request.method === "item/fileChange/requestApproval");
    const hookStarted = rpc.notifications.filter((notification) => notification.method === "hook/started");
    const hookCompleted = rpc.notifications.filter((notification) => notification.method === "hook/completed");

    if (hookPayloads.length !== 1) {
      throw new Error(`expected 1 hook payload, got ${hookPayloads.length}`);
    }
    if (hookPayloads[0].tool_name !== "apply_patch") {
      throw new Error(`hook saw wrong tool: ${hookPayloads[0].tool_name}`);
    }
    if (hookPayloads[0].tool_input?.command !== originalPatch) {
      throw new Error("hook did not receive the original patch");
    }
    if (hookDecision === "allow") {
      if (originalExists) {
        throw new Error("original patch target was created; rewrite did not take effect");
      }
      if (rewritten !== "rewritten\n") {
        throw new Error(`rewritten patch target content mismatch: ${JSON.stringify(rewritten)}`);
      }
      if (approvals.length !== 1) {
        throw new Error(`expected 1 fileChange approval after hook allow, got ${approvals.length}`);
      }
    } else {
      if (originalExists || rewrittenExists) {
        throw new Error("hook denied apply_patch, but a patch target was still created");
      }
      if (approvals.length !== 0) {
        throw new Error(`expected no fileChange approvals after hook deny, got ${approvals.length}`);
      }
    }
    if (requests.length < 2) {
      throw new Error(`expected at least 2 mocked model requests, got ${requests.length}`);
    }
    if (rpc.stderr().includes("dangerously-bypass-hook-trust")) {
      throw new Error(`app-server emitted hook trust bypass warning:\n${rpc.stderr()}`);
    }

    console.log(
      JSON.stringify(
        {
          ok: true,
          hookDecision,
          hookSource,
          hookTrust,
          workspace,
          codexHome,
          hookPayloads: hookPayloads.length,
          approvals: approvals.map((request) => ({
            id: request.id,
            method: request.method,
            itemId: request.params?.itemId,
          })),
          hookStarted: hookStarted.length,
          hookCompleted: hookCompleted.length,
          rewrittenContent: rewritten,
          originalCreated: originalExists,
          rewrittenCreated: rewrittenExists,
          modelRequests: requests.length,
        },
        null,
        2,
      ),
    );
  } finally {
    child.kill();
    server.close();
    if (!keep) {
      await rm(root, { recursive: true, force: true });
    }
  }
}

main().catch((error) => {
  if (error?.stack) {
    console.error(error.stack);
  } else {
    console.error(JSON.stringify(error, null, 2));
  }
  process.exit(1);
});
