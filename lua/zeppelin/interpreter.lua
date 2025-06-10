local M = {}
local Job = require("plenary.job")
local ui = require("zeppelin.ui")
local config = require("zeppelin.config")

M.COOKIE_FILE = vim.fn.stdpath("cache") .. "/zeppelin_cookies.txt"

local function decode_json(str)
    local decode = vim.json_decode or vim.fn.json_decode
    local ok, data = pcall(decode, str)
    return ok and data or nil
end

local function make_request(setting_id, payload, success_msg)
    local url = string.format("%s/api/interpreter/setting/restart/%s", config.options.ZEPPELIN_URL, setting_id)
    local args = {
        "-X", "PUT",
        "-b", M.COOKIE_FILE,
        "-H", "Content-Type: application/json",
        "--data-binary", payload,
        url,
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
                        "Interpreter request failed (curl error).\n" ..
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
                    ui.show_popup("Interpreter request failed!\n\n" .. response, { width = 80, height = 10 })
                    return
                end

                ui.show_popup(success_msg, { width = 40, height = 5 })
            end)
        end,
    }):start()
end

function M.restart(setting_id, note_id)
    if not setting_id or setting_id == "" then
        ui.show_popup("Usage: :ZeppelinRestartInterpreter <settingId> [noteId]", { width = 60, height = 5 })
        return
    end
    local payload = note_id and vim.fn.json_encode({ noteId = note_id }) or "{}"
    make_request(setting_id, payload, "Interpreter restarted successfully!")
end

function M.stop(setting_id)
    if not setting_id or setting_id == "" then
        ui.show_popup("Usage: :ZeppelinStopInterpreter <settingId>", { width = 60, height = 5 })
        return
    end
    make_request(setting_id, "{}", "Interpreter stopped successfully!")
end

return M
