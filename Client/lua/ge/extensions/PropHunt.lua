-- Thin loader for modular PropHunt client extension
-- Core logic moved to: lua/ge/extensions/prophunt/core.lua

local ok, mod = pcall(require, "ge.extensions.prophunt.core")
if not ok or not mod then
  ok, mod = pcall(require, "ge/extensions/prophunt/core")
end

if not ok or not mod then
  log("E", "PropHunt", "Failed to load PropHunt core module: " .. tostring(mod))
  return {}
end

return mod
