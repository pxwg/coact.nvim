if vim.g.loaded_coact_mode == 1 then
  return
end
vim.g.loaded_coact_mode = 1

-- Coact mode loads on first use: the command, the <Plug> targets, or opening
-- an Org file inside a chat workspace.
local function mode()
  local m = require("coact.mode")
  m.setup_once()
  return m
end

vim.api.nvim_create_user_command("CoactMode", function(opts)
  mode().command(opts)
end, {
  nargs = "*",
  range = true,
  desc = "Coact mode: card-based conversations",
  complete = function(arglead, line)
    return require("coact.mode").complete(arglead, line)
  end,
})

local function plug(lhs, modes, fn, desc)
  vim.keymap.set(modes, lhs, fn, { desc = "Coact mode: " .. desc })
end

local function visual()
  local first, last = vim.fn.getpos("v"), vim.fn.getpos(".")
  if first[2] > last[2] or (first[2] == last[2] and first[3] > last[3]) then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return { { first[2], first[3] - 1 }, { last[2], last[3] - 1 } }
end

plug("<Plug>(CoactModeSubmit)", "n", function()
  mode().submit()
end, "submit the question")
plug("<Plug>(CoactModeStop)", "n", function()
  mode().stop()
end, "stop the call")
plug("<Plug>(CoactModePin)", "n", function()
  mode().pin()
end, "pin this card")
plug("<Plug>(CoactModeUnpin)", "n", function()
  mode().unpin()
end, "unpin")
plug("<Plug>(CoactModeNew)", "n", function()
  mode().new()
end, "new card")
plug("<Plug>(CoactModeNew)", "x", function()
  mode().new({ range = visual() })
end, "new card from the selection")
plug("<Plug>(CoactModeAsk)", "n", function()
  mode().ask()
end, "ask in a new pinned card")
plug("<Plug>(CoactModeAsk)", "x", function()
  mode().ask({ range = visual() })
end, "ask about the selection")
plug("<Plug>(CoactModeCompact)", "n", function()
  mode().compact()
end, "compact the thread")
plug("<Plug>(CoactModeTrace)", "n", function()
  mode().trace()
end, "show the trace")

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("CoactModeAttach", { clear = true }),
  pattern = "org",
  callback = function(event)
    if vim.fs.root(event.buf, ".coact-zk") then
      mode().attach(event.buf)
    end
  end,
})
