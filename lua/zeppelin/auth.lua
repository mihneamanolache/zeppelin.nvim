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

return M
