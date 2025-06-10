local M = {}
local Job = require("plenary.job")
local ui = require("zeppelin.ui")
local config = require("zeppelin.config")

M.COOKIE_FILE = vim.fn.stdpath("cache") .. "/zeppelin_cookies.txt"

--------------------------------------------------------------------------------
-- JSON decode helper
--------------------------------------------------------------------------------
local function decode_json(str)
    local decode = vim.json_decode or vim.fn.json_decode
    local ok, data = pcall(decode, str)
    return ok and data or nil
end

--------------------------------------------------------------------------------
-- Detect the paragraph's interpreter => filetype
--------------------------------------------------------------------------------
local function detect_interpreter(code_text)
    if code_text:match("^%%pyspark") then
        return "python"
    elseif code_text:match("^%.conf") then
        return "python"
    else
        return "scala"
    end
end

--------------------------------------------------------------------------------
-- Render a single paragraph in the buffer
--------------------------------------------------------------------------------
local function render_paragraph(bufnr, paragraphs, index)
    if index < 1 then index = 1 end
    if index > #paragraphs then index = #paragraphs end

    local paragraph = paragraphs[index]
    local code_text = paragraph.text or ""
    local lines = {}
    if code_text == "" then
        table.insert(lines, "  (no code)")
    else
        for _, cl in ipairs(vim.split(code_text, "\n", { plain = true })) do
            table.insert(lines, "" .. cl)
        end
    end

    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(bufnr, "filetype", detect_interpreter(code_text))
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    local clients = vim.lsp.buf_get_clients(bufnr) 
    if #clients > 0 then
        for _, client in ipairs(clients) do
            if not vim.lsp.buf_is_attached(bufnr, client.id) then
                local success = vim.lsp.buf_attach_client(bufnr, client.id)
                if not success then
                    vim.notify("Failed to attach LSP client to buffer!", vim.log.levels.WARN)
                end
            end
        end
    else
        vim.notify("No active LSP clients for this buffer.", vim.log.levels.INFO)
    end
    vim.api.nvim_buf_set_var(bufnr, "zeppelin_paragraph_index", index)
end

--------------------------------------------------------------------------------
-- Next paragraph
--------------------------------------------------------------------------------
function M.next_paragraph()
    local bufnr = vim.api.nvim_get_current_buf()
    local ok1, paragraphs = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraphs")
    local ok2, idx = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraph_index")
    if not (ok1 and ok2) then return end

    if idx < #paragraphs then
        render_paragraph(bufnr, paragraphs, idx + 1)
    else
        vim.notify("Already at last paragraph!", vim.log.levels.INFO)
    end
end

--------------------------------------------------------------------------------
-- Previous paragraph
--------------------------------------------------------------------------------
function M.prev_paragraph()
    local bufnr = vim.api.nvim_get_current_buf()
    local ok1, paragraphs = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraphs")
    local ok2, idx = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraph_index")
    if not (ok1 and ok2) then return end

    if idx > 1 then
        render_paragraph(bufnr, paragraphs, idx - 1)
    else
        vim.notify("Already at first paragraph!", vim.log.levels.INFO)
    end
end

--------------------------------------------------------------------------------
-- Save current paragraph changes
--------------------------------------------------------------------------------
function M.save_current_paragraph()
    local bufnr = vim.api.nvim_get_current_buf()
    local ok1, paragraphs = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraphs")
    local ok2, idx = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraph_index")
    local ok3, notebookId = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_notebook_id")
    if not (ok1 and ok2 and ok3) then
        ui.show_popup("Cannot save paragraph: missing data!", { width = 60, height = 5 })
        return
    end

    local paragraph = paragraphs[idx]
    if not paragraph or not paragraph.id then
        ui.show_popup("Paragraph missing an ID—can't save!", { width = 50, height = 5 })
        return
    end

    local paragraphId = paragraph.id
    local saveUrl = string.format("%s/api/notebook/%s/paragraph/%s", config.options.ZEPPELIN_URL, notebookId, paragraphId)

    -- Get updated code from buffer
    local new_code = table.concat(vim.api.nvim_buf_get_lines(bufnr, 1, -1, false), "\n")

    local payload = vim.fn.json_encode({ text = new_code })

    local args = {
        "-X", "PUT",
        "-b", M.COOKIE_FILE,
        "-H", "Content-Type: application/json",
        "--data-binary", payload,
        saveUrl,
    }
    if config.options.SOCKS5_PROXY and config.options.SOCKS5_PROXY ~= "" then
        table.insert(args, 1, config.options.SOCKS5_PROXY)
        table.insert(args, 1, "--socks5-hostname")
    end

    Job:new({
        command = "curl",
        args = args,
        on_exit = function(job, return_val)
            vim.schedule(function()
                if return_val ~= 0 then
                    local stdout_str = table.concat(job:result(), "\n")
                    local stderr_str = table.concat(job:stderr_result(), "\n")
                    ui.show_popup(
                        "Failed to save paragraph (curl error).\n" ..
                        "Return code: " .. return_val .. "\n\n" ..
                        "STDOUT:\n" .. stdout_str .. "\n\n" ..
                        "STDERR:\n" .. stderr_str,
                        { width = 80, height = 20 }
                    )
                    return
                end

                local response = table.concat(job:result(), "\n")
                local data = decode_json(response)
                if not data or data.status ~= "OK" then
                    ui.show_popup("Failed to save paragraph!\n\n" .. response, { width = 80, height = 10 })
                    return
                end

                ui.show_popup("Paragraph saved successfully!", { width = 40, height = 5 })
            end)
        end,
    }):start()
