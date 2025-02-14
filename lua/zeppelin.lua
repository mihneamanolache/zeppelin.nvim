-- lua/zeppelin.lua
local M = {}
local auth = require("zeppelin.auth")
local ui = require("zeppelin.ui")
local notebooks = require("zeppelin.notebooks")
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

return M
