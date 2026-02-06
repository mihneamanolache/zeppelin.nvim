local M = {}
local api = require("zeppelin.api")
local notebook = require("zeppelin.notebook")
local ui = require("zeppelin.ui")

local _tree_buf = nil
local _tree_win = nil
local _root = nil
local _expanded_paths = {}
local _flat_list = {}

local TREE_WIDTH = 35

--------------------------------------------------------------------------------
-- Data model
--------------------------------------------------------------------------------

--- Build a nested tree from a flat notebook list.
--- Each notebook has { id, name, path } where path looks like "/folder/subfolder/name".
---@param notebook_list table[]
---@return table root node
local function build_tree(notebook_list)
  local root = { name = "Notebooks", path = "/", is_folder = true, expanded = true, children = {} }

  for _, nb in ipairs(notebook_list) do
    local full_path = nb.path or nb.name or "Untitled"
    local parts = vim.split(full_path, "/", { trimempty = true })

    local current = root
    for i, part in ipairs(parts) do
      if i == #parts then
        -- Leaf notebook node
        table.insert(current.children, {
          name = part,
          path = full_path,
          is_folder = false,
          expanded = false,
          children = {},
          notebook_id = nb.id,
        })
      else
        -- Folder node — find existing or create
        local folder_path = "/" .. table.concat({ unpack(parts, 1, i) }, "/")
        local found = nil
        for _, child in ipairs(current.children) do
          if child.is_folder and child.path == folder_path then
            found = child
            break
          end
        end
        if not found then
          found = {
            name = part,
            path = folder_path,
            is_folder = true,
            expanded = _expanded_paths[folder_path] or false,
            children = {},
            notebook_id = nil,
          }
          table.insert(current.children, found)
        end
        current = found
      end
    end
  end

  return root
end

--- Sort tree children: folders first (alphabetical), then notebooks (alphabetical).
---@param node table
local function sort_tree(node)
  if not node.children or #node.children == 0 then
    return
  end
  table.sort(node.children, function(a, b)
    if a.is_folder ~= b.is_folder then
      return a.is_folder
    end
    return (a.name or ""):lower() < (b.name or ""):lower()
  end)
  for _, child in ipairs(node.children) do
    sort_tree(child)
  end
end

--- Flatten the tree into visible display lines.
---@param node table root node
---@param depth number current indentation depth
---@return table[] flat list of { display, node, depth }
local function flatten_tree(node, depth)
  depth = depth or 0
  local result = {}

  -- Skip root node itself in display; show its children at depth 0
  if depth == 0 and node.name == "Notebooks" then
    for _, child in ipairs(node.children) do
      local sub = flatten_tree(child, 0)
      for _, item in ipairs(sub) do
        table.insert(result, item)
      end
    end
    return result
  end

  local indent = string.rep("  ", depth)
  local icon, display

  if node.is_folder then
    icon = node.expanded and "▼ " or "▶ "
    display = indent .. icon .. node.name
  else
    display = indent .. "  " .. node.name
  end

  table.insert(result, { display = display, node = node, depth = depth })

  if node.is_folder and node.expanded then
    for _, child in ipairs(node.children) do
      local sub = flatten_tree(child, depth + 1)
      for _, item in ipairs(sub) do
        table.insert(result, item)
      end
    end
  end

  return result
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

--- Render the tree into the tree buffer.
local function render()
  if not _tree_buf or not vim.api.nvim_buf_is_valid(_tree_buf) then
    return
  end
  if not _root then
    return
  end

  sort_tree(_root)
  _flat_list = flatten_tree(_root)

  local lines = {}
  for _, item in ipairs(_flat_list) do
    table.insert(lines, item.display)
  end

  if #lines == 0 then
    lines = { "  (no notebooks)" }
  end

  vim.bo[_tree_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_tree_buf, 0, -1, false, lines)
  vim.bo[_tree_buf].modifiable = false

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(_tree_buf, -1, 0, -1)
  for i, item in ipairs(_flat_list) do
    if item.node.is_folder then
      vim.api.nvim_buf_add_highlight(_tree_buf, -1, "ZeppelinFolder", i - 1, 0, -1)
    else
      vim.api.nvim_buf_add_highlight(_tree_buf, -1, "ZeppelinNotebook", i - 1, 0, -1)
    end
  end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Handle <CR> press — toggle folder or open notebook.
