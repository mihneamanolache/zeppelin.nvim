local M = {}
local Job = require("plenary.job")
local config = require("zeppelin.config")

M.COOKIE_FILE = vim.fn.stdpath("cache") .. "/zeppelin_cookies.txt"

--- Build curl args with optional proxy and cookie support.
---@param method string HTTP method
---@param url string Full URL
---@param opts table|nil { body = string|nil, write_cookies = bool, form = bool }
---@return table args
local function build_curl_args(method, url, opts)
  opts = opts or {}
  local args = {}

  -- Proxy
  local proxy = config.options.SOCKS5_PROXY
  if proxy and proxy ~= "" then
    table.insert(args, "--socks5-hostname")
    table.insert(args, proxy)
  end

  -- Method
  table.insert(args, "-X")
  table.insert(args, method)

  -- Cookies
  if opts.write_cookies then
    table.insert(args, "-c")
    table.insert(args, M.COOKIE_FILE)
  else
    table.insert(args, "-b")
    table.insert(args, M.COOKIE_FILE)
  end

  -- Content type + body
  if opts.form then
    table.insert(args, "-H")
    table.insert(args, "Content-Type: application/x-www-form-urlencoded")
    if opts.body then
      table.insert(args, "--data")
      table.insert(args, opts.body)
    end
  elseif opts.body then
    table.insert(args, "-H")
    table.insert(args, "Content-Type: application/json")
    table.insert(args, "--data-binary")
    table.insert(args, opts.body)
  end

  table.insert(args, url)
  return args
end

--- Core request function. Runs curl asynchronously via plenary.job.
---@param method string HTTP method (GET, POST, PUT, DELETE)
---@param path string API path (e.g. "/api/notebook")
---@param body any|nil Request body (will be JSON-encoded if table)
---@param callback function callback(err, data) where data is decoded body field
function M.request(method, path, body, callback)
  local url = config.options.ZEPPELIN_URL .. path
  local encoded_body = nil
  if body ~= nil then
    if type(body) == "table" then
      encoded_body = vim.fn.json_encode(body)
    else
      encoded_body = tostring(body)
    end
  end

  local args = build_curl_args(method, url, { body = encoded_body })

  Job:new({
    command = "curl",
    args = args,
    on_exit = function(j, return_val)
      vim.schedule(function()
        if return_val ~= 0 then
          local stderr = table.concat(j:stderr_result(), "\n")
          callback("curl error (code " .. return_val .. "): " .. stderr, nil)
          return
        end

        local response = table.concat(j:result(), "\n")
        local ok, data = pcall(vim.fn.json_decode, response)
        if not ok or not data then
          callback("Invalid JSON response: " .. response, nil)
          return
        end

        if data.status ~= "OK" then
          callback(data.message or "Zeppelin returned non-OK status", nil)
          return
        end

        callback(nil, data.body)
      end)
    end,
  }):start()
end

--- GET request
---@param path string
---@param callback function callback(err, data)
function M.get(path, callback)
  M.request("GET", path, nil, callback)
end

--- POST request
---@param path string
---@param body any|nil
---@param callback function callback(err, data)
function M.post(path, body, callback)
  M.request("POST", path, body, callback)
end

--- PUT request
---@param path string
---@param body any|nil
---@param callback function callback(err, data)
function M.put(path, body, callback)
  M.request("PUT", path, body, callback)
end

--- DELETE request
---@param path string
---@param callback function callback(err, data)
function M.delete(path, callback)
  M.request("DELETE", path, nil, callback)
end

--- Authenticate with Zeppelin. Uses form-urlencoded POST and writes cookies.
---@param username string
---@param password string
---@param callback function callback(err, data)
function M.authenticate(username, password, callback)
  local url = config.options.ZEPPELIN_URL .. "/api/login"
  local form_body = "userName=" .. username .. "&password=" .. password
  local args = build_curl_args("POST", url, {
    body = form_body,
    write_cookies = true,
    form = true,
  })

  Job:new({
    command = "curl",
    args = args,
    on_exit = function(j, return_val)
      vim.schedule(function()
        if return_val ~= 0 then
          local stderr = table.concat(j:stderr_result(), "\n")
          callback("Authentication failed (curl error): " .. stderr, nil)
          return
        end

        local response = table.concat(j:result(), "\n")
        local ok, data = pcall(vim.fn.json_decode, response)
        if not ok or not data then
          callback("Authentication failed (invalid JSON): " .. response, nil)
          return
        end

        if data.status == "OK" then
          callback(nil, data.body)
        else
          callback("Authentication failed: " .. (data.message or "Unknown error"), nil)
        end
      end)
    end,
  }):start()
end

return M
