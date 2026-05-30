local M = {}

local AUTO_TAG_COOLDOWN = 0.5
local TAG_CONTACT_COOLDOWN = 0.25
local TAG_OBB_ENABLED = true
local TAG_OBB_DEBUG = true

local function stateAllowsTag(ctx)
    if not ctx.getGameActive or not ctx.getGameActive() then return false end
    if ctx.isHidePhase and ctx.isHidePhase() then return false end
    if ctx.getPlayerTeam and ctx.getPlayerTeam() ~= "seeker" then return false end
    return true
end

local function makeTagToken(remotePid)
    return tostring(math.floor((os.clock() or 0) * 1000)) .. "-" .. tostring(remotePid or 0) .. "-" .. tostring(math.random(100000, 999999))
end

local function currentRoundId(ctx)
    if ctx.getCurrentRoundId then
        return tonumber(ctx.getCurrentRoundId() or 0) or 0
    end
    return 0
end

local function getOOBB(vehId)
    if not vehId then return nil, "no vehId" end
    if not be or not be.getObjectByID then return nil, "no be:getObjectByID" end
    local veh = be:getObjectByID(vehId)
    if not veh then return nil, "no veh object" end
    if not veh.getSpawnWorldOOBB then return nil, "no getSpawnWorldOOBB method" end
    local ok, bb = pcall(function() return veh:getSpawnWorldOOBB() end)
    if not ok or not bb then return nil, "getSpawnWorldOOBB failed" end
    return bb, nil
end

local function obbAllowsTag(localVehID, remoteVehID, state)
    if not TAG_OBB_ENABLED then return true end

    local bb1, e1 = getOOBB(localVehID)
    local bb2, e2 = getOOBB(remoteVehID)
    local haveFn = (type(overlapsOBB_OBB) == "function")
    local dbgNow = os.clock()

    if TAG_OBB_DEBUG and (dbgNow - state.lastObbDebugAt) > 0.5 then
        state.lastObbDebugAt = dbgNow
        print(string.format("PropHunt[TAG-OBB] local=%s remote=%s bb1=%s bb2=%s overlapsFn=%s e1=%s e2=%s",
            tostring(localVehID), tostring(remoteVehID), tostring(bb1 ~= nil), tostring(bb2 ~= nil), tostring(haveFn), tostring(e1), tostring(e2)))
    end

    if not (bb1 and bb2 and haveFn) then
        return true
    end

    local ok, hit = pcall(function()
        local he1 = bb1:getHalfExtents()
        local he2 = bb2:getHalfExtents()
        local inflate = 1.45
        local minHalf = 0.55
        local hx2 = math.max(he2.x * inflate, minHalf)
        local hy2 = math.max(he2.y * inflate, minHalf)
        local hz2 = math.max(he2.z * inflate, minHalf)

        return overlapsOBB_OBB(
            bb1:getCenter(), bb1:getAxis(0) * he1.x, bb1:getAxis(1) * he1.y, bb1:getAxis(2) * he1.z,
            bb2:getCenter(), bb2:getAxis(0) * hx2,  bb2:getAxis(1) * hy2,  bb2:getAxis(2) * hz2
        )
    end)

    if ok and not hit then
        if TAG_OBB_DEBUG and (dbgNow - state.lastObbDebugAt) > 0.49 then
            print("PropHunt[TAG-OBB] result=false (blocked tag)")
        end
        return false
    end

    if not ok then
        print("PropHunt[TAG-OBB] ERROR running overlapsOBB_OBB; falling back: " .. tostring(hit))
    end

    return true
end

function M.new(ctx)
    ctx = ctx or {}
    local state = {
        lastAutoTagTime = 0,
        lastTagContact = 0,
        lastObbDebugAt = 0
    }
    local api = {}

    function api.sendTagContact(remoteVehID, localVehID)
        if not stateAllowsTag(ctx) then return end

        local t = os.clock()
        if (t - state.lastTagContact) < TAG_CONTACT_COOLDOWN then return end
        state.lastTagContact = t

        if not obbAllowsTag(localVehID, remoteVehID, state) then return end

        if MPVehicleGE and MPVehicleGE.getServerVehicleID then
            local serverVehID = MPVehicleGE.getServerVehicleID(remoteVehID)
            if serverVehID then
                local remotePid = tonumber(string.match(tostring(serverVehID), "(%d+)%-%d+"))
                if remotePid and TriggerServerEvent then
                    local token = makeTagToken(remotePid)
                    TriggerServerEvent("PropHunt_onContactReceive", tostring(currentRoundId(ctx)) .. "|" .. tostring(remotePid) .. "|" .. token)
                end
            end
        end
    end

    function api.onSeekerCollision(otherVehId)
        if not stateAllowsTag(ctx) then return end

        local t = os.clock()
        if (t - state.lastAutoTagTime) < AUTO_TAG_COOLDOWN then return end
        state.lastAutoTagTime = t

        local otherId = tonumber(otherVehId)
        if not otherId then return end

        local myVeh = be and be.getPlayerVehicle and be:getPlayerVehicle(0) or nil
        local myId = myVeh and myVeh:getID() or nil
        if myId then
            api.sendTagContact(otherId, myId)
            return
        end

        local targetPlayerId = ctx.resolveOwnerPlayerIdFromVehId and ctx.resolveOwnerPlayerIdFromVehId(otherId) or nil
        if not targetPlayerId then
            print("DEBUG: Could not resolve owner for collided vehicle " .. tostring(otherId) .. " (BeamMP API mismatch)")
            return
        end

        if TriggerServerEvent then
            local token = makeTagToken(targetPlayerId)
            TriggerServerEvent("PropHunt_onContactReceive", tostring(currentRoundId(ctx)) .. "|" .. tostring(targetPlayerId) .. "|" .. token)
            print("DEBUG: Auto-tag collision => contact on player " .. tostring(targetPlayerId))
        end
    end

    return api
end

return M
