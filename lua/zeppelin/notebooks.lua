-- lua/zeppelin/notebooks.lua
local M = {}
local Job = require("plenary.job")
local nb = require("zeppelin.notebook")
local config = require("zeppelin.config")

M.COOKIE_FILE = vim.fn.stdpath("cache") .. "/zeppelin_cookies.txt"

-------------------------------------------------------------------------------
-- JSON decode helper
-------------------------------------------------------------------------------
local function decode_json(str)
    local decode = vim.json_decode or vim.fn.json_decode
    local ok, data = pcall(decode, str)
    return ok and data or nil
end

-------------------------------------------------------------------------------
-- 1) Main entry: fetch the list of all notebooks
-------------------------------------------------------------------------------
function M.fetch_notebooks()
    local args = {
        "-b", M.COOKIE_FILE,
        config.options.ZEPPELIN_URL .. "/api/notebook",
    }

    if config.options.SOCKS5_PROXY and config.options.SOCKS5_PROXY ~= "" then
        table.insert(args, 1, config.options.SOCKS5_PROXY)
        table.insert(args, 1, "--socks5-hostname")
    end
    Job:new({
        command = "curl",
        args = args,
        on_exit = function(j, return_val)
            vim.schedule(function()
                if return_val ~= 0 then
                    vim.notify("Failed to fetch notebooks (curl error)!", vim.log.levels.ERROR)
                    return
                end

                local response = table.concat(j:result(), "\n")
                local data = decode_json(response)
                if not data or data.status ~= "OK" or not data.body then
                    vim.notify("Failed to parse Zeppelin notebooks!\n\n" .. response, vim.log.levels.ERROR)
                    return
                end
                M.show_notebook_list(data.body)
            end)
        end,
    }):start()
end

-------------------------------------------------------------------------------
-- 2) Show the notebook list in a scratch buffer
-------------------------------------------------------------------------------
function M.show_notebook_list(notebooks)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "Zeppelin Notebooks")
    vim.api.nvim_buf_set_option(buf, "filetype", "zeppelin_notelist")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

    vim.api.nvim_buf_set_var(buf, "zeppelin_notebook_original_data", notebooks)
    vim.api.nvim_buf_set_var(buf, "zeppelin_notebook_current_list", notebooks)

    M.render_notebook_lines(buf, notebooks)

    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "<CR>",
        "<cmd>lua require('zeppelin.notebooks').open_selected_notebook()<CR>",
        { nowait = true, noremap = true, silent = true }
    )

    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "f",
        "<cmd>lua require('zeppelin.notebooks').filter_notebooks()<CR>",
        { nowait = true, noremap = true, silent = true }
    )

    vim.api.nvim_set_current_buf(buf)
end

function M.render_notebook_lines(bufnr, notebook_list)
    if not notebook_list or #notebook_list == 0 then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "No notebooks found." })
        return
    end

    local lines = {}
    for _, nb in ipairs(notebook_list) do
        local name = nb.name or ("Untitled ID:" .. (nb.id or "?"))
        local path = nb.path or ""
        table.insert(lines, string.format("%s | %s", name, path))
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-------------------------------------------------------------------------------
-- 3) Filter the currently displayed notebooks
-------------------------------------------------------------------------------
function M.filter_notebooks()
    local buf = vim.api.nvim_get_current_buf()

    vim.ui.input({ prompt = "Filter notebooks: " }, function(input)
        if not input then
            return
        end

        local ok1, original_data = pcall(vim.api.nvim_buf_get_var, buf, "zeppelin_notebook_original_data")
        if not ok1 or not original_data then
            return
        end

        if input == "" then
            vim.api.nvim_buf_set_var(buf, "zeppelin_notebook_current_list", original_data)
            M.render_notebook_lines(buf, original_data)
            return
        end

        local filtered = {}
        for _, nb in ipairs(original_data) do
            local name = nb.name or ("Untitled ID:" .. (nb.id or "?"))
            local path = nb.path or ""
            local line = (name .. " | " .. path):lower()
            if line:find(input:lower(), 1, true) then
                table.insert(filtered, nb)
            end
        end

        vim.api.nvim_buf_set_var(buf, "zeppelin_notebook_current_list", filtered)
        M.render_notebook_lines(buf, filtered)
    end)
end

-------------------------------------------------------------------------------
-- 4) Open the selected line's notebook
-------------------------------------------------------------------------------
function M.open_selected_notebook()
    local buf = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]  -- (row, col) => row is line#
    local ok, current_list = pcall(vim.api.nvim_buf_get_var, buf, "zeppelin_notebook_current_list")
    if not ok or type(current_list) ~= "table" or #current_list == 0 then
        vim.notify("No notebooks to open.", vim.log.levels.ERROR)
        return
    end

    if line < 1 or line > #current_list then
        vim.notify("Invalid line: " .. line, vim.log.levels.ERROR)
        return
    end

    local nb = current_list[line]
    if not nb or not nb.id then
        vim.notify("No valid notebook ID on this line.", vim.log.levels.ERROR)
        return
    end

    M.fetch_and_open_notebook(nb.id)
end

-------------------------------------------------------------------------------
-- 5) Fetch /api/notebook/<ID> and open
-------------------------------------------------------------------------------
function M.fetch_and_open_notebook(notebook_id)
    local args = {
        "-b", M.COOKIE_FILE,
        config.options.ZEPPELIN_URL .. "/api/notebook/" .. notebook_id,
    }
    if config.options.SOCKS5_PROXY and config.options.SOCKS5_PROXY ~= "" then
        table.insert(args, 1, config.options.SOCKS5_PROXY)
        table.insert(args, 1, "--socks5-hostname")
    end
    Job:new({
        command = "curl",
        args = args,
        on_exit = function(j, return_val)
            vim.schedule(function()
                if return_val ~= 0 then
                    vim.notify("Failed to fetch notebook " .. notebook_id .. " (curl error)!", vim.log.levels.ERROR)
                    return
                end

                local response = table.concat(j:result(), "\n")
                local data = decode_json(response)
                if not data or data.status ~= "OK" or not data.body then
                    vim.notify("Failed to parse single notebook " .. notebook_id .. "!\n\n" .. response, vim.log.levels.ERROR)
                    return
                end

                nb.open_notebook_slideshow(data.body)
            end)
        end,
    }):start()
end

-------------------------------------------------------------------------------
-- 6) Open the fetched notebook JSON
-------------------------------------------------------------------------------
function M.open_notebook_in_buffer(notebook_json)
    local buf = vim.api.nvim_create_buf(false, true)
    local ephemeral_name = string.format("zep-%s.zeppelin", notebook_json.id or "unknown")
    vim.api.nvim_buf_set_name(buf, ephemeral_name)
    vim.api.nvim_buf_set_option(buf, "filetype", "zeppelin")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    local raw_json = vim.fn.json_encode(notebook_json)
    local lines = {}
    for s in raw_json:gmatch("[^\r\n]+") do
        table.insert(lines, s)
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
end

return M