function M.on_enter()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local item = _flat_list[line]
  if not item then
    return
  end

  local node = item.node
  if node.is_folder then
    node.expanded = not node.expanded
    if node.expanded then
      _expanded_paths[node.path] = true
    else
      _expanded_paths[node.path] = nil
    end
    render()
  elseif node.notebook_id then
    M.close()
    notebook.fetch_and_open(node.notebook_id)
  end
end

--- Handle `a` press — create a new notebook.
function M.on_create()
  vim.ui.input({ prompt = "New notebook path: " }, function(input)
    if not input or input == "" then
      return
    end
    api.post("/api/notebook", { name = input }, function(err)
      if err then
        ui.show_popup("Failed to create notebook: " .. err)
        return
      end
      ui.show_popup("Notebook created: " .. input)
      M.refresh()
    end)
  end)
end

--- Refresh the tree (re-fetch notebooks, preserve expanded state).
function M.refresh()
  api.get("/api/notebook", function(err, data)
    if err then
      ui.show_popup("Failed to fetch notebooks: " .. err)
      return
    end
    _root = build_tree(data or {})
    -- Restore expanded state
    local function restore_expanded(node)
      if node.is_folder and _expanded_paths[node.path] then
        node.expanded = true
      end
      for _, child in ipairs(node.children or {}) do
        restore_expanded(child)
      end
    end
    restore_expanded(_root)
    render()
  end)
end

--------------------------------------------------------------------------------
-- Window management
--------------------------------------------------------------------------------

--- Create the tree buffer if it doesn't exist.
local function ensure_buf()
  if _tree_buf and vim.api.nvim_buf_is_valid(_tree_buf) then
    return
  end

  _tree_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[_tree_buf].buftype = "nofile"
  vim.bo[_tree_buf].bufhidden = "hide"
  vim.bo[_tree_buf].swapfile = false
  vim.bo[_tree_buf].filetype = "zeppelin_tree"
  vim.bo[_tree_buf].modifiable = false

  local kopts = { nowait = true, noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(_tree_buf, "n", "<CR>",
    "<cmd>lua require('zeppelin.tree').on_enter()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(_tree_buf, "n", "a",
    "<cmd>lua require('zeppelin.tree').on_create()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(_tree_buf, "n", "R",
    "<cmd>lua require('zeppelin.tree').refresh()<CR>", kopts)
  vim.api.nvim_buf_set_keymap(_tree_buf, "n", "q",
    "<cmd>lua require('zeppelin.tree').close()<CR>", kopts)
end

--- Open the tree window.
function M.open()
  ensure_buf()

  -- If already open, just focus it
  if _tree_win and vim.api.nvim_win_is_valid(_tree_win) then
    vim.api.nvim_set_current_win(_tree_win)
    M.refresh()
    return
  end

  -- Create left vsplit
  vim.cmd("topleft " .. TREE_WIDTH .. "vsplit")
  _tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(_tree_win, _tree_buf)

  -- Window options
  vim.wo[_tree_win].number = false
  vim.wo[_tree_win].relativenumber = false
  vim.wo[_tree_win].signcolumn = "no"
  vim.wo[_tree_win].foldcolumn = "0"
  vim.wo[_tree_win].wrap = false
  vim.wo[_tree_win].cursorline = true
  vim.wo[_tree_win].winfixwidth = true

  M.refresh()
end

--- Close the tree window.
function M.close()
  if _tree_win and vim.api.nvim_win_is_valid(_tree_win) then
    vim.api.nvim_win_close(_tree_win, true)
  end
  _tree_win = nil
end

--- Toggle the tree sidebar.
function M.toggle()
  if _tree_win and vim.api.nvim_win_is_valid(_tree_win) then
    M.close()
  else
    M.open()
  end
end

return M
