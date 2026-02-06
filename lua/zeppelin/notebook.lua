local M = {}
local api = require("zeppelin.api")
local ui = require("zeppelin.ui")

local ns = vim.api.nvim_create_namespace("zeppelin_paragraphs")

--- Per-buffer notebook state.
--- _buffers[bufnr] = {
---   notebook_id = "...",
---   paragraphs = {
---     { id, original_text, start_extmark, end_extmark, output_extmark, interpreter, last_output },
---     ...
---   }
--- }
local _buffers = {}

--------------------------------------------------------------------------------
-- Interpreter / filetype detection
--------------------------------------------------------------------------------

local interpreter_map = {
  ["%%pyspark"]  = "python",
  ["%%python"]   = "python",
  ["%%sql"]      = "sql",
  ["%%sh"]       = "sh",
  ["%%md"]       = "markdown",
  ["%%angular"]  = "html",
  ["%%spark"]    = "scala",
}

--- Detect interpreter from the first line of paragraph text.
---@param text string
---@return string filetype
local function detect_interpreter(text)
  local first_line = text:match("^([^\n]*)")
  if not first_line then
    return "scala"
  end
  first_line = vim.trim(first_line)

  for prefix, ft in pairs(interpreter_map) do
    if first_line:match("^" .. vim.pesc(prefix)) then
      return ft
    end
  end

  if first_line:match("^%%.conf") then
    return "python"
  end

  return "scala"
end

--- Pick the dominant filetype from a list of paragraphs.
---@param paragraphs table[]
---@return string filetype
local function detect_dominant_filetype(paragraphs)
  local counts = {}
  for _, p in ipairs(paragraphs) do
    local ft = detect_interpreter(p.text or "")
    counts[ft] = (counts[ft] or 0) + 1
  end

  local best_ft, best_count = "scala", 0
  for ft, count in pairs(counts) do
    if count > best_count then
      best_ft = ft
      best_count = count
    end
  end
  return best_ft
end

--------------------------------------------------------------------------------
-- Separator virtual lines
--------------------------------------------------------------------------------

local separator_text = string.rep("─", 80)

--- Create a virtual separator line below a given line.
---@param bufnr number
---@param line number 0-indexed line to place separator after
---@return number extmark_id
local function place_separator(bufnr, line)
  return vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
    virt_lines = { { { separator_text, "ZeppelinSeparator" } } },
    virt_lines_above = false,
  })
end

--------------------------------------------------------------------------------
-- Output display (inline via virt_lines)
--------------------------------------------------------------------------------

--- Build virtual lines from Zeppelin output msg array.
---@param output_data table Zeppelin response body with msg array
---@return table[] virt_lines
local function build_output_virt_lines(output_data)
  local virt_lines = {}
  table.insert(virt_lines, { { "── Output ──", "ZeppelinOutputHeader" } })

  local code = output_data.code or "UNKNOWN"
  local hl = (code == "ERROR") and "ZeppelinOutputError" or "ZeppelinOutput"

  if output_data.msg and type(output_data.msg) == "table" then
    for _, item in ipairs(output_data.msg) do
      if item.data then
        for _, text_line in ipairs(vim.split(item.data, "\n", { plain = true })) do
          table.insert(virt_lines, { { text_line, hl } })
        end
      end
    end
  else
    table.insert(virt_lines, { { "(no output)", "ZeppelinOutput" } })
  end

  return virt_lines
end

--- Display output inline below a paragraph via extmarks.
---@param bufnr number
---@param para table paragraph metadata entry
---@param output_data table Zeppelin response body
function M.display_output(bufnr, para, output_data)
  -- Remove previous output extmark
  if para.output_extmark then
    vim.api.nvim_buf_del_extmark(bufnr, ns, para.output_extmark)
    para.output_extmark = nil
  end

  para.last_output = output_data

  local virt_lines = build_output_virt_lines(output_data)

  -- Place output after the paragraph's end extmark line
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.end_extmark, {})
  if not end_pos or #end_pos == 0 then
    return
  end

  para.output_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, end_pos[1], 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })
end

--- Show "Running..." indicator.
---@param bufnr number
---@param para table
function M.show_running_indicator(bufnr, para)
  if para.output_extmark then
    vim.api.nvim_buf_del_extmark(bufnr, ns, para.output_extmark)
    para.output_extmark = nil
  end

  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.end_extmark, {})
  if not end_pos or #end_pos == 0 then
    return
  end

  para.output_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, end_pos[1], 0, {
    virt_lines = { { { "  Running...", "ZeppelinRunning" } } },
    virt_lines_above = false,
  })
end

--- Toggle output visibility for a paragraph.
---@param bufnr number
---@param para table
function M.toggle_output(bufnr, para)
  if para.output_extmark then
    vim.api.nvim_buf_del_extmark(bufnr, ns, para.output_extmark)
    para.output_extmark = nil
  elseif para.last_output then
    M.display_output(bufnr, para, para.last_output)
  end
end

--------------------------------------------------------------------------------
-- Paragraph location
--------------------------------------------------------------------------------

