-- Catalogs come from this execution unit, not whichever UI has focus when a
-- request finishes. CLI commands lack file paths; command is an invocation id.
local M = {}
local function object(value)
  return type(value) == "table" and value or {}
end
local function text(value)
  return type(value) == "string" and value or ""
end

function M.models(client)
  local configured = require("coact.providers.claude").options().models
  local source = type(configured) == "table" and configured or object(object(client.init).models)
  local models, seen = {}, {}
  for _, entry in ipairs(source) do
    if type(entry) == "string" then
      entry = { value = entry }
    end
    entry = object(entry)
    local id = text(entry.value or entry.id or entry.model)
    if id ~= "" and not seen[id] then
      seen[id] = true
      table.insert(models, {
        id = id,
        model = id,
        displayName = text(entry.displayName) ~= "" and entry.displayName or id,
        description = text(entry.description),
        isDefault = id == client.model or (not client.model and id == "default"),
      })
    end
  end
  if text(client.model) ~= "" and not seen[client.model] then
    table.insert(models, { id = client.model, model = client.model, displayName = client.model, isDefault = true })
  end
  return models
end

function M.skills(client)
  local names, descriptions = {}, {}
  local reported = object(client.metadata).skills
  for _, command in ipairs(object(object(client.init).commands)) do
    command = object(command)
    local name = text(command.name)
    if name ~= "" then
      descriptions[name] = text(command.description)
      -- Built-in control commands (compact, model, etc.) are not skills. The
      -- system/init skills list adds built-in prompt skills once available.
      if type(reported) ~= "table" and command.builtin ~= true then
        names[name] = true
      end
    end
  end
  for _, name in ipairs(object(reported)) do
    if type(name) == "string" then
      names[name] = true
    end
  end
  local skills = {}
  for name in pairs(names) do
    if name:match("^[%w_:/%.%-]+$") then
      table.insert(
        skills,
        { name = name, command = "/" .. name, description = descriptions[name], shortDescription = descriptions[name] }
      )
    end
  end
  table.sort(skills, function(a, b)
    return a.name < b.name
  end)
  return skills
end

function M.prompt(client, input)
  local parts, skill = {}, nil
  for _, entry in ipairs(object(input)) do
    if entry.type == "text" then
      table.insert(parts, text(entry.text))
    elseif entry.type == "skill" then
      if skill then
        return nil, "Submit one Claude skill invocation at a time"
      end
      for _, available in ipairs(M.skills(client)) do
        if available.name == entry.name then
          skill = available.command
          break
        end
      end
      if not skill then
        return nil, "Claude skill is not available in this thread: " .. text(entry.name)
      end
    else
      return nil, "Claude adapter accepts text context and skills only"
    end
  end
  local prompt = table.concat(parts, "\n\n")
  if skill then
    prompt = skill .. (prompt ~= "" and " " .. prompt or "")
  end
  if prompt == "" then
    return nil, "Prompt is empty"
  end
  return prompt
end

return M
