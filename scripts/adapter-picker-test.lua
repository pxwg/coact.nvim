-- Run remotely: deterministic Pi/Claude JSONL peers + native Codex lifecycle.
-- Codex is only started/read here; no model generation is requested.
local coact = require("coact")
local config = require("coact.config")
local state = require("coact.state")
local rpc = require("coact.rpc")
local providers = require("coact.providers")
local root = vim.fn.getcwd()
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace .. "/codex", "p")
coact.setup({
  default_adapter = "pi_work",
  edit = { mode = "yolo" },
  adapters = {
    pi = {
      command = { "node", root .. "/scripts/pi-transcript-rpc-fixture.mjs" },
      picker_prewarm = false,
      edit_bridge = { enabled = false },
      nvim_tools = { enabled = false },
    },
    claude = {
      command = { "node", root .. "/scripts/claude-rpc-fixture.mjs" },
      config_dir = workspace .. "/claude",
    },
    pi_work = {
      provider = "pi",
      command = { "node", root .. "/scripts/pi-transcript-rpc-fixture.mjs" },
      extra_args = { "--fixture-work" },
      env = { COACT_PROFILE = "work" },
      picker_prewarm = false,
      model_provider = "fixture-api",
      edit_bridge = { enabled = false },
      nvim_tools = { enabled = false },
    },
    codex = {
      provider = "codex",
      extra_args = { "-c", "model=fixture" },
      env = { COACT_PROFILE = "codex", CODEX_HOME = workspace .. "/codex" },
    },
  },
})
local function in_adapter(name, callback)
  return config.with_context(config.resolve_adapter(name), callback)
end
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source, workspace .. "/source.lua")
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "local source = true" })
vim.api.nvim_set_current_buf(source)
assert(config.selected_adapter().name == "pi_work")
assert(config.root().default_adapter == "pi_work")
assert(config.resolve_adapter("pi_work") == config.resolve_adapter(config.root().default_adapter))
assert(not pcall(config.resolve_adapter, "missing"))
for _, key in ipairs({ "provider", "providers", "app_server" }) do
  local ok, err = pcall(config.setup, { [key] = key == "provider" and "pi" or {} })
  assert(not ok and tostring(err):match("was removed"), "legacy config must fail with migration guidance")
  assert(config.root()[key] == nil, "legacy keys must not remain in public defaults")
  assert(config.selected_adapter().name == "pi_work", "invalid setup must not replace the active config")
