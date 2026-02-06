local M = {}
local api = require("zeppelin.api")
local notebook = require("zeppelin.notebook")
local ui = require("zeppelin.ui")

--- Open a Telescope picker to search notebooks by path.
function M.search_notebooks()
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    ui.show_popup("Telescope.nvim is required for :ZeppelinSearch")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  api.get("/api/notebook", function(err, data)
    if err then
      ui.show_popup("Failed to fetch notebooks: " .. err)
      return
    end

    if not data or #data == 0 then
      ui.show_popup("No notebooks found!")
      return
    end

    pickers.new({}, {
      prompt_title = "Zeppelin Notebooks",
      finder = finders.new_table({
        results = data,
        entry_maker = function(entry)
          local path = entry.path or entry.name or "Untitled"
          return {
            value = entry,
            display = path,
            ordinal = path .. " " .. (entry.name or ""),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection and selection.value and selection.value.id then
            notebook.fetch_and_open(selection.value.id)
          end
        end)
        return true
      end,
    }):find()
  end)
end

return M
