if vim.g.loaded_codex_nvim == 1 then
  return
end
vim.g.loaded_codex_nvim = 1

vim.api.nvim_create_user_command("Codex", function(opts)
  require("codex").command(opts)
end, {
  nargs = "*",
  complete = function(_, line)
    return require("codex").complete_command(line)
  end,
})
