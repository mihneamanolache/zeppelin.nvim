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
  require("zeppelin.auth").login_or_reuse()
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

-- :ZeppelinNewParagraph — create new paragraph after cursor
vim.api.nvim_create_user_command("ZeppelinNewParagraph", function()
  require("zeppelin.notebook").create_paragraph()
end, {})

return M