end

--------------------------------------------------------------------------------
-- Run current paragraph (Zeppelin 0.7.0 synchronous):
--------------------------------------------------------------------------------
function M.run_current_paragraph()
    local bufnr = vim.api.nvim_get_current_buf()

    local ok1, paragraphs = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraphs")
    local ok2, idx = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraph_index")
    local ok3, notebookId = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_notebook_id")
    if not (ok1 and ok2 and ok3) then
        ui.show_popup("Cannot run paragraph: missing data!", { width = 60, height = 5 })
        return
    end

    local paragraph = paragraphs[idx]
    if not paragraph or not paragraph.id then
        ui.show_popup("Paragraph missing an ID—can't run!", { width = 50, height = 5 })
        return
    end

    local paragraphId = paragraph.id
    local runUrl = string.format("%s/api/notebook/run/%s/%s", config.options.ZEPPELIN_URL, notebookId, paragraphId)

    ui.show_popup("Running paragraph... Please wait for output.")

    local args = {
        "-X", "POST",
        "-b", M.COOKIE_FILE,
        "-H", "Content-Type: application/json",
        "--data-binary", "{}",
        runUrl,
    }
    if config.options.SOCKS5_PROXY and config.options.SOCKS5_PROXY ~= "" then
        table.insert(args, 1, config.options.SOCKS5_PROXY)
        table.insert(args, 1, "--socks5-hostname")
    end

    Job:new({
        command = "curl",
        args = args,
        on_exit = function(job, return_val)
            vim.schedule(function()
                if return_val ~= 0 then
                    local stdout_str = table.concat(job:result(), "\n")
                    local stderr_str = table.concat(job:stderr_result(), "\n")
                    ui.show_popup(
                        "Failed to run paragraph (curl error).\n" ..
                        "Return code: " .. return_val .. "\n\n" ..
                        "STDOUT:\n" .. stdout_str .. "\n\n" ..
                        "STDERR:\n" .. stderr_str,
                        { width = 80, height = 20 }
                    )
                    return
                end

                local response = table.concat(job:result(), "\n")
                local data = decode_json(response)
                if not data or data.status ~= "OK" then
                    ui.show_popup("Failed to run paragraph!\n\n" .. response, { width = 80, height = 10 })
                    return
                end

                local body = data.body or {}
                local code = body.code or "(no code)"
                local msg = "No output"

                if body.msg and type(body.msg) == "table" then
                    local output_lines = {}
                    for _, item in ipairs(body.msg) do
                        if item.type and item.data then
                            table.insert(output_lines, "[" .. item.type .. "] " .. item.data)
                        end
                    end
                    msg = table.concat(output_lines, "\n")
                end

                ui.show_popup(string.format("Paragraph %s => %s\n\n%s", paragraphId, code, msg), { sticky = true, padding = 10 })
            end)
        end,
    }):start()
end

