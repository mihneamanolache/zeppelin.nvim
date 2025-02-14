local M = {}

M.options = {}

M.setup = function(opts)
  if not opts or not opts.ZEPPELIN_URL or not opts.SOCKS5_PROXY then
    error("[Zeppelin.nvim] Missing required configuration: ZEPPELIN_URL and SOCKS5_PROXY must be set in setup()")
  end

  M.options = opts
end

return M
