local M = {}
local api = require("zeppelin.api")
local ui = require("zeppelin.ui")

local ns = vim.api.nvim_create_namespace("zeppelin_paragraphs")

--- Per-buffer notebook state.
--- _buffers[bufnr] = {
---   notebook_id = "...",
---   paragraphs = {
---     { id, original_text, start_extmark, end_extmark, output_start_extmark, output_end_extmark, status_extmark, interpreter, last_output },
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

-- Maps paragraph directive to Zeppelin interpreter setting name (for restart)
local interpreter_setting_map = {
  ["%%pyspark"]  = "spark",
  ["%%python"]   = "python",
  ["%%sql"]      = "spark",
  ["%%sh"]       = "sh",
  ["%%md"]       = "md",
  ["%%angular"]  = "angular",
  ["%%spark"]    = "spark",
}

local status_hl_map = {
  READY    = "ZeppelinStatusReady",
  PENDING  = "ZeppelinStatusPending",
  RUNNING  = "ZeppelinStatusRunning",
  FINISHED = "ZeppelinStatusFinished",
  ERROR    = "ZeppelinStatusError",
  ABORT    = "ZeppelinStatusAbort",
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

--- Place a right-aligned status badge on a paragraph's first line.
---@param bufnr number
---@param para table paragraph metadata
---@param status string e.g. "READY", "RUNNING", "FINISHED", "ERROR"
local function place_status_extmark(bufnr, para, status)
  if para.status_extmark then
    vim.api.nvim_buf_del_extmark(bufnr, ns, para.status_extmark)
    para.status_extmark = nil
  end

  local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.start_extmark, {})
  if not start_pos or #start_pos == 0 then
    return
  end

  local hl = status_hl_map[status] or "ZeppelinStatusReady"
  para.status = status
  para.status_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, start_pos[1], 0, {
    virt_text = { { " " .. status .. " ", hl } },
    virt_text_pos = "right_align",
  })
end

--------------------------------------------------------------------------------
-- Output display
--------------------------------------------------------------------------------

--- Strip ANSI escape sequences from a string.
---@param s string
---@return string
local function strip_ansi(s)
  return s:gsub("\27%[[%d;]*[A-Za-z]", "")
end

--- Build plain text lines from Zeppelin output msg array.
---@param output_data table Zeppelin response body with msg array
---@return string[] lines, string hl_group
local function build_output_lines(output_data)
  local lines = {}
  table.insert(lines, "── Output ──")

  local code = output_data.code or "UNKNOWN"
  local hl = (code == "ERROR") and "ZeppelinOutputError" or "ZeppelinOutput"

  if output_data.msg and type(output_data.msg) == "table" then
    for _, item in ipairs(output_data.msg) do
      if item.data then
        for _, text_line in ipairs(vim.split(item.data, "\n", { plain = true })) do
          table.insert(lines, (strip_ansi(text_line)))
        end
      end
    end
  else
    table.insert(lines, "(no output)")
  end

  return lines, hl
end

--- Remove output lines from the buffer for a paragraph.
---@param bufnr number
---@param para table
local function remove_output_lines(bufnr, para)
  if not para.output_start_extmark or not para.output_end_extmark then
    return
  end

  local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.output_start_extmark, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.output_end_extmark, {})

  if start_pos and end_pos and #start_pos > 0 and #end_pos > 0 then
    vim.api.nvim_buf_set_lines(bufnr, start_pos[1], end_pos[1] + 1, false, {})
  end

  vim.api.nvim_buf_del_extmark(bufnr, ns, para.output_start_extmark)
  vim.api.nvim_buf_del_extmark(bufnr, ns, para.output_end_extmark)
  para.output_start_extmark = nil
  para.output_end_extmark = nil
end

--- Insert output lines into the buffer after a paragraph and track with extmarks.
---@param bufnr number
---@param para table paragraph metadata entry
---@param lines string[] lines to insert
---@param header_hl string highlight for the header line
---@param body_hl string highlight for body lines
local function insert_output_lines(bufnr, para, lines, header_hl, body_hl)
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.end_extmark, {})
  if not end_pos or #end_pos == 0 then
    return
  end

  local insert_at = end_pos[1] + 1
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)

  -- Place extmarks around the inserted lines
  para.output_start_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, insert_at, 0, {
    right_gravity = false,
  })
  para.output_end_extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, insert_at + #lines - 1, 0, {
    right_gravity = true,
  })

  -- Apply highlights
  for j = 0, #lines - 1 do
    local hl_group = (j == 0) and header_hl or body_hl
    vim.api.nvim_buf_add_highlight(bufnr, ns, hl_group, insert_at + j, 0, -1)
  end
