-- Launch once in Kitty from the repository root:
-- nvim -u scripts/pi-transcript-ui.lua -i NONE --listen /tmp/coact-pi-ui.sock
-- Over that same socket, call CoactPiTranscriptCheck('live'), then ('reload'),
-- then ('compact'). Use za/K on the visible blocks between checks.
vim.opt.runtimepath:append(vim.fn.getcwd())
local id = "pi:kitty-transcript-fixed"
local state = require("coact.state")
local render = require("coact.ui.render")
local function signature(thread, full_history)
  local out = {}
  for _, block in
    ipairs(full_history and require("coact.events").normalize_thread(thread) or render.select_render_tree(thread))
  do
    local item = block.raw or {}
    table.insert(out, { block.type, block.text or "", item.arguments or {}, item.output or "", item.status or "" })
  end
  return out
end

function _G.CoactPiTranscriptCheck(phase)
  local rpc = require("coact.rpc")
  local thread = assert(state.get_thread(id))
  assert(vim.wait(5000, function()
    return thread.generation == "idle" and #thread.item_order > 0
  end))
  if phase == "live" then
    local types = {}
    for _, block in ipairs(render.select_render_tree(thread)) do
      table.insert(types, block.type)
    end
    assert(
      table.concat(types, ",") == "UserBlock,ReasoningBlock,AssistantBlock,ToolCallBlock,AssistantBlock,AssistantBlock"
    )
    assert(thread.items["e2e-read"].arguments.path == "README.md")
    assert(thread.items["e2e-read"].output == "Fixture read output")
    _G.CoactPiLiveSignature = signature(thread)
  elseif phase == "reload" then
    local done, failure = false, nil
    rpc.request("thread/read", { threadId = id }, function(err, result)
      failure = err
      if not err then
        state.update_thread_from_payload(result.thread)
      end
      done = true
    end)
    assert(vim.wait(5000, function()
      return done
    end))
    assert(not failure, vim.inspect(failure))
    assert(vim.deep_equal(_G.CoactPiLiveSignature, signature(thread)), "live and reloaded transcripts differ")
  elseif phase == "compact" then
    rpc.request("thread/compact/start", { threadId = id }, function(err)
      assert(not err, vim.inspect(err))
    end)
    assert(
      vim.wait(5000, function()
        local last = thread.items[thread.item_order[#thread.item_order]]
        return last and last.type == "branchSummary" and #thread.item_order == 8
      end),
      "compaction failed to preserve branch history"
    )
    local blocks = render.select_render_tree(thread)
    assert(#blocks == 2 and blocks[1].type == "CompactionSummaryBlock" and blocks[2].type == "BranchSummaryBlock")
    local current = signature(thread, true)
    for index, block in ipairs(_G.CoactPiLiveSignature) do
      assert(vim.deep_equal(current[index], block), "compaction must not change prior history")
    end
  elseif phase == "branch" then
    local client = require("coact.providers.pi_rpc").by_thread[id]
    local done = false
    client._request_message("fixture_branch", {}, function(err)
      assert(not err)
      rpc.request("thread/read", { threadId = id }, function(read_err, result)
        assert(not read_err)
        state.update_thread_from_payload(result.thread)
        done = true
      end)
    end)
    assert(vim.wait(5000, function()
      return done
    end))
    local blocks = render.select_render_tree(thread)
    assert(#blocks == 2 and blocks[2].text == "Alternate branch only", "sibling history leaked into selected branch")
  else
    error("unknown check: " .. tostring(phase))
  end
  render.render(thread)
  return { phase = phase, passed = true, signature = signature(thread) }
end

-- Set this flag when loading the assertions into the existing fixed UI.
if not _G.CoactPiTranscriptAttach then
  require("coact").setup({
    provider = "pi",
    providers = {
      pi = {
        command = { "node", vim.fn.getcwd() .. "/scripts/pi-transcript-rpc-fixture.mjs" },
        picker_prewarm = false,
        edit_bridge = { enabled = false },
        nvim_tools = { enabled = false },
      },
    },
  })
  vim.schedule(function()
    require("coact").new_thread({ session_id = "kitty-transcript-fixed", prompt = "Verify Pi transcript placement" })
  end)
end