--- Find the paragraph metadata for the cursor's current position.
---@param bufnr number|nil
---@return table|nil para, number|nil index
function M.get_paragraph_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = _buffers[bufnr]
  if not state then
    return nil, nil
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed

  for i, para in ipairs(state.paragraphs) do
    local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.start_extmark, {})
    local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.end_extmark, {})
    if start_pos and end_pos and #start_pos > 0 and #end_pos > 0 then
      if cursor_line >= start_pos[1] and cursor_line <= end_pos[1] then
        return para, i
      end
    end
  end

  return nil, nil
end

--------------------------------------------------------------------------------
-- Buffer rendering
--------------------------------------------------------------------------------

--- Render all paragraphs into a buffer with extmark tracking.
---@param bufnr number
---@param paragraphs table[] raw Zeppelin paragraph objects
---@param notebook_id string
function M.render_notebook(bufnr, paragraphs, notebook_id)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local para_meta = {}
  local all_lines = {}

  for i, p in ipairs(paragraphs) do
    local text = p.text or ""
    local lines = vim.split(text, "\n", { plain = true })
    if #lines == 0 then
      lines = { "" }
    end

    local start_line = #all_lines

    for _, line in ipairs(lines) do
      table.insert(all_lines, line)
    end

    local end_line = #all_lines - 1

    table.insert(para_meta, {
      id = p.id,
      original_text = text,
      start_line = start_line,
      end_line = end_line,
      start_extmark = nil,
      end_extmark = nil,
      output_extmark = nil,
      interpreter = detect_interpreter(text),
      last_output = nil,
    })

    -- Add a blank line between paragraphs (for separator placement)
    if i < #paragraphs then
      table.insert(all_lines, "")
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_lines)

  -- Place extmarks now that lines are set
  local offset = 0
  for i, meta in ipairs(para_meta) do
    local text = paragraphs[i].text or ""
    local lines = vim.split(text, "\n", { plain = true })
    if #lines == 0 then
      lines = { "" }
    end

    local start_line = offset
    local end_line = offset + #lines - 1

    meta.start_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
      right_gravity = false,
    })
    meta.end_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, end_line, 0, {
      right_gravity = true,
    })
    meta.start_line = start_line
    meta.end_line = end_line

    -- Place separator after each paragraph except the last
    if i < #paragraphs then
      place_separator(bufnr, end_line)
      offset = end_line + 2 -- +1 for blank line, +1 for next start
    else
      offset = end_line + 1
    end
  end

  _buffers[bufnr] = {
    notebook_id = notebook_id,
    paragraphs = para_meta,
  }
end

--------------------------------------------------------------------------------
-- Open notebook
--------------------------------------------------------------------------------

--- Fetch and open a notebook by ID.
---@param notebook_id string
function M.fetch_and_open(notebook_id)
  api.get("/api/notebook/" .. notebook_id, function(err, data)
    if err then
      ui.show_popup("Failed to fetch notebook: " .. err)
      return
    end
    M.open_notebook(data)
  end)
end

--- Find or create a suitable editing window (not a special/tree sidebar).
---@return number win_id
local function find_edit_window()
  local cur_win = vim.api.nvim_get_current_win()
  -- Try to find an existing normal window
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= cur_win then
      local buf = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[buf].buftype
      local ft = vim.bo[buf].filetype
      -- Skip special buffers (tree, nofile sidebars, etc.)
      if bt ~= "nofile" and ft ~= "zeppelin_tree" then
        return win
      end
    end
  end
  -- Check if current window itself is suitable
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  if vim.bo[cur_buf].filetype ~= "zeppelin_tree" and vim.bo[cur_buf].buftype ~= "nofile" then
    return cur_win
  end
  -- No suitable window found — create a new split to the right
  vim.cmd("rightbelow vsplit")
  return vim.api.nvim_get_current_win()
end

--- Open a notebook from its JSON data. Creates or switches to the buffer.
---@param notebook_json table
function M.open_notebook(notebook_json)
  local paragraphs = notebook_json.paragraphs or {}
  if #paragraphs == 0 then
    ui.show_popup("No paragraphs in notebook!")
    return
  end

  local notebook_id = notebook_json.id or "unknown"
  local buf_name = "zeppelin://" .. notebook_id

  -- Check if buffer already exists
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == buf_name then
      local win = find_edit_window()
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_buf(win, b)
      return
    end
  end

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, buf_name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false

  M.render_notebook(buf, paragraphs, notebook_id)

  -- Set filetype based on dominant interpreter
  local ft = detect_dominant_filetype(paragraphs)
  vim.bo[buf].filetype = ft

  -- Keymaps
  local kopts = { nowait = true, noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>r",
    "<cmd>lua require('zeppelin.notebook').run_paragraph()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>w",
    "<cmd>lua require('zeppelin.notebook').save_paragraph()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>W",
    "<cmd>lua require('zeppelin.notebook').save_all()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>o",
    "<cmd>lua require('zeppelin.notebook').toggle_output_at_cursor()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>R",
    "<cmd>lua require('zeppelin.notebook').restart_interpreter()<CR>", kopts)

  -- BufWriteCmd autocmd for :w support
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.save_all()
      vim.bo[buf].modified = false
    end,
  })

  local win = find_edit_window()
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, buf)
end

