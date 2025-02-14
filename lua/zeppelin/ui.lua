local M = {}

M.show_popup = function(text, opts)
    opts = opts or {}
    local lines = vim.split(text, "\n", { plain = true })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.api.nvim_buf_set_option(buf, "readonly", true)

    local editor_width = vim.api.nvim_get_option("columns")
    local editor_height = vim.api.nvim_get_option("lines")

    local padding = 4
    local width = opts.width or (editor_width - padding)
    local height = opts.height or (editor_height - padding) 

    local config = {
        relative = "editor",
        width = width,
        height = height,
        row = 2,
        col = math.floor((editor_width - width) / 2),
        style = "minimal",
        border = "rounded",
        focusable = true,
    }

    local win = vim.api.nvim_open_win(buf, true, config)

    vim.api.nvim_buf_set_var(buf, "original_lines", lines)

    if opts.sticky then
        vim.api.nvim_buf_set_keymap(
            buf,
            "n",
            "q",
            "<cmd>close<CR>",
            { nowait = true, noremap = true, silent = true }
        )

        vim.api.nvim_buf_set_keymap(
            buf,
            "n",
            "f",
            "<cmd>lua require('zeppelin.ui').filter_popup(" .. buf .. ")<CR>",
            { nowait = true, noremap = true, silent = true }
        )
    else
        vim.defer_fn(function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end, 1000)
    end
end

M.filter_popup = function(bufnr)
    vim.ui.input({ prompt = "Filter notebooks: " }, function(input)
        if input == nil then
            return
        end

        local ok, orig_lines = pcall(vim.api.nvim_buf_get_var, bufnr, "original_lines")
        if not ok or type(orig_lines) ~= "table" then
            return
        end

        local filtered = {}
        for _, line in ipairs(orig_lines) do
            if line:lower():find(input:lower(), 1, true) then
                table.insert(filtered, line)
            end
        end
        if #filtered == 0 then
            filtered = { "No matches for: " .. input }
        end

        vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, filtered)
        vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
        vim.api.nvim_buf_set_option(bufnr, "readonly", true)
    end)
end

return M