end

--- Display output inline below a paragraph as real buffer lines.
---@param bufnr number
---@param para table paragraph metadata entry
---@param output_data table Zeppelin response body
function M.display_output(bufnr, para, output_data)
  remove_output_lines(bufnr, para)

  para.last_output = output_data
  para.output_visible = true

  local lines, hl = build_output_lines(output_data)
  insert_output_lines(bufnr, para, lines, "ZeppelinOutputHeader", hl)
end

--- Show "Running..." indicator as a real buffer line.
---@param bufnr number
---@param para table
function M.show_running_indicator(bufnr, para)
  remove_output_lines(bufnr, para)
  insert_output_lines(bufnr, para, { "  Running..." }, "ZeppelinRunning", "ZeppelinRunning")
end

--- Toggle output visibility for a paragraph.
---@param bufnr number
---@param para table
function M.toggle_output(bufnr, para)
  if para.output_start_extmark then
    remove_output_lines(bufnr, para)
    para.output_visible = false
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
      -- Check paragraph code lines
      if cursor_line >= start_pos[1] and cursor_line <= end_pos[1] then
        return para, i
      end
      -- Check output lines (cursor in output belongs to this paragraph)
      if para.output_start_extmark and para.output_end_extmark then
        local out_start = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.output_start_extmark, {})
        local out_end = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.output_end_extmark, {})
        if out_start and out_end and #out_start > 0 and #out_end > 0 then
          if cursor_line >= out_start[1] and cursor_line <= out_end[1] then
            return para, i
          end
        end
      end
    end
  end

  return nil, nil
end

--- Jump to the next paragraph.
function M.jump_next_paragraph()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, idx = M.get_paragraph_at_cursor(bufnr)
  local state = _buffers[bufnr]
  if not state then return end

  local target = (idx and idx < #state.paragraphs) and (idx + 1) or 1
  local para = state.paragraphs[target]
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.start_extmark, {})
  if pos and #pos > 0 then
    vim.api.nvim_win_set_cursor(0, { pos[1] + 1, 0 })
  end
end

--- Jump to the previous paragraph.
function M.jump_prev_paragraph()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, idx = M.get_paragraph_at_cursor(bufnr)
  local state = _buffers[bufnr]
  if not state then return end

  local target = (idx and idx > 1) and (idx - 1) or #state.paragraphs
  local para = state.paragraphs[target]
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, para.start_extmark, {})
  if pos and #pos > 0 then
    vim.api.nvim_win_set_cursor(0, { pos[1] + 1, 0 })
  end
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
      output_start_extmark = nil,
      output_end_extmark = nil,
      output_visible = false,
      status_extmark = nil,
      status = p.status or "READY",
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

    place_status_extmark(bufnr, meta, meta.status)

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

--- Find a suitable editing window (not the tree sidebar).
--- Prefers a normal buffer window, but will reuse dashboard/empty windows
--- rather than creating splits.
---@return number win_id
local function find_edit_window()
  local cur_win = vim.api.nvim_get_current_win()
  local all_wins = vim.api.nvim_tabpage_list_wins(0)

  -- First pass: find an existing normal editing window (not tree, not current)
  for _, win in ipairs(all_wins) do
    if win ~= cur_win then
      local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
      if ft ~= "zeppelin_tree" then
        return win
      end
    end
  end

  -- Second pass: use current window if it's not the tree
  local cur_ft = vim.bo[vim.api.nvim_win_get_buf(cur_win)].filetype
  if cur_ft ~= "zeppelin_tree" then
    return cur_win
  end

  -- Last resort: pick any non-tree window
  for _, win in ipairs(all_wins) do
    local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if ft ~= "zeppelin_tree" then
      return win
    end
  end

  return cur_win
end