--------------------------------------------------------------------------------
-- Save
--------------------------------------------------------------------------------

--- Extract the current text of a paragraph from the buffer via extmarks.
---@param bufnr number
---@param para table
---@return string
local function get_paragraph_text(bufnr, para)
  local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.start_extmark, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.end_extmark, {})
  if not start_pos or not end_pos or #start_pos == 0 or #end_pos == 0 then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_pos[1], end_pos[1] + 1, false)
  return table.concat(lines, "\n")
end

--- Save the paragraph under the cursor.
function M.save_paragraph()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = _buffers[bufnr]
  if not state then
    ui.show_popup("Not a Zeppelin notebook buffer!")
    return
  end

  local para = M.get_paragraph_at_cursor(bufnr)
  if not para then
    ui.show_popup("No paragraph found at cursor position!")
    return
  end

  local text = get_paragraph_text(bufnr, para)
  local path = string.format("/api/notebook/%s/paragraph/%s", state.notebook_id, para.id)

  api.put(path, { text = text }, function(err)
    if err then
      ui.show_popup("Failed to save paragraph: " .. err)
      return
    end
    para.original_text = text
    ui.show_popup("Paragraph saved!")
  end)
end

--- Save all modified paragraphs in the current buffer.
function M.save_all()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = _buffers[bufnr]
  if not state then
    ui.show_popup("Not a Zeppelin notebook buffer!")
    return
  end

  local saved = 0
  local errors = 0
  local total = 0

  for _, para in ipairs(state.paragraphs) do
    local text = get_paragraph_text(bufnr, para)
    if text ~= para.original_text then
      total = total + 1
      local path = string.format("/api/notebook/%s/paragraph/%s", state.notebook_id, para.id)
      api.put(path, { text = text }, function(err)
        if err then
          errors = errors + 1
        else
          para.original_text = text
          saved = saved + 1
        end
        if saved + errors == total then
          if errors > 0 then
            ui.show_popup(string.format("Saved %d/%d paragraphs (%d errors)", saved, total, errors))
          else
            ui.show_popup(string.format("Saved %d paragraph(s)!", saved))
          end
        end
      end)
    end
  end

  if total == 0 then
    ui.show_popup("No modified paragraphs to save.")
  end
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

--- Run the paragraph under the cursor.
function M.run_paragraph()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = _buffers[bufnr]
  if not state then
    ui.show_popup("Not a Zeppelin notebook buffer!")
    return
  end

  local para = M.get_paragraph_at_cursor(bufnr)
  if not para then
    ui.show_popup("No paragraph found at cursor position!")
    return
  end

  M.show_running_indicator(bufnr, para)

  local path = string.format("/api/notebook/run/%s/%s", state.notebook_id, para.id)
  api.post(path, {}, function(err, data)
    if err then
      ui.show_popup("Failed to run paragraph: " .. err)
      -- Clear running indicator
      if para.output_extmark then
        vim.api.nvim_buf_del_extmark(bufnr, ns, para.output_extmark)
        para.output_extmark = nil
      end
      return
    end
    M.display_output(bufnr, para, data)
  end)
end

--- Toggle output visibility for paragraph at cursor.
function M.toggle_output_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local para = M.get_paragraph_at_cursor(bufnr)
  if not para then
    ui.show_popup("No paragraph found at cursor position!")
    return
  end
  M.toggle_output(bufnr, para)
end

--------------------------------------------------------------------------------
-- Restart interpreter
--------------------------------------------------------------------------------

--- Restart the interpreter for the current notebook.
function M.restart_interpreter()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = _buffers[bufnr]
  if not state then
    ui.show_popup("Not a Zeppelin notebook buffer!")
    return
  end

  -- First get interpreter settings to find the interpreter ID
  api.get("/api/interpreter/setting", function(err, data)
    if err then
      ui.show_popup("Failed to get interpreter settings: " .. err)
      return
    end

    if not data or type(data) ~= "table" then
      ui.show_popup("No interpreter settings found!")
      return
    end

    -- Find the first interpreter and restart it
    local interpreter_id = nil
    for _, setting in ipairs(data) do
      if setting.id then
        interpreter_id = setting.id
        break
      end
    end

    if not interpreter_id then
      ui.show_popup("No interpreter found to restart!")
      return
    end

    local path = string.format("/api/interpreter/setting/restart/%s", interpreter_id)
    api.put(path, { noteId = state.notebook_id }, function(restart_err)
      if restart_err then
        ui.show_popup("Failed to restart interpreter: " .. restart_err)
        return
      end
      ui.show_popup("Interpreter restarted!")
    end)
  end)
end

--------------------------------------------------------------------------------
-- Public getters for other modules
--------------------------------------------------------------------------------

--- Get the buffer state for a given buffer.
---@param bufnr number|nil
---@return table|nil
function M.get_state(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return _buffers[bufnr]
end

return M
