local M = {}
local config = require("zeppelin.config")
local ui = require("zeppelin.ui")

M.setup = function(opts)
  config.setup(opts)
  ui.setup_highlights()
end

-- :ZeppelinLogin [username] [password]
vim.api.nvim_create_user_command("ZeppelinLogin", function(opts)
  local args = vim.split(opts.args, " ", { trimempty = true })
  if #args >= 2 then
    require("zeppelin.auth").authenticate(args[1], args[2])
    return
  end
  vim.ui.input({ prompt = "Username: " }, function(username)
    if not username or username == "" then return end
    vim.ui.input({ prompt = "Password: " }, function(password)
      if not password or password == "" then return end
      require("zeppelin.auth").authenticate(username, password)
    end)
  end)
end, { nargs = "*" })

-- :Zeppelin / :ZeppelinTree — toggle tree sidebar
vim.api.nvim_create_user_command("Zeppelin", function()
  require("zeppelin.tree").toggle()
end, {})

vim.api.nvim_create_user_command("ZeppelinTree", function()
  require("zeppelin.tree").toggle()
end, {})

-- :ZeppelinSearch — Telescope notebook search
vim.api.nvim_create_user_command("ZeppelinSearch", function()
  require("zeppelin.search").search_notebooks()
end, {})

-- :ZeppelinRun — run paragraph under cursor
vim.api.nvim_create_user_command("ZeppelinRun", function()
  require("zeppelin.notebook").run_paragraph()
end, {})

-- :ZeppelinSave — save current paragraph
vim.api.nvim_create_user_command("ZeppelinSave", function()
  require("zeppelin.notebook").save_paragraph()
end, {})

-- :ZeppelinSaveAll — save all modified paragraphs
vim.api.nvim_create_user_command("ZeppelinSaveAll", function()
  require("zeppelin.notebook").save_all()
end, {})

-- :ZeppelinRestartInterpreter — restart interpreter for current notebook
vim.api.nvim_create_user_command("ZeppelinRestartInterpreter", function()
  require("zeppelin.notebook").restart_interpreter()
end, {})

return M
