local M = {}

M.options = {}

M.setup = function(opts)
  if not opts or not opts.ZEPPELIN_URL then
    error("[Zeppelin.nvim] Missing required configuration: ZEPPELIN_URL must be set in setup()")
  end

  opts.SOCKS5_PROXY = opts.SOCKS5_PROXY or ""
  M.options = opts
end

return M
