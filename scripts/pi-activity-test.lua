local M = {}
function M.run()
  local state = require("coact.state")
  local render = require("coact.ui.render")
  local id = "pi:activity-clusters"
  local thread = state.update_thread_from_payload({ id = id, replaceTurns = true })
  local function item(key, kind, text, status)
    local value = {
      id = key,
      type = kind,
      status = status or "completed",
      text = text,
      command = kind == "commandExecution" and ("echo " .. key) or nil,
    }
    if kind == "userMessage" then
      value.content = { { type = "text", text = text } }
    end
    if kind == "reasoning" then
      value.content = { text }
    end
    state.upsert_item(id, "turn", value)
  end
  item("user", "userMessage", "Inspect files")
  item("tool1", "commandExecution")
  item("tool2", "commandExecution", nil, "error")
  item("thought", "reasoning", "Checked both files")
  item("text1", "agentMessage", "First result")
  item("tool3", "commandExecution")
  item("tool4", "commandExecution")
  item("compact", "compactionSummary", "Checkpoint")
  item("tool5", "commandExecution")
  item("tool6", "commandExecution")
  item("branch", "branchSummary", "Branch checkpoint")
  item("user2", "userMessage", "Next request")
  item("tool7", "commandExecution")
  item("tool8", "commandExecution")
  thread.generation = "idle"
  thread.pi_agent_active = false
  local function inspect()
    local blocks, clusters, flat = render.select_render_tree(thread), {}, {}
    for _, block in ipairs(blocks) do
      if block.type == "ActivitySummaryBlock" then
        table.insert(clusters, block)
        for _, child in ipairs(block.children) do
          table.insert(flat, child.item_id)
        end
      else
        table.insert(flat, block.item_id)
      end
    end
    assert(vim.deep_equal(flat, thread.item_order), "clustering must preserve exact transcript order")
    return blocks, clusters
  end
  local blocks, clusters = inspect()
  assert(#clusters == 4 and #clusters[1].children == 3, "finished adjacent tools/thinking should cluster")
  assert(clusters[1].children[2].state == "error", "failed tools remain inspectable")
  assert(
    blocks[3].item_id == "text1" and blocks[5].item_id == "compact" and blocks[7].item_id == "branch",
    "text and summaries must stay between clusters"
  )
  local cluster_id = clusters[1].item_id
  thread.generation = "streaming"
  thread.pi_agent_active = true
  local _, busy_clusters = inspect()
  assert(
    #busy_clusters == 3 and busy_clusters[1].item_id == cluster_id,
    "a new run must not expand historical clusters"
  )
  thread.generation = "idle"
  thread.pi_agent_active = false
  state.upsert_item(id, "turn", { id = "tool8", status = "running" })
  local _, running_clusters = inspect()
  assert(#running_clusters == 3, "unfinished tools must not enter a finished cluster")
  state.upsert_item(id, "turn", { id = "tool8", status = "completed" })
  if not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    state.bind_buffer(thread, vim.api.nvim_create_buf(false, true))
  end
  render.render(thread)
  assert(vim.tbl_contains(thread.placeholder_marks[2].meta, "2 tools"), "tool-only clusters must show their tool count")
  return thread
end
return M
