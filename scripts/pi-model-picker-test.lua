local config = require("coact.config")
config.setup({ default_adapter = "pi", adapters = { pi = { provider = "pi" } } })
local pi = require("coact.providers.pi")
local runtime = pi.new_runtime()
pi.with_runtime(runtime, function()
  local calls = 0
  local peer = {
    _request_message = function(method, _, callback)
      assert(method == "get_available_models")
      calls = calls + 1
      callback(nil, { models = { { provider = "test", id = "all" } } })
    end,
  }
  local function list(scope)
    local result
    assert(pi.custom_request(peer, "model/list", { scope = scope }, function(err, value)
      assert(not err)
      result = value.data
    end))
    return result
  end
  local function publish(value)
    assert(pi.handle_raw_message({
      type = "extension_ui_request",
      method = "setStatus",
      statusKey = "coact.nvim.scoped-models",
      statusText = value,
    }, peer))
  end
  publish('[{"provider":"test","id":"scoped"},null,{"id":null}]')
  assert(list("scoped")[1].id == "test/scoped" and calls == 0)
  assert(list("all")[1].id == "test/all" and calls == 1)
  assert(list(nil)[1].id == "test/all", "other catalog consumers retain the full list")
  pi.with_runtime(pi.new_runtime(), function()
    assert(list("scoped")[1].id == "test/all", "scope must not leak between threads")
  end)
  publish('[{"provider":"magpie-vps","id":"claude/claude-opus-5-5"}]')
  assert(list("scoped")[1].model == "magpie-vps/claude/claude-opus-5-5")
  local selected
  pi.custom_request(
    {
      _request_message = function(method, params, callback)
        assert(method == "set_model")
        selected = params
        callback(nil, {})
      end,
    },
    "thread/settings/update",
    { model = list("scoped")[1].model },
    function(err)
      assert(not err)
    end
  )
  assert(selected.provider == "magpie-vps" and selected.modelId == "claude/claude-opus-5-5")
  assert(pi._normalize_model({ provider = "test", id = "test/nested" }).model == "test/test/nested")
  publish(vim.NIL)
  assert(list("scoped")[1].id == "test/all", "unset scope falls back to all")
  publish("null")
  assert(list("scoped")[1].id == "test/all")
end)

local rpc = require("coact.rpc")
local slash = require("coact.slash")
local original_request, original_select = rpc.request, vim.ui.select
local scopes, prompts = {}, {}
rpc.request = function(method, params, callback)
  assert(method == "model/list")
  assert(params.threadId == "pi:model-test", "model requests must target the opening thread")
  scopes[#scopes + 1] = params.scope
  callback(nil, { data = { { id = "test/" .. params.scope } } })
end
vim.ui.select = function(items, opts, callback)
  prompts[#prompts + 1] = opts.prompt
  assert(items[1].id == "test/" .. scopes[#scopes])
  assert(items[2].scope_switch)
  if #prompts < 3 then
    callback(items[2])
  else
    callback(nil)
  end
end
slash.dispatch("/model", "pi:model-test", {
  ensure_server = function(callback)
    callback()
  end,
})
assert(vim.deep_equal(scopes, { "scoped", "all", "scoped" }))
assert(prompts[1] == "Pi model (scoped)" and prompts[2] == "Pi model (all)")
rpc.request, vim.ui.select = original_request, original_select
print("Pi model picker tests passed")