end
in_adapter("codex", function()
  local command = providers.current().command(config.get())
  assert(command[#command] == "model=fixture")
  assert(providers.current().env(config.get(), {}).COACT_PROFILE == "codex")
end)
in_adapter("pi_work", function()
  assert(providers.current().env(config.get(), {}).COACT_PROFILE == "work")
  local command = providers.current().command(config.get())
  local provider_index = vim.fn.index(command, "--provider") + 1
  assert(
    provider_index > 0 and command[provider_index + 1] == "fixture-api",
    "adapter protocol and Pi model provider must be separate"
  )
  state.set_cache("profile", "work")
end)
in_adapter("pi", function()
  assert(state.get_cache("profile") == nil, "catalog caches must be adapter scoped")
  assert(not vim.tbl_contains(providers.current().command(config.get()), "--fixture-work"))
end)
local bound = in_adapter("pi_work", function()
  return config.bind(function()
    return config.context().name, nil, "tail"
  end)
end)
config.select_adapter("codex")
local name, hole, tail = bound()
assert(name == "pi_work" and hole == nil and tail == "tail")
assert(config.context().name == "codex")
assert(not pcall(function()
  in_adapter("pi", function()
    error("scope restoration")
  end)
end))
assert(config.context().name == "codex")

-- Both picker backends keep an empty query and the configured default first.
local saved_snacks = package.loaded.snacks
local picker_opts
package.loaded.snacks = { picker = {
  pick = function(opts)
    picker_opts = opts
  end,
} }
coact.pick_adapter({ action = "new" })
assert(picker_opts.items[1].name == "pi_work")
assert(picker_opts.pattern == nil and picker_opts.search == nil)
assert(#picker_opts.items == 4)
local closed = false
picker_opts.confirm({
  close = function()
    closed = true
  end,
}, nil)
vim.wait(20, function()
  return false
end)
assert(closed and config.selected_adapter().name == "codex", "cancel must not change selection")
local saved_select = vim.ui.select
local saved_new = coact.new_thread
local called
coact.new_thread = function(opts)
  called = { opts = opts, adapter = config.context().name }
end
package.loaded.snacks = { picker = false }
vim.ui.select = function(items, opts, callback)
  assert(items[1].name == "pi_work")
  assert(opts.prompt == "Coact adapter")
  callback(items[1])
end
coact.pick_adapter({ action = "new", prompt = "initial" })
assert(called.adapter == "pi_work" and called.opts.source_bufnr == source)
assert(called.opts.prompt == "initial")
assert(config.root().default_adapter == "pi_work", "selection must not rewrite the default reference")
coact.new_thread, vim.ui.select, package.loaded.snacks = saved_new, saved_select, saved_snacks

local function run()
  -- Launch from the previous agent's chat without waiting between profiles.
  -- Explicit selection must beat buffer focus; callbacks must retain ownership.
  vim.api.nvim_set_current_buf(source)
  for _, adapter in ipairs({ "pi", "pi_work", "claude", "codex" }) do
    coact.new_thread({ adapter = adapter, cwd = workspace, source_bufnr = source })
  end
  vim.api.nvim_set_current_buf(source)
  config.select_adapter("codex")
  local threads = {}
  assert(
    vim.wait(15000, function()
      for _, thread in pairs(state.threads) do
        if thread.adapter_context and thread.lifecycle == "ready" then
          threads[thread.adapter_context.name] = thread
        end
      end
      return threads.pi and threads.pi_work and threads.claude and threads.codex
    end, 10),
    "mixed adapter startup timed out"
  )
  assert(rpc.client_count() == 4, "client count must cover all adapters")
  for adapter, thread in pairs(threads) do
    assert(thread.context_bufnr == source, "picker must preserve source targeting")
    assert(providers.current_id(thread) == (adapter == "pi_work" and "pi" or adapter))
    assert(config.with_context(thread.adapter_context, rpc.is_running, thread.id))
    if adapter ~= "codex" then
      coact.submit_text("Reply COACT_CLAUDE_OK", thread.id)
    end
  end
  local read_done
  in_adapter("pi_work", function()
    rpc.request("thread/read", { threadId = threads.codex.id, includeTurns = false }, function(err, result)
      assert(not err, vim.inspect(err))
      assert(config.context().name == "codex", "explicit thread requests must retain the owner")
      assert(result.thread.id == threads.codex.id)
      read_done = true
    end)
  end)
  assert(vim.wait(10000, function()
    return read_done
  end, 10))
  assert(
    vim.wait(15000, function()
      for adapter, thread in pairs(threads) do
        if adapter ~= "codex" then
          if #thread.turn_order == 0 or thread.active_turn_id or #state.get_thread_pending_requests(thread) > 0 then
            return false
          end
          local complete = false
          for _, item in pairs(thread.items) do
            if item.type == "agentMessage" and (item.text or ""):match("COACT_CLAUDE_OK") then
              complete = true
            elseif item.type == "agentMessage" and (item.text or ""):match("Final answer") then
              complete = true
            end
          end
          if not complete then
            return false
          end
        end
      end
      return true
    end, 10),
    "mixed adapter submissions did not settle"
  )
  local pi_rpc = require("coact.providers.pi_rpc")
  for _, adapter in ipairs({ "pi", "pi_work" }) do
    local thread = threads[adapter]
    local client = pi_rpc.client_for_thread(thread.id)
    assert(client and pi_rpc.thread_id_for_client(client.id) == thread.id)
    assert(client.runtime.adapter_context.name == adapter)
  end
  assert(config.root().default_adapter == "pi_work")
  assert(config.selected_adapter().name == "codex")
  rpc.stop()
  assert(rpc.client_count() == 0, "shutdown must stop every adapter")
  for _, thread in pairs(threads) do
    assert(not config.with_context(thread.adapter_context, rpc.is_running, thread.id))
  end
end
local ok, err = xpcall(run, debug.traceback)
rpc.stop()
vim.fn.delete(workspace, "rf")
assert(ok, err)
print("Adapter picker + mixed provider ownership: PASS")
vim.cmd("qa!")
