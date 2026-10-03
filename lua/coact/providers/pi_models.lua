-- Publish Pi's resolved session scope without exposing it as chat/status content.
local M = {}
local path

function M.source()
  return [=[
export default function (pi) {
  const publish = (_event, ctx) => {
    const scoped = typeof pi.getScopedModels === "function"
      ? pi.getScopedModels() : ctx.scopedModels;
    ctx.ui.setStatus("coact.nvim.scoped-models", JSON.stringify(
      (scoped || []).map(entry => entry.model)
    ));
  };
  pi.on("session_start", publish);
  pi.on("model_select", publish);
}
]=]
end

function M.prepare_command(command)
  if not path then
    path = vim.fn.tempname() .. "-coact-models.mjs"
    vim.fn.writefile(vim.split(M.source(), "\n", { plain = true }), path)
  end
  if type(command) == "string" then
    return command .. " --extension " .. vim.fn.shellescape(path)
  end
  local out = vim.deepcopy(command)
  vim.list_extend(out, { "--extension", path })
  return out
end

return M
