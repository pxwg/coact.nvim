if vim.g.loaded_coact_nvim == 1 then
  return
end
vim.g.loaded_coact_nvim = 1

vim.api.nvim_create_user_command("Coact", function(opts)
  require("coact").command(opts)
end, {
  nargs = "*",
  complete = function(arglead, line)
    return require("coact").complete_command(arglead, line)
  end,
})