--- Close any floating windows (dashboard overlays, popups, etc.)
local function dismiss_floating_wins()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Open a notebook from its JSON data. Creates or switches to the buffer.
---@param notebook_json table
function M.open_notebook(notebook_json)
  local paragraphs = notebook_json.paragraphs or {}
  local notebook_id = notebook_json.id or "unknown"

  -- Auto-create a first paragraph for empty notebooks
  if #paragraphs == 0 then
    local path = string.format("/api/notebook/%s/paragraph", notebook_id)
    api.post(path, { title = "", text = "", index = 0 }, function(err)
      if err then
        ui.show_popup("Failed to create initial paragraph: " .. err)
        return
      end
      M.fetch_and_open(notebook_id)
    end)
    return
  end

  dismiss_floating_wins()

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
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>a",
    "<cmd>lua require('zeppelin.notebook').create_paragraph()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>y",
    "<cmd>lua require('zeppelin.notebook').yank_paragraph()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<S-Down>",
    "<cmd>lua require('zeppelin.notebook').jump_next_paragraph()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<S-Up>",
    "<cmd>lua require('zeppelin.notebook').jump_prev_paragraph()<CR>", kopts)

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

--- Yank the current paragraph text to the system clipboard.
function M.yank_paragraph()
  local bufnr = vim.api.nvim_get_current_buf()
  local para = M.get_paragraph_at_cursor(bufnr)
  if not para then
    ui.show_popup("No paragraph found at cursor position!")
    return
  end
  local text = get_paragraph_text(bufnr, para)
  vim.fn.setreg("+", text)
  ui.show_popup("Paragraph yanked!")
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

  -- Auto-save before running (fire-and-forget)
  local text = get_paragraph_text(bufnr, para)
  local save_path = string.format("/api/notebook/%s/paragraph/%s", state.notebook_id, para.id)
  api.put(save_path, { text = text }, function(save_err)
    if not save_err then
      para.original_text = text
    end
  end)

  M.show_running_indicator(bufnr, para)
  place_status_extmark(bufnr, para, "RUNNING")

  local path = string.format("/api/notebook/run/%s/%s", state.notebook_id, para.id)
  api.post(path, {}, function(err, data)
    if err then
      ui.show_popup("Failed to run paragraph: " .. err)
      place_status_extmark(bufnr, para, "ERROR")
      -- Clear running indicator
      remove_output_lines(bufnr, para)
      return
    end
    if data then
      local result_status = (data.code == "ERROR") and "ERROR" or "FINISHED"
      place_status_extmark(bufnr, para, result_status)
      M.display_output(bufnr, para, data)
    end
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

--- Detect the Zeppelin interpreter setting name from paragraph text.
---@param text string
---@return string setting_name
local function detect_interpreter_setting(text)
  local first_line = text:match("^([^\n]*)")
  if first_line then
    first_line = vim.trim(first_line)
    for prefix, setting in pairs(interpreter_setting_map) do
      if first_line:match("^" .. vim.pesc(prefix)) then
        return setting
      end
    end
  end
  return "spark"
end

--- Restart the interpreter for the paragraph under the cursor.
function M.restart_interpreter()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = _buffers[bufnr]
  if not state then
    ui.show_popup("Not a Zeppelin notebook buffer!")
    return
  end

  local para = M.get_paragraph_at_cursor(bufnr)
  local setting_name = "spark"
  if para then
    local text = get_paragraph_text(bufnr, para)
    setting_name = detect_interpreter_setting(text)
  end

  local path = string.format("/api/interpreter/setting/restart/%s", setting_name)
  api.put(path, { noteId = state.notebook_id }, function(err)
    if err then
      ui.show_popup("Failed to restart interpreter: " .. err)
      return
    end
    ui.show_popup("Interpreter '" .. setting_name .. "' restarted!")
  end)
end

--------------------------------------------------------------------------------
-- Create new paragraph
--------------------------------------------------------------------------------

--- Create a new empty paragraph after the one under the cursor.
function M.create_paragraph()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = _buffers[bufnr]
  if not state then
    ui.show_popup("Not a Zeppelin notebook buffer!")
    return
  end

  local _, idx = M.get_paragraph_at_cursor(bufnr)
  local insert_index = idx and idx or #state.paragraphs

  local path = string.format("/api/notebook/%s/paragraph", state.notebook_id)
  api.post(path, { title = "", text = "", index = insert_index }, function(err)
    if err then
      ui.show_popup("Failed to create paragraph: " .. err)
      return
    end
    -- Re-fetch and re-render the notebook in place
    api.get("/api/notebook/" .. state.notebook_id, function(fetch_err, data)
      if fetch_err then
        ui.show_popup("Failed to refresh notebook: " .. fetch_err)
        return
      end
      local paragraphs = (data and data.paragraphs) or {}
      if #paragraphs == 0 then
        return
      end
      M.render_notebook(bufnr, paragraphs, state.notebook_id)
      ui.show_popup("New paragraph created!")
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
