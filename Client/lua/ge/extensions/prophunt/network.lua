local M = {}
M.BUILD = "2026-02-11-phase2e"

function M.register(handlers)
  if not AddEventHandler then
    print("ERROR: AddEventHandler not available - BeamMP client events cannot be registered")
    return false
  end

  AddEventHandler("PropHunt_Taunt", handlers.onNetworkTaunt)
  print("DEBUG: Registered handler for PropHunt_Taunt")

  AddEventHandler("PropHunt_GameStart", handlers.onGameStart)
  print("DEBUG: Registered handler for PropHunt_GameStart")
  AddEventHandler("PropHunt_GameEnd", handlers.onGameEnd)
  print("DEBUG: Registered handler for PropHunt_GameEnd")
  AddEventHandler("PropHunt_TimerUpdate", handlers.onTimerUpdate)
  print("DEBUG: Registered handler for PropHunt_TimerUpdate")
  AddEventHandler("PropHunt_HidePhaseStart", handlers.onHidePhaseStart)
  print("DEBUG: Registered handler for PropHunt_HidePhaseStart")
  AddEventHandler("PropHunt_HideTimerUpdate", handlers.onHideTimerUpdate)
  print("DEBUG: Registered handler for PropHunt_HideTimerUpdate")
  AddEventHandler("PropHunt_HidePhaseEnd", handlers.onHidePhaseEnd)
  print("DEBUG: Registered handler for PropHunt_HidePhaseEnd")
  AddEventHandler("PropHunt_RoundStart", handlers.onRoundStart)
  print("DEBUG: Registered handler for PropHunt_RoundStart")
  AddEventHandler("PropHunt_RoundEnd", handlers.onRoundEnd)
  print("DEBUG: Registered handler for PropHunt_RoundEnd")

  AddEventHandler("PropHunt_PlayerEliminated", handlers.onPlayerEliminated)
  print("DEBUG: Registered handler for PropHunt_PlayerEliminated")

  AddEventHandler("PropHunt_AssignProp", handlers.onAssignProp)
  print("DEBUG: Registered handler for PropHunt_AssignProp")

  AddEventHandler("ChatMessageReceived", handlers.onChatMessage)
  print("DEBUG: Registered PropHunt chat command handler")

  AddEventHandler("PropHunt_HiderList", handlers.onHiderList)
  print("DEBUG: Registered handler for PropHunt_HiderList")
  AddEventHandler("PropHunt_SeekerList", handlers.onSeekerList)
  print("DEBUG: Registered handler for PropHunt_SeekerList")
  AddEventHandler("PropHunt_ScanPulse", handlers.onScanPulse)
  print("DEBUG: Registered handler for PropHunt_ScanPulse")
  AddEventHandler("PropHunt_TeamUpdate", handlers.onTeamUpdate)
  print("DEBUG: Registered handler for PropHunt_TeamUpdate")
  AddEventHandler("PropHunt_Settings", handlers.onSettings)
  print("DEBUG: Registered handler for PropHunt_Settings")
  AddEventHandler("PropHunt_tempPropClear", handlers.onTempPropClear)
  print("DEBUG: Registered handler for PropHunt_tempPropClear")

  return true
end

return M
