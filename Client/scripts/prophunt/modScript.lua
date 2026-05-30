log("I", "PropHunt", "Loading /scripts/prophunt/modScript.lua")

-- Ensure GE extensions are loaded as soon as the client mod is mounted.
if extensions and extensions.load then
  extensions.load("PropHunt")
  extensions.load("PropHuntKeybinds")
else
  load("PropHunt")
  load("PropHuntKeybinds")
end

setExtensionUnloadMode("PropHunt", "manual")
setExtensionUnloadMode("PropHuntKeybinds", "manual")

log("I", "PropHunt", "Loaded PropHunt + PropHuntKeybinds via modScript load()")
