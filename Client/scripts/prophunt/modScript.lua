log("I", "PropHunt", "Loading /scripts/prophunt/modScript.lua")

-- Ensure GE extensions are loaded as soon as the client mod is mounted.
load("PropHunt")
load("PropHuntKeybinds")

setExtensionUnloadMode("PropHunt", "manual")
setExtensionUnloadMode("PropHuntKeybinds", "manual")

log("I", "PropHunt", "Loaded PropHunt + PropHuntKeybinds via modScript load()")
