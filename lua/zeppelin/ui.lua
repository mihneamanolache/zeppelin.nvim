local M = {}

--- Show a simple popup notification. Auto-closes after 1 second.
---@param text string
---@param opts table|nil { width, height }
M.show_popup = function(text, opts)
  opts = opts or {}
  local lines = vim.split(text, "\n", { plain = true })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local max_line_width = 0
  for _, line in ipairs(lines) do
    max_line_width = math.max(max_line_width, #line)
  end

  local width = opts.width or math.min(max_line_width + 4, editor_width - 4)
  local height = opts.height or math.min(#lines, editor_height - 4)

  width = math.max(width, 20)
  height = math.max(height, 1)

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = 1,
    col = math.floor((editor_width - width) / 2),
    style = "minimal",
    border = "rounded",
    focusable = false,
  })

  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, 1000)
end

--- Define highlight groups used by the plugin.
function M.setup_highlights()
  local hl = vim.api.nvim_set_hl

  -- Tree highlights
  hl(0, "ZeppelinFolder", { link = "Directory", default = true })
  hl(0, "ZeppelinNotebook", { link = "Normal", default = true })
  hl(0, "ZeppelinFolderIcon", { link = "Directory", default = true })

  -- Output highlights
  hl(0, "ZeppelinOutputHeader", { link = "Title", default = true })
  hl(0, "ZeppelinOutput", { link = "Comment", default = true })
  hl(0, "ZeppelinOutputError", { link = "ErrorMsg", default = true })
  hl(0, "ZeppelinRunning", { link = "WarningMsg", default = true })

  -- Separator
  hl(0, "ZeppelinSeparator", { link = "NonText", default = true })
end

return M
