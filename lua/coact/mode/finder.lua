-- Finding threads and cards across every known workspace.
local config = require("coact.mode.config")
local lsp = require("coact.mode.lsp")
local workspace = require("coact.mode.workspace")

local M = {}

local function notify(message, level)
  vim.notify("Coact mode: " .. message, level or vim.log.levels.INFO)
end

local function value(v)
  return v ~= vim.NIL and v or nil
end

--- Index every known workspace with the server: callback(cards), each card
--- carrying its workspace root.
function M.index(callback)
  local cmd, err = lsp.cmd()
  if not cmd then
    return notify(err, vim.log.levels.ERROR)
  end
  local roots = workspace.known()
  if #roots == 0 then
    return callback({})
  end
  local cards, pending = {}, #roots
  for _, root in ipairs(roots) do
    vim.system(vim.list_extend(vim.deepcopy(cmd), { "--index", root }), { text = true }, function(result)
      vim.schedule(function()
        local ok, index = pcall(vim.json.decode, result.stdout or "")
        if result.code == 0 and ok and type(index) == "table" then
          for _, card in ipairs(index.cards or {}) do
            for key, v in pairs(card) do
              card[key] = value(v)
            end
            card.root = root
            table.insert(cards, card)
          end
        end
        pending = pending - 1
        if pending == 0 then
          callback(cards)
        end
      end)
    end)
  end
end

local function age(seconds)
  if not seconds then
    return ""
  end
  local d = os.time() - seconds
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%dm ago"):format(d / 60)
  elseif d < 86400 then
    return ("%dh ago"):format(d / 3600)
  end
  return os.date("%Y-%m-%d", seconds)
end

local function place(card)
  return vim.fs.basename(card.root)
end

--- Open a card's file at its heading and attach Coact mode.
function M.jump(card)
  vim.cmd.edit(vim.fn.fnameescape(card.path))
  vim.api.nvim_win_set_cursor(0, { card.line + 1, 0 })
  vim.cmd("normal! zv")
  require("coact.mode").attach(vim.api.nvim_get_current_buf())
end

-- snacks.picker when available, else vim.ui.select.
local function pick(title, items, choose)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    snacks.picker.pick({
      title = title,
      items = items,
      format = function(item)
        return item.chunks
      end,
      preview = "file",
      confirm = function(picker, item)
        picker:close()
        if item then
          choose(item.card)
        end
      end,
    })
    return
  end
  vim.ui.select(items, {
    prompt = title,
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      choose(item.card)
    end
  end)
end

local function item(card, icon, icon_hl, detail)
  local label = icon .. " " .. card.title .. (detail ~= "" and ("  " .. detail) or "")
  return {
    card = card,
    label = label,
    text = table.concat({ card.title, card.preview or "", card.last or "", card.text or "", place(card) }, " "),
    file = card.path,
    pos = { card.line + 1, 0 },
    chunks = { { icon .. " ", icon_hl }, { card.title }, { "  " .. detail, "Comment" } },
  }
end

--- Pick a thread (a card with THREAD_ID), most recent first.
function M.threads()
  M.index(function(cards)
    local threads = vim.tbl_filter(function(card)
      return card.thread ~= nil
    end, cards)
    if #threads == 0 then
      return notify("no threads yet; :CoactMode init starts a workspace")
    end
    for _, card in ipairs(threads) do
      card.activity = workspace.activity(card.root, card.thread) or vim.fn.getftime(card.path)
    end
    table.sort(threads, function(a, b)
      if a.pin ~= b.pin then
        return a.pin
      end
      return (a.activity or 0) > (b.activity or 0)
    end)
    local icons = config.get().icons
    local items = vim.tbl_map(function(card)
      local detail = table.concat(
        vim.tbl_filter(function(s)
          return s ~= ""
        end, {
          card.last or "",
          ("%d turn%s"):format(card.turns, card.turns == 1 and "" or "s"),
          place(card),
          age(card.activity),
        }),
        " · "
      )
      return item(card, card.pin and icons.pin or icons.note, card.pin and "CoactModePin" or "CoactModeNote", detail)
    end, threads)
    pick("Coact threads", items, M.jump)
  end)
end

local kind_hl = {
  user = "CoactModeUser",
  assistant = "CoactModeAssistant",
  synthesis = "CoactModeSynthesis",
  trace = "CoactModeTrace",
}

--- Pick any card by title or text; trace records are left out.
function M.cards()
  M.index(function(cards)
    local icons = config.get().icons
    local items = {}
    for _, card in ipairs(cards) do
      local record = card.kind == "trace" and (card.text or ""):find("#+begin_src jsonl", 1, true)
      if not record then
        local icon = card.thread and icons.pin or icons[card.kind or "note"] or icons.note
        local detail = table.concat(
          vim.tbl_filter(function(s)
            return s ~= ""
          end, { card.preview or "", place(card) }),
          " · "
        )
        table.insert(items, item(card, icon, kind_hl[card.kind] or "CoactModeNote", detail))
      end
    end
    if #items == 0 then
      return notify("no cards yet")
    end
    pick("Coact cards", items, M.jump)
  end)
end

return M
