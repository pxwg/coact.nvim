if vim.g.loaded_coact_nvim == 1 then
  return
end
vim.g.loaded_coact_nvim = 1

-- Selection actions are <Plug> targets; coact.nvim binds no global keys.
vim.keymap.set("x", "<Plug>(CoactSideAsk)", function()
  require("coact").side_ask()
end, { desc = "Coact: side ask about the selection" })
vim.keymap.set("x", "<Plug>(CoactAddSelection)", function()
  require("coact").add_selection_visual()
end, { desc = "Coact: add @selection to the prompt" })

vim.api.nvim_create_user_command("Coact", function(opts)
  require("coact").command(opts)
end, {
  nargs = "*",
  bang = true,
  range = true,
  complete = function(arglead, line)
    return require("coact").complete_command(arglead, line)
  end,
})
