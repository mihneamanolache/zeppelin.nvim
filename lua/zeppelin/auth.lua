local M = {}
local Job = require("plenary.job")
local ui = require("zeppelin.ui")
local config = require("zeppelin.config")

M.COOKIE_FILE = vim.fn.stdpath("cache") .. "/zeppelin_cookies.txt"

M.authenticate = function(username, password)
    local args = {
        "-X", "POST",
        "-H", "Content-Type: application/x-www-form-urlencoded",
        "-c", M.COOKIE_FILE,
        "--data", "userName=" .. username .. "&password=" .. password,
        config.options.ZEPPELIN_URL .. "/api/login",
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
                    ui.show_popup("Zeppelin authentication failed (curl error)!")
                    return
                end

                local response = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.fn.json_decode, response)
                if not ok or not data then
                    ui.show_popup("Zeppelin authentication failed (invalid JSON)! " .. response)
                    return
                end
                if data.status == "OK" then
                    ui.show_popup("Zeppelin authentication successful!")
                else
                    ui.show_popup("Zeppelin authentication failed: " .. (data.message or "Unknown error"))
                end
            end)
        end,
    }):start()
end

return M