--------------------------------------------------------------------------------
-- Create a new empty paragraph after the current one
--------------------------------------------------------------------------------
function M.new_paragraph()
    local bufnr = vim.api.nvim_get_current_buf()
    local ok1, paragraphs = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraphs")
    local ok2, idx = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_paragraph_index")
    local ok3, notebookId = pcall(vim.api.nvim_buf_get_var, bufnr, "zeppelin_notebook_id")
    if not (ok1 and ok2 and ok3) then
        ui.show_popup("Cannot add paragraph: missing data!", { width = 60, height = 5 })
        return
    end

    local createUrl = string.format("%s/api/notebook/%s/paragraph", config.options.ZEPPELIN_URL, notebookId)
    local payload = vim.fn.json_encode({ title = "", text = "", index = idx })

    local args = {
        "-X", "POST",
        "-b", M.COOKIE_FILE,
        "-H", "Content-Type: application/json",
        "--data-binary", payload,
        createUrl,
    }
    if config.options.SOCKS5_PROXY and config.options.SOCKS5_PROXY ~= "" then
        table.insert(args, 1, config.options.SOCKS5_PROXY)
        table.insert(args, 1, "--socks5-hostname")
    end

    Job:new({
        command = "curl",
        args = args,
        on_exit = function(job, return_val)
            vim.schedule(function()
                if return_val ~= 0 then
                    local stdout_str = table.concat(job:result(), "\n")
                    local stderr_str = table.concat(job:stderr_result(), "\n")
                    ui.show_popup(
                        "Failed to add paragraph (curl error).\n" ..
                        "Return code: " .. return_val .. "\n\n" ..
                        "STDOUT:\n" .. stdout_str .. "\n\n" ..
                        "STDERR:\n" .. stderr_str,
                        { width = 80, height = 20 }
                    )
                    return
                end

                local response = table.concat(job:result(), "\n")
                local data = decode_json(response)
                if not data or data.status ~= "OK" or not data.body then
                    ui.show_popup("Failed to add paragraph!\n\n" .. response, { width = 80, height = 10 })
                    return
                end

                local new_paragraph = { id = data.body, text = "" }
                table.insert(paragraphs, idx + 1, new_paragraph)
                vim.api.nvim_buf_set_var(bufnr, "zeppelin_paragraphs", paragraphs)
                render_paragraph(bufnr, paragraphs, idx + 1)

                ui.show_popup("Paragraph added successfully!", { width = 40, height = 5 })
            end)
        end,
    }):start()
end

--------------------------------------------------------------------------------
-- Create a slideshow buffer
--------------------------------------------------------------------------------
function M.open_notebook_slideshow(notebook_json)
    local paragraphs = notebook_json.paragraphs or {}
    if #paragraphs == 0 then
        vim.notify("No paragraphs in notebook!", vim.log.levels.INFO)
        return
    end

    -- Create ephemeral buffer
    local buf = vim.api.nvim_create_buf(false, true)
    local ephemeral_name = string.format("zep-%s.zeppelin", notebook_json.id or "unknown")
    vim.api.nvim_buf_set_name(buf, ephemeral_name)

    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "readonly", false)
    vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")

    vim.api.nvim_buf_set_var(buf, "zeppelin_paragraphs", paragraphs)
    vim.api.nvim_buf_set_var(buf, "zeppelin_paragraph_index", 1)
    vim.api.nvim_buf_set_var(buf, "zeppelin_notebook_id", notebook_json.id or "unknown")

    render_paragraph(buf, paragraphs, 1)

    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "<leader><Right>",
        "<cmd>lua require('zeppelin.notebook').next_paragraph()<CR>",
        { nowait = true, noremap = true, silent = true }
    )
    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "<leader><Left>",
        "<cmd>lua require('zeppelin.notebook').prev_paragraph()<CR>",
        { nowait = true, noremap = true, silent = true }
    )

    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "<leader>r",
        "<cmd>ZeppelinRun<CR>",
        { nowait = true, noremap = true, silent = true }
    )

    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "<leader>n",
        "<cmd>ZeppelinNewParagraph<CR>",
        { nowait = true, noremap = true, silent = true }
    )


    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            require('zeppelin.notebook').save_current_paragraph()
        end,
    })

    vim.api.nvim_set_current_buf(buf)
end

--------------------------------------------------------------------------------
-- Create a user command :ZeppelinRun that runs the current paragraph
--------------------------------------------------------------------------------
vim.api.nvim_create_user_command("ZeppelinRun", function()
    M.run_current_paragraph()
end, {})

vim.api.nvim_create_user_command("ZeppelinNewParagraph", function()
    M.new_paragraph()
end, {})

return M
