local config = require("coact.config")

local M = {
  name = "claude",
  title = "Claude Code",
  agent_label = "Claude",
  protocol = "claude-stream-json",
  transport = "coact.providers.claude_rpc",
  catalog_scope = "thread",
  transport_scope = "thread",
  thread_list_requires_transport = false,
  supports_follow_up = true,
  tree = { title = "Claude rewind history", action = "rewind" },
  slash = {
    commands = {
      behavior = true,
      clear = true,
      copy = true,
      diff = true,
      help = true,
      new = true,
      resume = true,
      tree = true,
      model = true,
      compact = true,
      skills = true,
      raw = true,
      statusline = true,
      stop = true,
    },
  },
}

function M.options()
  return config.get().adapter or {}
end

function M.command(_, launch)
  launch = launch or {}
  local opts = M.options()
  local cmd = vim.deepcopy(opts.command or { "claude" })
  assert(type(cmd) == "table" and type(cmd[1]) == "string", "providers.claude.command must be an argv list")
  vim.list_extend(cmd, opts.extra_args or {})
  vim.list_extend(cmd, {
    "--print",
    "--verbose",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--include-partial-messages",
    "--replay-user-messages",
    "--permission-prompt-tool",
    "stdio",
    "--mcp-config",
    vim.json.encode({ mcpServers = { coact = { type = "sdk", name = "coact" } } }),
  })
  if launch.resume then
    table.insert(cmd, "--resume=" .. launch.resume)
    if launch.fork then
      table.insert(cmd, "--fork-session")
    end
    if launch.resume_at then
      table.insert(cmd, "--resume-session-at=" .. launch.resume_at)
    end
  end
  if launch.session_id and (not launch.resume or launch.fork) then
    table.insert(cmd, "--session-id=" .. launch.session_id)
  end
  local model = launch.model or opts.model
  if model then
    vim.list_extend(cmd, { "--model", model })
  end
  local instructions = launch.instructions or ""
  if config.edit_mode() == "pair" then
    -- Bash is deliberately available: pair mode is a collaboration policy,
    -- not a sandbox. Keep native edits out of the surface to prefer review.
    vim.list_extend(cmd, { "--tools", "Read,Glob,Grep,Bash,Skill", "--strict-mcp-config" })
    instructions = instructions
      .. "\nUse mcp__coact__edit for precise file changes and mcp__coact__openDiff for new files or full rewrites, including paths outside the workspace. Both write accepted changes after Neovim review. Use Bash for tests, builds, and inspection; do not use shell writes to bypass review. Bash is available but is not a write sandbox."
  end
  if instructions ~= "" then
    vim.list_extend(cmd, { "--append-system-prompt", instructions })
  end
  return cmd
end

function M.skill_catalog(thread)
  local backend = require("coact.providers.claude_rpc")
  local client = backend.catalog_client(thread and thread.id)
  return client and require("coact.providers.claude_catalog").skills(client) or {}
end

function M.executable()
  return M.command()[1]
end

function M.command_label()
  return "Claude Code stream-json"
end

function M.health(_, health)
  health.info("active provider: claude (bidirectional stream-json + SDK MCP)")
  local executable = M.executable()
  if vim.fn.executable(executable) == 1 then
    health.ok("Claude Code executable found: " .. executable)
  else
    health.error("Claude Code executable not found: " .. executable)
  end
end

return M
