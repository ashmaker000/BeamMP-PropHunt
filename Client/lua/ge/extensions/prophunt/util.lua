local M = {}
M.BUILD = "2026-02-11-phase2e"

local function validCategory(cat)
  if not cat then return 'info' end
  local normalized = tostring(cat):lower()
  local ok = { info=true, warning=true, error=true, flag=true, success=true }
  return ok[normalized] and normalized or 'info'
end

function M.beamMessage(opts)
  if not opts then return end
  local msg = opts.msg or opts.txt or opts.text
  if not msg then return end
  opts.category = validCategory(opts.category or opts.icon)
  opts.msg = msg
  if guihooks and guihooks.trigger then
    guihooks.trigger('Message', opts)
  elseif guihooks and guihooks.message then
    guihooks.message({txt = msg}, opts.ttl or 2, opts.category)
  end
end

return M
