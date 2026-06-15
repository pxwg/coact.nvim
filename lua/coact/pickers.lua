local M = {}
local util = require("coact.util")

local function label(thread)
  local title = util.value(thread.name) or util.value(thread.preview) or "[untitled]"
  return ("%s  %s"):format(tostring(util.value(thread.id) or ""), tostring(title):gsub("\n", " "))
end

local function preview_text(thread)
  local lines = {}
  local function add(name, value)
    value = util.value(value)
    if value ~= nil and value ~= "" then
      table.insert(lines, ("%s: %s"):format(name, tostring(value)))
    end
  end
  add("id", thread.id)
  add("name", thread.name)
  add("cwd", thread.cwd)
  add("model", thread.model)
  add("provider", thread.modelProvider)
  add("session", thread.sessionFile)
  local preview = util.value(thread.preview)
  if preview ~= nil and preview ~= "" then
    if #lines > 0 then
      table.insert(lines, "")
    end
    table.insert(lines, tostring(preview))
  end
  return table.concat(lines, "\n")
end

M._label = label
M._preview_text = preview_text

function M.threads()
  require("coact").list_threads(function(threads)
    local provider_title = require("coact.providers").title()
    if #threads == 0 then
      vim.notify(
        "No " .. provider_title .. " threads for this workspace",
        vim.log.levels.INFO,
        { title = "coact.nvim" }
      )
      return
    end

    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.picker then
      snacks.picker.pick({
        title = provider_title .. " Threads",
        items = vim.tbl_map(function(thread)
          return {
            text = label(thread),
            preview = {
              text = preview_text(thread),
              ft = "coact-thread",
              loc = false,
            },
            thread = thread,
          }
        end, threads),
        format = function(item)
          return { { item.text } }
        end,
        preview = "preview",
        confirm = function(picker, item)
          picker:close()
          require("coact").resume(item.thread.id)
        end,
      })
      return
    end

    vim.ui.select(threads, {
      prompt = provider_title .. " threads",
      format_item = label,
    }, function(thread)
      if thread then
        require("coact").resume(thread.id)
      end
    end)
  end)
end

return M
