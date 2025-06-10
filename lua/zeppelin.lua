-- lua/zeppelin.lua
local M = {}
local auth = require("zeppelin.auth")
local ui = require("zeppelin.ui")
local notebooks = require("zeppelin.notebooks")
local interpreter = require("zeppelin.interpreter")
local config = require("zeppelin.config")

 -- Load configuration globally
M.setup = function(opts)
  config.setup(opts)
end

-- Add :ZeppelinLogin command to authenticate
vim.api.nvim_create_user_command("ZeppelinLogin", function(opts)
  local args = vim.split(opts.args, " ")
  if #args < 2 then
    ui.show_popup("Usage: :ZeppelinLogin <username> <password>")
    return
  end
  auth.authenticate(args[1], args[2])
end, { nargs = "*" })

-- Add :Zeppelin command to fetch and display all notebooks
vim.api.nvim_create_user_command("Zeppelin", function()
  notebooks.fetch_notebooks()
end, {})

-- Restart interpreter
vim.api.nvim_create_user_command("ZeppelinRestartInterpreter", function(opts)
  local args = vim.split(opts.args, " ")
  if #args < 1 then
    ui.show_popup("Usage: :ZeppelinRestartInterpreter <settingId> [noteId]")
    return
  end
  interpreter.restart(args[1], args[2])
end, { nargs = "*" })

-- Stop interpreter
vim.api.nvim_create_user_command("ZeppelinStopInterpreter", function(opts)
  local args = vim.split(opts.args, " ")
  if #args < 1 then
    ui.show_popup("Usage: :ZeppelinStopInterpreter <settingId>")
    return
  end
  interpreter.stop(args[1])
end, { nargs = 1 })

return M
