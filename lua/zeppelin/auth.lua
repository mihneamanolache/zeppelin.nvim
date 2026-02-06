local M = {}
local api = require("zeppelin.api")
local ui = require("zeppelin.ui")

M.authenticate = function(username, password)
  api.authenticate(username, password, function(err)
    if err then
      ui.show_popup(err)
      return
    end
    ui.show_popup("Zeppelin authentication successful!")
    require("zeppelin.tree").open()
  end)
end

--- Try to reuse existing session cookies. If valid, open tree directly;
--- otherwise fall back to the interactive login prompt.
M.login_or_reuse = function()
  local cookie_file = api.COOKIE_FILE
  if vim.fn.filereadable(cookie_file) == 1 then
    -- Validate session with a lightweight call
    api.get("/api/notebook", function(err)
      if not err then
        ui.show_popup("Session restored!")
        require("zeppelin.tree").open()
      else
        M.prompt_login()
      end
    end)
  else
    M.prompt_login()
  end
end

--- Interactive login prompt (extracted from ZeppelinLogin command).
M.prompt_login = function()
  vim.ui.input({ prompt = "Username: " }, function(username)
    if not username or username == "" then return end
    local password = vim.fn.inputsecret("Password: ")
    if not password or password == "" then return end
    M.authenticate(username, password)
  end)
end

return M
