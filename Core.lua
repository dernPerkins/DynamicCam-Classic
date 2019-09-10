---------------
-- LIBRARIES --
---------------
local AceAddon = LibStub("AceAddon-3.0");
local LibCamera = LibStub("LibCamera-1.0");
local LibEasing = LibStub("LibEasing-1.0");


---------------
-- CONSTANTS --
---------------
local ACTION_CAM_CVARS = {
    ["test_cameraOverShoulder"] = true,

    ["test_cameraTargetFocusEnemyEnable"] = true,
    ["test_cameraTargetFocusEnemyStrengthPitch"] = true,
    ["test_cameraTargetFocusEnemyStrengthYaw"] = true,

    ["test_cameraTargetFocusInteractEnable"] = true,
    ["test_cameraTargetFocusInteractStrengthPitch"] = true,
    ["test_cameraTargetFocusInteractStrengthYaw"] = true,

    ["test_cameraHeadMovementStrength"] = true,
    ["test_cameraHeadMovementRangeScale"] = true,
    ["test_cameraHeadMovementMovingStrength"] = true,
    ["test_cameraHeadMovementStandingStrength"] = true,
    ["test_cameraHeadMovementMovingDampRate"] = true,
    ["test_cameraHeadMovementStandingDampRate"] = true,
    ["test_cameraHeadMovementFirstPersonDampRate"] = true,
    ["test_cameraHeadMovementDeadZone"] = true,

    ["test_cameraDynamicPitch"] = true,
    ["test_cameraDynamicPitchBaseFovPad"] = true,
    ["test_cameraDynamicPitchBaseFovPadFlying"] = true,
    ["test_cameraDynamicPitchBaseFovPadDownScale"] = true,
    ["test_cameraDynamicPitchSmartPivotCutoffDist"] = true,
};


-------------
-- GLOBALS --
-------------
DynamicCam = AceAddon:NewAddon("DynamicCam", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0");
DynamicCam.currentSituationID = nil;


------------
-- LOCALS --
------------
local _;
local Options;
local functionCache = {};
local situationEnvironments = {}
local conditionExecutionCache = {};

local function DC_RunScript(script, situationID)
    if (not script or script == "") then
        return;
    end

    -- make sure that we're not creating tables willy nilly
    if (not functionCache[script]) then
        functionCache[script] = assert(loadstring(script));

        -- if env, set the environment to that
        if (situationID) then
            if (not situationEnvironments[situationID]) then
                situationEnvironments[situationID] = setmetatable({}, { __index =
                    function(t, k)
                        if (k == "_G") then
                            return t;
                        elseif (k == "this") then
                            return situationEnvironments[situationID].this;
                        else
                            return _G[k];
                        end
                    end
                });
                situationEnvironments[situationID].this = {};
            end

            setfenv(functionCache[script], situationEnvironments[situationID]);
        end
    end

    -- return the result
    return functionCache[script]();
end

local function DC_SetCVar(cvar, setting)
    -- if actioncam flag is off and if cvar is an ActionCam setting, don't set it
    if (not DynamicCam.db.profile.actionCam and ACTION_CAM_CVARS[cvar]) then
        return;
    end

    -- don't apply cvars if they're already set to the new value
    if (GetCVar(cvar) ~= tostring(setting)) then
        DynamicCam:DebugPrint(cvar, setting);
        SetCVar(cvar, setting);
    end
end

local function round(num, numDecimalPlaces)
    local mult = 10^(numDecimalPlaces or 0);
    return math.floor(num * mult + 0.5) / mult;
end

local function gotoView(view, instant)
    -- if you call SetView twice, then it's instant
    if (instant) then
        SetView(view);
    end
    SetView(view);
end

local function copyTable(originalTable)
    local origType = type(originalTable);
    local copy;
    if (origType == 'table') then
        -- this child is a table, copy the table recursively
        copy = {};
        for orig_key, orig_value in next, originalTable, nil do
            copy[copyTable(orig_key)] = copyTable(orig_value);
        end
    else
        -- this child is a value, copy it cover
        copy = originalTable;
    end
    return copy;
end


----------------------
-- SHOULDER OFFSET  --
----------------------
local easeShoulderOffsetHandle;

local function setShoulderOffset(offset)
    if (offset and type(offset) == 'number') then
        SetCVar("test_cameraOverShoulder", offset)
    end
end

local function stopEasingShoulderOffset()
    if (easeShoulderOffsetHandle) then
        LibEasing:StopEasing(easeShoulderOffsetHandle);
        easeShoulderOffsetHandle = nil;
    end
end

local function easeShoulderOffset(endValue, duration, easingFunc)
    stopEasingShoulderOffset();

    local oldOffest = tonumber(GetCVar("test_cameraOverShoulder"));
    easeShoulderOffsetHandle = LibEasing:Ease(setShoulderOffset, oldOffest, endValue, duration, easingFunc);
    DynamicCam:DebugPrint("test_cameraOverShoulder", oldOffest, "->", endValue);
end


-------------
-- FADE UI --
-------------
local easeUIAlphaHandle;
local hidMinimap;
local unfadeUIFrame = CreateFrame("Frame", "DynamicCamUnfadeUIFrame");
local combatSecureFrame = CreateFrame("Frame", "DynamicCamCombatSecureFrame", nil, "SecureHandlerStateTemplate");
combatSecureFrame.hidUI = nil;
combatSecureFrame.lastUIAlpha = nil;

RegisterStateDriver(combatSecureFrame, "dc_combat_state", "[combat] combat; [nocombat] nocombat");
combatSecureFrame:SetAttribute("_onstate-dc_combat_state", [[ -- arguments: self, stateid, newstate
    if (newstate == "combat") then
        if (self.hidUI) then
            setUIAlpha(combatSecureFrame.lastUIAlpha);
            UIParent:Show();

            combatSecureFrame.lastUIAlpha = nil;
            self.hidUI = nil;
        end
    end
]]);

local function setUIAlpha(newAlpha)
    if (newAlpha and type(newAlpha) == 'number') then
        UIParent:SetAlpha(newAlpha);

        -- show unfadeUIFrame if we're faded
        if (newAlpha < 1 and not unfadeUIFrame:IsShown()) then
            unfadeUIFrame:Show();
        elseif (newAlpha == 1) then
            -- UI is no longer faded, remove the esc handler
            if (unfadeUIFrame:IsShown()) then
                -- want to hide the frame without calling it's onhide handler
                local onHide = unfadeUIFrame:GetScript("OnHide");
                unfadeUIFrame:SetScript("OnHide", nil);
                unfadeUIFrame:Hide();
                unfadeUIFrame:SetScript("OnHide", onHide);
            end
        end
    end
end

local function stopEasingUIAlpha()
    -- if we are currently easing the UI out, make sure to stop that
    if (easeUIAlphaHandle) then
        LibEasing:StopEasing(easeUIAlphaHandle);
        easeUIAlphaHandle = nil;
    end

    -- show the minimap if we hid it and it's still hidden
    if (hidMinimap and not Minimap:IsShown()) then
        Minimap:Show();
        hidMinimap = nil;
    end

    -- show the UI if we hid it and it's still hidden
    if (combatSecureFrame.hidUI) then
        if (not UIParent:IsShown() and (not InCombatLockdown() or issecure())) then
            setUIAlpha(combatSecureFrame.lastUIAlpha);
            UIParent:Show();
        end

        combatSecureFrame.hidUI = nil;
        combatSecureFrame.lastUIAlpha = nil;
    end
end

local function easeUIAlpha(endValue, duration, easingFunc, callback)
    stopEasingUIAlpha();

    if (UIParent:GetAlpha() ~= endValue) then
        easeUIAlphaHandle = LibEasing:Ease(setUIAlpha, UIParent:GetAlpha(), endValue, duration, easingFunc, callback);
    else
        -- we're not going to ease because we're already there, have to call the callback anyways
        if (callback) then
            callback();
        end
    end
end

local function fadeUI(opacity, duration, hideUI)
    -- setup a callback that will hide the UI if given or hide the minimap if opacity is 0
    local callback = function()
        if (opacity == 0 and hideUI and UIParent:IsShown() and (not InCombatLockdown() or issecure())) then
            -- hide the UI, but make sure to make opacity 1 so that if escape is pressed, it is shown
            setUIAlpha(1);
            UIParent:Hide();

            combatSecureFrame.lastUIAlpha = opacity;
            combatSecureFrame.hidUI = true;
        elseif (opacity == 0 and Minimap:IsShown()) then
            -- hide the minimap
            Minimap:Hide();
            hidMinimap = true;
        end
    end

    easeUIAlpha(opacity, duration, nil, callback);
end

local function unfadeUI(opacity, duration)
    stopEasingUIAlpha();
    easeUIAlpha(opacity, duration);
end

-- need to be able to clear the faded UI, use dummy frame that Show() on fade, which will cause esc to
-- hide it, make OnHide
unfadeUIFrame:SetScript("OnHide", function(self)
    stopEasingUIAlpha();
    UIParent:SetAlpha(1);
end);
tinsert(UISpecialFrames, unfadeUIFrame:GetName());


-----------------------
-- NAMEPLATE ZOOMING --
-----------------------
local nameplateRestore = {};
local RAMP_TIME = .25;
local HYS = 3;
local SETTLE_TIME = .5;
local ERROR_MULT = 2.5;
local STOPPING_SPEED = 5;

local function restoreNameplates()
	if (not InCombatLockdown()) then
		for k,v in pairs(nameplateRestore) do
			SetCVar(k, v);
		end
		nameplateRestore = {};
	end
end

local function fitNameplate(minZoom, maxZoom, nameplatePosition, continously, toggleNameplates)
    if (toggleNameplates and not InCombatLockdown()) then
        nameplateRestore["nameplateShowAll"] = GetCVar("nameplateShowAll");
        nameplateRestore["nameplateShowFriends"] = GetCVar("nameplateShowFriends");
        nameplateRestore["nameplateShowEnemies"] = GetCVar("nameplateShowEnemies");

        SetCVar("nameplateShowAll", 1);
        SetCVar("nameplateShowFriends", 1);
        SetCVar("nameplateShowEnemies", 1);
    end

    local lastSpeed = 0;
    local startTime = GetTime();
    local settleTimeStart;
    local zoomFunc = function() -- returning 0 will stop camera, returning nil stops camera, returning number puts camera to that speed
        local nameplate = C_NamePlate.GetNamePlateForUnit("target");

        if (nameplate) then
            local yCenter = (nameplate:GetTop() + nameplate:GetBottom())/2;
            local screenHeight = GetScreenHeight() * UIParent:GetEffectiveScale();
            local difference = screenHeight - yCenter;
            local ratio = (1 - difference/screenHeight) * 100;
            local error = ratio - nameplatePosition;

            local speed = 0;
            if (lastSpeed == 0 and abs(error) < HYS) then
                speed = 0;
            elseif (abs(error) > HYS/4 or abs(lastSpeed) > STOPPING_SPEED) then
                speed = ERROR_MULT * error;

                local deltaTime = GetTime() - startTime;
                if (deltaTime < RAMP_TIME) then
                    speed = speed * (deltaTime / RAMP_TIME);
                end
            end

            local curZoom = GetCameraZoom();
            if (speed > 0 and curZoom >= maxZoom) then
                speed = 0;
            elseif (speed < 0 and curZoom <= minZoom) then
                speed = 0;
            end

            if (speed == 0) then
                startTime = GetTime();
                settleTimeStart = settleTimeStart or GetTime();
            else
                settleTimeStart = nil;
            end

            if (speed == 0 and not continously and (GetTime() - settleTimeStart > SETTLE_TIME)) then
                return nil;
            end

            lastSpeed = speed;
            return speed;
        end

        if (continously) then
            startTime = GetTime();
            lastSpeed = 0;
            return 0;
        end

        return nil;
    end

    LibCamera:CustomZoom(zoomFunc, restoreNameplates);
    DynamicCam:DebugPrint("zoom fit nameplate");
end


--------
-- DB --
--------
DynamicCam.defaults = {
    profile = {
        enabled = true,
        version = 0,
        firstRun = true,

        advanced = false,
        debugMode = false,
        actionCam = true,

        easingZoom = "InOutQuad",
        easingYaw = "InOutQuad",
        easingPitch = "InOutQuad",

        reactiveZoom = {
            enabled = false,
            addIncrementsAlways = 1,
            addIncrements = 3,
            maxZoomTime = .25,
            incAddDifference = 4,
            easingFunc = "OutQuad",
        },
        defaultCvars = {
            ["cameraZoomSpeed"] = 20,
            ["cameraDistanceMaxZoomFactor"] = 2.6,

            ["test_cameraOverShoulder"] = 0,

            ["test_cameraTargetFocusEnemyEnable"] = 0,
            ["test_cameraTargetFocusEnemyStrengthPitch"] = 0.4,
            ["test_cameraTargetFocusEnemyStrengthYaw"] = 0.5,
            ["test_cameraTargetFocusInteractEnable"] = 0,
            ["test_cameraTargetFocusInteractStrengthPitch"] = 0.75,
            ["test_cameraTargetFocusInteractStrengthYaw"] = 1.0,

            ["test_cameraHeadMovementStrength"] = 0,
            ["test_cameraHeadMovementRangeScale"] = 5,
            ["test_cameraHeadMovementMovingStrength"] = 0.5,
            ["test_cameraHeadMovementStandingStrength"] = 0.3,
            ["test_cameraHeadMovementMovingDampRate"] = 10,
            ["test_cameraHeadMovementStandingDampRate"] = 10,
            ["test_cameraHeadMovementFirstPersonDampRate"] = 20,
            ["test_cameraHeadMovementDeadZone"] = 0.015,

            ["test_cameraDynamicPitch"] = 0,
            ["test_cameraDynamicPitchBaseFovPad"] = .35,
            ["test_cameraDynamicPitchBaseFovPadFlying"] = .75,
            ["test_cameraDynamicPitchBaseFovPadDownScale"] = .25,
            ["test_cameraDynamicPitchSmartPivotCutoffDist"] = 10,
        },
        situations = {
            ["**"] = {
                name = "",
                enabled = true,
                priority = 0,
                condition = "return false",
                events = {},
                delay = 0,
                executeOnInit = "",
                executeOnEnter = "",
                executeOnExit = "",
                cameraActions = {
                    transitionTime = .75,
                    timeIsMax = true,

                    rotate = false,
                    rotateSetting = "continous",
                    rotateSpeed = 20,
                    yawDegrees = 0,
                    pitchDegrees = 0,
                    rotateBack = false,

                    zoomSetting = "off",
                    zoomValue = 10,
                    zoomMin = 5,
                    zoomMax = 15,

                    zoomFitContinous = false,
                    zoomFitPosition = 84,
                    zoomFitUseCurAsMin = false,
                    zoomFitToggleNameplate = false,
                },
                view = {
                    enabled = false,
                    viewNumber = 5,
                    restoreView = false,
                    instant = false,
                },
                extras = {
                    hideUI = false,
                    actuallyHideUI = true,
                    hideUIFadeOpacity = 0,
                },
                cameraCVars = {},
            },
            ["001"] = {
                name = "City",
                priority = 1,
                condition = "return IsResting();",
                events = {"PLAYER_UPDATE_RESTING"},
            },
            ["002"] = {
                name = "City (Indoors)",
                priority = 11,
                condition = "return IsResting() and IsIndoors();",
                events = {"PLAYER_UPDATE_RESTING", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED", "SPELL_UPDATE_USABLE"},
            },
            ["004"] = {
                name = "World",
                priority = 0,
                condition = "return not IsResting() and not IsInInstance();",
                events = {"PLAYER_UPDATE_RESTING", "ZONE_CHANGED_NEW_AREA"},
            },
            ["005"] = {
                name = "World (Indoors)",
                priority = 10,
                condition = "return not IsResting() and not IsInInstance() and IsIndoors();",
                events = {"PLAYER_UPDATE_RESTING", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "SPELL_UPDATE_USABLE"},
            },
            ["006"] = {
                name = "World (Combat)",
                priority = 50,
                condition = "return not IsInInstance() and UnitAffectingCombat(\"player\");",
                events = {"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA"},
            },
            ["020"] = {
                name = "Dungeon/Scenerio",
                priority = 2,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and (instanceType == \"party\" or instanceType == \"scenario\"));",
                events = {"ZONE_CHANGED_NEW_AREA"},
            },
            ["021"] = {
                name = "Dungeon/Scenerio (Outdoors)",
                priority = 12,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and (instanceType == \"party\" or instanceType == \"scenario\")) and IsOutdoors();",
                events = {"ZONE_CHANGED_INDOORS", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "SPELL_UPDATE_USABLE"},
            },
            ["023"] = {
                name = "Dungeon/Scenerio (Combat, Boss)",
                priority = 302,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and (instanceType == \"party\" or instanceType == \"scenario\")) and UnitAffectingCombat(\"player\") and IsEncounterInProgress();",
                events = {"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_START", "ENCOUNTER_END", "INSTANCE_ENCOUNTER_ENGAGE_UNIT"},
            },
            ["024"] = {
                name = "Dungeon/Scenerio (Combat, Trash)",
                priority = 202,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and (instanceType == \"party\" or instanceType == \"scenario\")) and UnitAffectingCombat(\"player\") and not IsEncounterInProgress();",
                events = {"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_START", "ENCOUNTER_END", "INSTANCE_ENCOUNTER_ENGAGE_UNIT"},
            },
            ["030"] = {
                name = "Raid",
                priority = 3,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"raid\");",
                events = {"ZONE_CHANGED_NEW_AREA"},
            },
            ["031"] = {
                name = "Raid (Outdoors)",
                priority = 13,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"raid\") and IsOutdoors();",
                events = {"ZONE_CHANGED_INDOORS", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "SPELL_UPDATE_USABLE"},
            },
            ["033"] = {
                name = "Raid (Combat, Boss)",
                priority = 303,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"raid\") and UnitAffectingCombat(\"player\") and IsEncounterInProgress();",
                events = {"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_START", "ENCOUNTER_END", "INSTANCE_ENCOUNTER_ENGAGE_UNIT"},
            },
            ["034"] = {
                name = "Raid (Combat, Trash)",
                priority = 203,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"raid\") and UnitAffectingCombat(\"player\") and not IsEncounterInProgress();",
                events = {"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_START", "ENCOUNTER_END", "INSTANCE_ENCOUNTER_ENGAGE_UNIT"},
            },
            ["050"] = {
                name = "Arena",
                priority = 3,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"arena\");",
                events = {"ZONE_CHANGED_NEW_AREA"},
            },
            ["051"] = {
                name = "Arena (Combat)",
                priority = 203,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"arena\") and UnitAffectingCombat(\"player\");",
                events = {"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA"},
            },
            ["060"] = {
                name = "Battleground",
                priority = 3,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"pvp\");",
                events = {"ZONE_CHANGED_NEW_AREA"},
            },
            ["061"] = {
                name = "Battleground (Combat)",
                priority = 203,
                condition = "local isInstance, instanceType = IsInInstance(); return (isInstance and instanceType == \"pvp\") and UnitAffectingCombat(\"player\");",
                events = {"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA"},
            },
            ["100"] = {
                name = "Mounted",
                priority = 100,
                condition = "return IsMounted() and not UnitOnTaxi(\"player\");",
                events = {"SPELL_UPDATE_USABLE", "UNIT_AURA"},
            },
            ["101"] = {
                name = "Taxi",
                priority = 1000,
                condition = "return UnitOnTaxi(\"player\");",
                events = {"PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED"},
            },
            ["102"] = {
                name = "Vehicle",
                priority = 1000,
                condition = "return UnitUsingVehicle(\"player\");",
                events = {"UNIT_ENTERED_VEHICLE", "UNIT_EXITED_VEHICLE"},
            },
            ["200"] = {
                name = "Hearth/Teleport",
                priority = 20,
                condition = [[for k,v in pairs(this.spells) do
    if (UnitCastingInfo("player") == GetSpellInfo(v)) then
        return true;
    end
end
return false;]],
                executeOnInit = "this.spells = {227334, 136508, 189838, 54406, 94719, 556, 168487, 168499, 171253, 50977, 8690, 222695, 171253, 224869, 53140, 3565, 32271, 193759, 3562, 3567, 33690, 35715, 32272, 49358, 176248, 3561, 49359, 3566, 88342, 88344, 3563, 132627, 132621, 176242, 192085, 192084, 216016};",
                executeOnEnter = "local _, _, _, startTime, endTime = UnitCastingInfo(\"player\");\nthis.transitionTime = ((endTime - startTime)/1000) - .25;",
                events = {"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_INTERRUPTED"},
            },
            ["201"] = {
                name = "Annoying Spells",
                priority = 1000,
                condition = [[for k,v in pairs(this.buffs) do
    local name = GetSpellInfo(v);
    if (AuraUtil.FindAuraByName(name, "player", "HELPFUL")) then
        return true;
    end
end
return false;]],
                events = {"UNIT_AURA"},
                executeOnInit = "this.buffs = {46924, 51690, 188499, 210152};",
            },
            ["300"] = {
                name = "NPC Interaction",
                priority = 20,
                condition = "local unit = (UnitExists(\"questnpc\") and \"questnpc\") or (UnitExists(\"npc\") and \"npc\");\nreturn unit and (UnitIsUnit(unit, \"target\"));",
                events = {"PLAYER_TARGET_CHANGED", "GOSSIP_SHOW", "GOSSIP_CLOSED", "QUEST_COMPLETE", "QUEST_DETAIL", "QUEST_FINISHED", "QUEST_GREETING", "QUEST_PROGRESS", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "TRAINER_SHOW", "TRAINER_CLOSED", "SHIPMENT_CRAFTER_OPENED", "SHIPMENT_CRAFTER_CLOSED"},
                delay = .5,
            },
            ["301"] = {
                name = "Mailbox",
                priority = 20,
                condition = "return (MailFrame and MailFrame:IsShown())",
                events = {"MAIL_CLOSED", "MAIL_SHOW", "GOSSIP_CLOSED"},
            },
            ["302"] = {
                name = "Fishing",
                priority = 20,
                condition = "return (UnitChannelInfo(\"player\") == GetSpellInfo(7620))",
                events = {"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_INTERRUPTED"},
                delay = 2,
            },
        },
    },
};


----------
-- CORE --
----------
local started;
local events = {};
local evaluateTimer;

function DynamicCam:OnInitialize()
    -- setup db
    self:InitDatabase();
    self:RefreshConfig();

    -- setup chat commands
    self:RegisterChatCommand("dynamiccam", "OpenMenu");
    self:RegisterChatCommand("dc", "OpenMenu");

    self:RegisterChatCommand("saveview", "SaveViewCC");
    self:RegisterChatCommand("sv", "SaveViewCC");

    self:RegisterChatCommand("zoominfo", "ZoomInfoCC");
    self:RegisterChatCommand("zi", "ZoomInfoCC");

    self:RegisterChatCommand("zoom", "ZoomSlash");
    self:RegisterChatCommand("pitch", "PitchSlash");
    self:RegisterChatCommand("yaw", "YawSlash");

    -- make sure to disable the message if ActionCam setting is on
    if (self.db.profile.actionCam) then
        UIParent:UnregisterEvent("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED");
    end

    -- disable if the setting is enabled
    if (not self.db.profile.enabled) then
        self:Disable();
    end
end

function DynamicCam:OnEnable()
    self.db.profile.enabled = true;

    self:Startup();
end

function DynamicCam:OnDisable()
    self.db.profile.enabled = false;
    self:Shutdown();
end

function DynamicCam:Startup()
    -- make sure that shortcuts have values
    if (not Options) then
        Options = self.Options;
    end

    -- register for dynamiccam messages
    self:RegisterMessage("DC_SITUATION_ENABLED");
    self:RegisterMessage("DC_SITUATION_DISABLED");
    self:RegisterMessage("DC_SITUATION_UPDATED");
    self:RegisterMessage("DC_BASE_CAMERA_UPDATED");

    -- initial evaluate needs to be delayed because the camera doesn't like changing cvars on startup
    self:ScheduleTimer("ApplyDefaultCameraSettings", 2.5);
    evaluateTimer = self:ScheduleTimer("EvaluateSituations", 3);
    self:ScheduleTimer("RegisterEvents", 3);

    -- turn on reactive zoom if it's enabled
    if (self.db.profile.reactiveZoom.enabled) then
        self:ReactiveZoomOn();
    end

    started = true;
end

function DynamicCam:Shutdown()
    -- kill the evaluate timer if it's running
    if (evaluateTimer) then
        self:CancelTimer(evaluateTimer);
        evaluateTimer = nil;
    end

    -- exit the current situation if in one
    if (self.currentSituationID) then
        self:ExitSituation(self.currentSituationID);
    end

    events = {};
    self:UnregisterAllEvents();
    self:UnregisterAllMessages();

    -- apply default settings
    self:ApplyDefaultCameraSettings();

    -- turn off reactiveZoom
    self:ReactiveZoomOff();

    started = false;
end

function DynamicCam:DebugPrint(...)
    if (self.db.profile.debugMode) then
        self:Print(...);
    end
end


----------------
-- SITUATIONS --
----------------
local delayTime;
local delayTimer;
local restoration = {};

function DynamicCam:EvaluateSituations()
    -- if we currently have timer running, kill it
    if (evaluateTimer) then
        self:CancelTimer(evaluateTimer);
        evaluateTimer = nil;
    end

    if (self.db.profile.enabled) then
        local highestPriority = -100;
        local topSituation;

        -- go through all situations pick the best one
        for id, situation in pairs(self.db.profile.situations) do
            if (situation.enabled) then
                -- evaluate the condition, if it checks out and the priority is larger then any other, set it
                local lastEvaluate = conditionExecutionCache[id];
                local thisEvaluate = DC_RunScript(situation.condition, id);
                conditionExecutionCache[id] = thisEvaluate;

                if (thisEvaluate) then
                    -- the condition is true
                    if (not lastEvaluate) then
                        -- last evaluate wasn't true, so this we "flipped"
                        self:SendMessage("DC_SITUATION_ACTIVE", id);
                    end

                    -- check to see if we've already found something with higher priority
                    if (situation.priority > highestPriority) then
                        highestPriority = situation.priority;
                        topSituation = id;
                    end
                else
                    -- the condition is false
                    if (lastEvaluate) then
                        -- last evaluate was true, so we "flipped"
                        self:SendMessage("DC_SITUATION_INACTIVE", id);
                    end
                end
            end
        end

        local swap = true;
        if (self.currentSituationID and (not topSituation or topSituation ~= self.currentSituationID)) then
            -- we're in a situation that isn't the topSituation or there is no topSituation
            local delay = self.db.profile.situations[self.currentSituationID].delay;
            if (delay > 0) then
                if (not delayTime) then
                    -- not yet cooling down, make sure to guarentee an evaluate, don't swap
                    delayTime = GetTime() + delay;
                    delayTimer = self:ScheduleTimer("EvaluateSituations", delay, "DELAY_TIMER");
                    self:DebugPrint("Not changing situation because of a delay");
                    swap = false;
                elseif (delayTime > GetTime()) then
                    -- still cooling down, don't swap
                    swap = false;
                end
            end
        end

        if (swap) then
            if (topSituation) then
                if (topSituation ~= self.currentSituationID) then
                    -- we want to swap and there is a situation to swap into, and it's not the current situation
                    self:SetSituation(topSituation);
                end

                -- if we had a delay previously, make sure to reset it
                delayTime = nil;
            else
                --none of the situations are active, leave the current situation
                if (self.currentSituationID) then
                    self:ExitSituation(self.currentSituationID);
                end
            end
        end
    end
end

function DynamicCam:SetSituation(situationID)
    local oldSituationID = self.currentSituationID;
    local restoringZoom;

    -- if currently in a situation, leave it
    if (self.currentSituationID) then
        restoringZoom = self:ExitSituation(self.currentSituationID, situationID);
    end

    -- go into the new situation
    self:EnterSituation(situationID, oldSituationID, restoringZoom);
end

function DynamicCam:EnterSituation(situationID, oldSituationID, skipZoom)
    local situation = self.db.profile.situations[situationID];
    local this = situationEnvironments[situationID].this;

    self:DebugPrint("Entering situation", situation.name);

    -- load and run advanced script onEnter
    DC_RunScript(situation.executeOnEnter, situationID);

    self.currentSituationID = situationID;

    restoration[situationID] = {};
    local a = situation.cameraActions;

    local transitionTime = a.transitionTime;
    if (this.transitionTime) then
        transitionTime = this.transitionTime;
    end
    -- min 10 frames
    transitionTime = math.max(10.0/60.0, transitionTime);

    -- set view settings
    if (situation.view.enabled) then
        if (situation.view.restoreView) then
            SaveView(1);
        end

        gotoView(situation.view.viewNumber, situation.view.instant);
    end

    -- ZOOM --
    if (not skipZoom) then
        -- save old zoom level
        local cameraZoom = GetCameraZoom();
        restoration[situationID].zoom = round(cameraZoom, 1);
        restoration[situationID].zoomSituation = oldSituationID;

        -- set zoom level
        local newZoomLevel;

        if (a.zoomSetting == "in" and cameraZoom > a.zoomValue) then
            newZoomLevel = a.zoomValue;
        elseif (a.zoomSetting == "out" and cameraZoom < a.zoomValue) then
            newZoomLevel = a.zoomValue;
        elseif (a.zoomSetting == "set") then
            newZoomLevel = a.zoomValue;
        elseif (a.zoomSetting == "range") then
            if (cameraZoom < a.zoomMin) then
                newZoomLevel = a.zoomMin;
            elseif (cameraZoom > a.zoomMax) then
                newZoomLevel = a.zoomMax;
            end
        elseif (a.zoomSetting == "fit") then
            local min = a.zoomMin;
            if (a.zoomFitUseCurAsMin) then
                min = math.min(GetCameraZoom(), a.zoomMax);
            end

            fitNameplate(min, a.zoomMax, a.zoomFitPosition, a.zoomFitContinous, a.zoomFitToggleNameplate);
        end

        -- actually do zoom
        if (newZoomLevel) then
            local difference = math.abs(newZoomLevel - cameraZoom)
            local linearSpeed = difference / transitionTime;
            local currentSpeed = tonumber(GetCVar("cameraZoomSpeed"));
            local duration = transitionTime;

            -- if zoom speed is lower than current speed, then calculate a new transitionTime
            if (a.timeIsMax and linearSpeed < currentSpeed) then
                -- min time 10 frames
                duration = math.max(10.0/60.0, difference / currentSpeed)
            end

            self:DebugPrint("Setting zoom level because of situation entrance", newZoomLevel, duration);

            LibCamera:SetZoom(newZoomLevel, duration, LibEasing[self.db.profile.easingZoom]);
        end

        -- if we didn't adjust the zoom, then reset oldZoom
        if (not newZoomLevel and a.zoomSetting ~= "fit") then
            restoration[situationID].zoom = nil;
            restoration[situationID].zoomSituation = nil;
        end
    else
        self:DebugPrint("Restoring zoom level, so skipping zoom action")
    end

    -- set all cvars
    for cvar, value in pairs(situation.cameraCVars) do
        if (cvar == "test_cameraOverShoulder") then
            -- ease shoulder offset over
            stopEasingShoulderOffset();
            if (GetCVar("test_cameraOverShoulder") ~= tostring(value)) then
                easeShoulderOffset(value, transitionTime);
            end
        else
            DC_SetCVar(cvar, value);
        end
    end

    -- ROTATE --
    if (a.rotate) then
        if (a.rotateSetting == "continous") then
            LibCamera:BeginContinuousYaw(a.rotateSpeed, transitionTime);
        elseif (a.rotateSetting == "degrees") then
            if (a.yawDegrees ~= 0) then
                LibCamera:Yaw(a.yawDegrees, transitionTime, LibEasing[self.db.profile.easingYaw]);
            end

            if (a.pitchDegrees ~= 0) then
                LibCamera:Pitch(a.pitchDegrees, transitionTime, LibEasing[self.db.profile.easingPitch]);
            end
        end
    end

    -- EXTRAS --
    if (situation.extras.hideUI) then
        fadeUI(situation.extras.hideUIFadeOpacity, math.min(0.5, transitionTime), situation.extras.actuallyHideUI);
    end

    self:SendMessage("DC_SITUATION_ENTERED");
end

function DynamicCam:ExitSituation(situationID, newSituationID)
    local restoringZoom;
    local situation = self.db.profile.situations[situationID];
    self.currentSituationID = nil;

    self:DebugPrint("Exiting situation "..situation.name);

    -- load and run advanced script onExit
    DC_RunScript(situation.executeOnExit, situationID);

    -- restore cvars to their default values
    self:ApplyDefaultCameraSettings(newSituationID);

    -- restore view that is enabled
    if (situation.view.enabled and situation.view.restoreView) then
        gotoView(1, situation.view.instant);
    end

    local a = situation.cameraActions;

    -- stop rotating if we started to
    if (a.rotate) then
        if (a.rotateSetting == "continous") then
            local yaw = LibCamera:StopYawing();

            -- rotate back if we want to
            if (a.rotateBack) then
                self:DebugPrint("Ended rotate, degrees rotated, yaw:", yaw);
                if (yaw) then
                    local yawBack = yaw % 360;

                    -- we're beyond 180 degrees, go the other way
                    if (yawBack > 180) then
                        yawBack = yawBack - 360;
                    end

                    LibCamera:Yaw(-yawBack, 0.75, LibEasing[self.db.profile.easingYaw]);
                end
            end
        elseif (a.rotateSetting == "degrees") then
            if (LibCamera:IsRotating()) then
                -- interrupted rotation
                local yaw, pitch = LibCamera:StopRotating();

                -- rotate back if we want to
                if (a.rotateBack) then
                    self:DebugPrint("Ended rotate early, degrees rotated, yaw:", yaw, "pitch:", pitch);
                    if (yaw) then
                        LibCamera:Yaw(-yaw, 0.75, LibEasing[self.db.profile.easingYaw]);
                    end

                    if (pitch) then
                        LibCamera:Pitch(-pitch, 0.75, LibEasing[self.db.profile.easingPitch]);
                    end
                end
            else
                if (a.rotateBack) then
                    if (a.yawDegrees ~= 0) then
                        LibCamera:Yaw(-a.yawDegrees, 0.75, LibEasing[self.db.profile.easingYaw]);
                    end

                    if (a.pitchDegrees ~= 0) then
                        LibCamera:Pitch(-a.pitchDegrees, 0.75, LibEasing[self.db.profile.easingPitch]);
                    end
                end
            end
        end
    end

    -- restore zoom level if we saved one
    if (self:ShouldRestoreZoom(situationID, newSituationID)) then
        restoringZoom = true;

        local defaultTime = math.abs(restoration[situationID].zoom - GetCameraZoom()) / tonumber(GetCVar("cameraZoomSpeed"));
        local t = math.max(10.0/60.0, math.min(defaultTime, .75));
        local zoomLevel = restoration[situationID].zoom;

        self:DebugPrint("Restoring zoom level:", restoration[situationID].zoom, t);

        LibCamera:SetZoom(zoomLevel, t, LibEasing[self.db.profile.easingZoom]);
    else
        self:DebugPrint("Not restoring zoom level");
    end

    -- unhide UI
    if (situation.extras.hideUI) then
        unfadeUI(1, .5);
    end

    wipe(restoration[situationID]);

    self:SendMessage("DC_SITUATION_EXITED");

    return restoringZoom;
end

function DynamicCam:GetSituationList()
    local situationList = {};

    for id, situation in pairs(self.db.profile.situations) do
        local prefix = "";
        local suffix = "";
        local customPrefix = "";

        if (self.currentSituationID == id) then
            prefix = "|cFF00FF00";
            suffix = "|r";
        elseif (not situation.enabled) then
            prefix = "|cFF808A87";
            suffix = "|r";
        elseif (conditionExecutionCache[id]) then
            prefix = "|cFF63B8FF";
            suffix = "|r";
        end

        if (string.find(id, "custom")) then
            customPrefix = "Custom: ";
        end

        situationList[id] = prefix..customPrefix..situation.name..suffix;
    end

    return situationList;
end

function DynamicCam:CopySituationInto(fromID, toID)
    -- make sure that both from and to are valid situationIDs
    if (not fromID or not toID or fromID == toID or not self.db.profile.situations[fromID] or not self.db.profile.situations[toID]) then
        self:DebugPrint("CopySituationInto has invalid from or to!");
        return;
    end

    local from = self.db.profile.situations[fromID];
    local to = self.db.profile.situations[toID];

    -- copy settings over
    to.enabled = from.enabled;

    -- a more robust solution would be much better!
    to.cameraActions = {};
    for key, value in pairs(from.cameraActions) do
        to.cameraActions[key] = from.cameraActions[key];
    end

    to.view = {};
    for key, value in pairs(from.view) do
        to.view[key] = from.view[key];
    end

    to.extras = {};
    for key, value in pairs(from.extras) do
        to.extras[key] = from.extras[key];
    end

    to.cameraCVars = {};
    for key, value in pairs(from.cameraCVars) do
        to.cameraCVars[key] = from.cameraCVars[key];
    end

    self:SendMessage("DC_SITUATION_UPDATED", toID);
end

function DynamicCam:UpdateSituation(situationID)
    local situation = self.db.profile.situations[situationID];
    if (situation and (situationID == self.currentSituationID)) then
        -- apply cvars
        for cvar, value in pairs(situation.cameraCVars) do
            DC_SetCVar(cvar, value);
        end
        self:ApplyDefaultCameraSettings();
    end
    DC_RunScript(situation.executeOnInit, situationID);
    self:RegisterSituationEvents(situationID);
    self:EvaluateSituations();
end

function DynamicCam:CreateCustomSituation(name)
    -- search for a clear id
    local highest = 0;

    -- go through each and every situation, look for the custom ones, and find the
    -- highest custom id
    for id, situation in pairs(self.db.profile.situations) do
        local i, j = string.find(id, "custom");

        if (i and j) then
            local num = tonumber(string.sub(id, j+1));

            if (num and num > highest) then
                highest = num;
            end
        end
    end

    -- copy the default situation into a new table
    local newSituationID = "custom"..(highest+1);
    local newSituation = copyTable(self.defaults.profile.situations["**"]);

    newSituation.name = name;

    -- create the entry in the profile with an id 1 higher than the highest already customID
    self.db.profile.situations[newSituationID] = newSituation;

    -- make sure that the options panel reselects a situation
    if (Options) then
        Options:SelectSituation(newSituationID);
    end

    self:SendMessage("DC_SITUATION_UPDATED", newSituationID);
    return newSituation, newSituationID;
end

function DynamicCam:DeleteCustomSituation(situationID)
    if (not self.db.profile.situations[situationID]) then
        self:DebugPrint("Cannot delete this situation since it doesn't exist", situationID)
    end

    if (not string.find(situationID, "custom")) then
        self:DebugPrint("Cannot delete a non-custom situation");
    end

    -- if we're currently in this situation, exit it
    if (self.currentSituationID == situationID) then
        self:ExitSituation(situationID);
    end

    -- delete the situation
    self.db.profile.situations[situationID] = nil;

    -- make sure that the options panel reselects a situation
    if (Options) then
        Options:ClearSelection();
        Options:SelectSituation();
    end

    -- EvaluateSituations because we might have changed the current situation
    self:EvaluateSituations();
end


-------------
-- UTILITY --
-------------
function DynamicCam:ApplyDefaultCameraSettings(newSituationID)
    local curSituation = self.db.profile.situations[self.currentSituationID];

    if (newSituationID) then
        curSituation = self.db.profile.situations[newSituationID];
    end

    -- apply ActionCam setting
    if (self.db.profile.actionCam) then
        -- if it's on, unregister the event, so that we don't get popup
        UIParent:UnregisterEvent("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED");
    else
        -- if it's off, make sure to reset all ActionCam settings, then reenable popup
        ResetTestCvars();
        UIParent:RegisterEvent("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED");
    end

    -- apply default settings if the current situation isn't overriding them
    for cvar, value in pairs(self.db.profile.defaultCvars) do
        if (not curSituation or not curSituation.cameraCVars[cvar]) then
            if (cvar == "test_cameraOverShoulder") then
                stopEasingShoulderOffset();
                if (not (GetCVar("test_cameraOverShoulder") == tostring(value))) then
                    easeShoulderOffset(value, 0.75);
                end
            else
                DC_SetCVar(cvar, value);
            end
        end
    end
end

function DynamicCam:ShouldRestoreZoom(oldSituationID, newSituationID)
    local newSituation = self.db.profile.situations[newSituationID];

    -- don't restore if we don't have a saved zoom value
    if (not restoration[oldSituationID].zoom) then
        return false;
    end

    -- restore if we're just exiting a situation, but not going into a new one
    if (not newSituation) then
        self:DebugPrint("Restoring because just exiting");
        return true;
    end

    -- only restore zoom if returning to the same situation
    if (restoration[oldSituationID].zoomSituation ~= newSituationID) then
        return false;
    end

    -- don't restore zoom if we're about to go into a view
    if (newSituation.view.enabled) then
        return false;
    end

    -- restore zoom based on newSituation zoomSetting
    if (newSituation.cameraActions.zoomSetting == "off") then
        -- don't restore zoom if the new situation doesn't zoom at all
        return false;
    elseif (newSituation.cameraActions.zoomSetting == "set") then
        -- don't restore zoom if the zoom is going to be setting the zoom anyways
        return false;
    elseif (newSituation.cameraActions.zoomSetting == "fit") then
        -- don't restore zoom to a zoom fit
        return false;
    elseif (newSituation.cameraActions.zoomSetting == "range") then
        --only restore zoom if zoom will be in the range
        if ((newSituation.cameraActions.zoomMin <= restoration[oldSituationID].zoom + .5) and
            (newSituation.cameraActions.zoomMax >= restoration[oldSituationID].zoom - .5)) then
            return true;
        end
    elseif (newSituation.cameraActions.zoomSetting == "in") then
        -- only restore if restoration zoom will still be acceptable
        if (newSituation.cameraActions.zoomValue >= restoration[oldSituationID].zoom - .5) then
            return true;
        end
    elseif (newSituation.cameraActions.zoomSetting == "out") then
        -- restore zoom if newSituation is zooming out and we would already be zooming out farther
        if (newSituation.cameraActions.zoomValue <= restoration[oldSituationID].zoom + .5) then
            return true;
        end
    end

    -- if nothing else, don't restore
    return false;
end


-------------------
-- REACTIVE ZOOM --
-------------------
local targetZoom;
local oldCameraZoomIn = CameraZoomIn;
local oldCameraZoomOut = CameraZoomOut;

local function clearTargetZoom(wasInterrupted)
    if (not wasInterrupted) then
        targetZoom = nil;
    end
end

local function ReactiveZoom(zoomIn, increments, automated)
    increments = increments or 1;

    if (not automated and increments == 1) then
        local currentZoom = GetCameraZoom();

        local addIncrementsAlways = DynamicCam.db.profile.reactiveZoom.addIncrementsAlways;
        local addIncrements = DynamicCam.db.profile.reactiveZoom.addIncrements;
        local maxZoomTime = DynamicCam.db.profile.reactiveZoom.maxZoomTime;
        local incAddDifference = DynamicCam.db.profile.reactiveZoom.incAddDifference;
        local easingFunc = DynamicCam.db.profile.reactiveZoom.easingFunc;

        -- if we've change directions, make sure to reset
        if (zoomIn) then
            if (targetZoom and targetZoom > currentZoom) then
                targetZoom = nil;
            end
        else
            if (targetZoom and targetZoom < currentZoom) then
                targetZoom = nil;
            end
        end

        -- scale increments up
        if (increments == 1) then
            if (targetZoom) then
                local diff = math.abs(targetZoom - currentZoom);

                if (diff > incAddDifference) then
                    increments = increments + addIncrementsAlways + addIncrements;
                else
                    increments = increments + addIncrementsAlways;
                end
            else
                increments = increments + addIncrementsAlways;
            end
        end

        -- if there is already a target zoom, base off that one, or just use the current zoom
        targetZoom = targetZoom or currentZoom;

        if (zoomIn) then
            targetZoom = math.max(0, targetZoom - increments);
        else
            targetZoom = math.min(39, targetZoom + increments);
        end

        -- if we don't need to zoom because we're at the max limits, then don't
        if ((targetZoom == 39 and currentZoom == 39)
            or (targetZoom == 0 and currentZoom == 0)) then
            return;
        end

        -- round target zoom off to the nearest decimal
        targetZoom = round(targetZoom, 1);

        -- get the current time to zoom if we were going linearly or use maxZoomTime, if that's too high
        local zoomTime = math.min(maxZoomTime, math.abs(targetZoom - currentZoom)/tonumber(GetCVar("cameraZoomSpeed")));

        LibCamera:SetZoom(targetZoom, zoomTime, LibEasing[easingFunc], clearTargetZoom);
    else
        if (zoomIn) then
            oldCameraZoomIn(increments, automated);
        else
            oldCameraZoomOut(increments, automated);
        end
    end
end

local function ReactiveZoomIn(increments, automated)
    ReactiveZoom(true, increments, automated);
end

local function ReactiveZoomOut(increments, automated)
    ReactiveZoom(false, increments, automated);
end

function DynamicCam:ReactiveZoomOn()
    CameraZoomIn = ReactiveZoomIn;
    CameraZoomOut = ReactiveZoomOut;
end

function DynamicCam:ReactiveZoomOff()
    CameraZoomIn = oldCameraZoomIn;
    CameraZoomOut = oldCameraZoomOut;
end


------------
-- EVENTS --
------------
local lastEvaluate;
local TIME_BEFORE_NEXT_EVALUATE = .1;
local EVENT_DOUBLE_TIME = .2;

function DynamicCam:EventHandler(event, possibleUnit, ...)
    -- we don't want to evaluate too often, some of the events can be *very* spammy
    if (not lastEvaluate or (lastEvaluate and ((lastEvaluate + TIME_BEFORE_NEXT_EVALUATE) < GetTime()))) then
        lastEvaluate = GetTime();

        -- call the evaluate
        self:EvaluateSituations();

        -- double the event, since a lot of events happen before the condition turns out to be true
        evaluateTimer = self:ScheduleTimer("EvaluateSituations", EVENT_DOUBLE_TIME);
    else
        -- we're delaying the call of evaluate situations until next evaluate
        if (not evaluateTimer) then
            evaluateTimer = self:ScheduleTimer("EvaluateSituations", TIME_BEFORE_NEXT_EVALUATE);
        end
    end
end

function DynamicCam:RegisterEvents()
    self:RegisterEvent("PLAYER_CONTROL_GAINED", "EventHandler");

    for situationID, situation in pairs(self.db.profile.situations) do
        self:RegisterSituationEvents(situationID);
    end
end

function DynamicCam:RegisterSituationEvents(situationID)
    local situation = self.db.profile.situations[situationID];
    if (situation and situation.events) then
        for i, event in pairs(situation.events) do
            if (not events[event]) then
                events[event] = true;
                self:RegisterEvent(event, "EventHandler");
                -- self:DebugPrint("Registered for event:", event);
            end
        end
    end
end

function DynamicCam:DC_SITUATION_ENABLED(message, situationID)
    self:EvaluateSituations();
end

function DynamicCam:DC_SITUATION_DISABLED(message, situationID)
    self:EvaluateSituations();
end

function DynamicCam:DC_SITUATION_UPDATED(message, situationID)
    self:UpdateSituation(situationID);
    self:EvaluateSituations();
end

function DynamicCam:DC_BASE_CAMERA_UPDATED(message)
    self:ApplyDefaultCameraSettings();
end


--------------
-- DATABASE --
--------------
local firstDynamicCamLaunch = false;
local upgradingFromOldVersion = false;
StaticPopupDialogs["DYNAMICCAM_FIRST_RUN"] = {
    text = "Welcome to your first launch of DynamicCam!\n\nIt is highly suggested to load a preset to start, since the addon starts completely unconfigured.",
    button1 = "Open Presets",
    button2 = "Close",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,  -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
    OnAccept = function()
        InterfaceOptionsFrame_OpenToCategory(Options.presets);
        InterfaceOptionsFrame_OpenToCategory(Options.presets);
    end,
    OnCancel = function(_, reason)
    end,
}

StaticPopupDialogs["DYNAMICCAM_FIRST_LOAD_PROFILE"] = {
    text = "The current DynamicCam profile is fresh and probably empty.\n\nWould you like to see available DynamicCam presets?",
    button1 = "Open Presets",
    button2 = "Close",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,  -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
    OnAccept = function()
        InterfaceOptionsFrame_OpenToCategory(Options.presets);
        InterfaceOptionsFrame_OpenToCategory(Options.presets);
    end,
    OnCancel = function(_, reason)
    end,
}

StaticPopupDialogs["DYNAMICCAM_UPDATED"] = {
    text = "DynamicCam has been updated, would you like to open the main menu?\n\nThere's a changelog right in there! (You may need to scroll down)",
    button1 = "Open Menu",
    button2 = "Close",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,  -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
    OnAccept = function()
        InterfaceOptionsFrame_OpenToCategory(Options.menu);
        InterfaceOptionsFrame_OpenToCategory(Options.menu);
    end,
}

function DynamicCam:InitDatabase()
    self.db = LibStub("AceDB-3.0"):New("DynamicCamDB", self.defaults, true);
    self.db.RegisterCallback(self, "OnProfileChanged", "RefreshConfig");
    self.db.RegisterCallback(self, "OnProfileCopied", "RefreshConfig");
    self.db.RegisterCallback(self, "OnProfileReset", "RefreshConfig");
    self.db.RegisterCallback(self, "OnDatabaseShutdown", "Shutdown");

    -- remove dbVersion, move to a per-profile version number
    if (self.db.global.dbVersion) then
        upgradingFromOldVersion = true;
        self.db.global.dbVersion = nil;
    end

    if (not DynamicCamDB.profiles) then
        firstDynamicCamLaunch = true;
    else
        -- reset db if we've got a really old version
        local veryOldVersion = false;
        for profileName, profile in pairs(DynamicCamDB.profiles) do
            if (profile.defaultCvars and profile.defaultCvars["cameraovershoulder"]) then
                veryOldVersion = true;
            end
        end

        if (veryOldVersion) then
            self:Print("Detected very old version, resetting DB, sorry about that!");
            self.db:ResetDB();
        end

        -- modernize each profile
        for profileName, profile in pairs(DynamicCamDB.profiles) do
            self:ModernizeProfile(profile);
        end

        -- show the updated popup
        if (upgradingFromOldVersion) then
            StaticPopup_Show("DYNAMICCAM_UPDATED");
        end
    end
end

function DynamicCam:ModernizeProfile(profile)
    if (not profile.version) then
        profile.version = 1;
    end

    local startVersion = profile.version;

    if (profile.version == 1) then
        if (profile.defaultCvars and profile.defaultCvars["test_cameraLockedTargetFocusing"] ~= nil) then
            profile.defaultCvars["test_cameraLockedTargetFocusing"] = nil;
        end

        upgradingFromOldVersion = true;
        profile.version = 2;
        profile.firstRun = false;
    end

    -- modernize each situation
    if (profile.situations) then
        for situationID, situation in pairs(profile.situations) do
            self:ModernizeSituation(situation, startVersion);
        end
    end
end

function DynamicCam:ModernizeSituation(situation, version)
    if (version == 1) then
        -- clear unused nameplates db stuff
        if (situation.extras) then
            situation.extras["nameplates"] = nil;
            situation.extras["friendlyNameplates"] = nil;
            situation.extras["enemyNameplates"] = nil;
        end

        -- update targetlock features
        if (situation.targetLock) then
            if (situation.targetLock.enabled) then
                if (not situation.cameraCVars) then
                    situation.cameraCVars = {};
                end

                if (situation.targetLock.onlyAttackable ~= nil and situation.targetLock.onlyAttackable == false) then
                    situation.cameraCVars["test_cameraTargetFocusEnemyEnable"] = 1;
                    situation.cameraCVars["test_cameraTargetFocusInteractEnable"] = 1
                else
                    situation.cameraCVars["test_cameraTargetFocusEnemyEnable"] = 1;
                end
            end

            situation.targetLock = nil;
        end

        -- update camera rotation
        if (situation.cameraActions) then
            -- convert to yaw degrees instead of rotate degrees
            if (situation.cameraActions.rotateDegrees) then
                situation.cameraActions.yawDegrees = situation.cameraActions.rotateDegrees;
                situation.cameraActions.pitchDegrees = 0;
                situation.cameraActions.rotateDegrees = nil;
            end

            -- convert old scalar rotate speed to something that's in degrees/second
            if (situation.cameraActions.rotateSpeed and situation.cameraActions.rotateSpeed < 5) then
                situation.cameraActions.rotateSpeed = situation.cameraActions.rotateSpeed * tonumber(GetCVar("cameraYawMoveSpeed"));
            end
        end
    end
end

function DynamicCam:RefreshConfig()
    local profile = self.db.profile;

    -- shutdown the addon if it's enabled
    if (profile.enabled and started) then
        self:Shutdown();
    end

    -- situation is active, but db killed it
    if (self.currentSituationID) then
        self.currentSituationID = nil;
    end

    -- clear the options panel so that it reselects
    -- make sure that options panel selects a situation
    if (Options) then
        Options:ClearSelection();
        Options:SelectSituation();
    end

    -- present a menu that loads a set of defaults, if this is the profiles first run
    if (profile.firstRun) then
        if (firstDynamicCamLaunch) then
            StaticPopup_Show("DYNAMICCAM_FIRST_RUN");
            firstDynamicCamLaunch = false;
        else
            StaticPopup_Show("DYNAMICCAM_FIRST_LOAD_PROFILE");
        end
        profile.firstRun = false;
    end

    -- start the addon back up
    if (profile.enabled and not started) then
        self:Startup();
    end

    -- run all situations's advanced init script
    for id, situation in pairs(self.db.profile.situations) do
        DC_RunScript(situation.executeOnInit, id);
    end
end


-------------------
-- CHAT COMMANDS --
-------------------
local function tokenize(str, delimitor)
    local tokens = {};
    for token in str:gmatch(delimitor or "%S+") do
        table.insert(tokens, token);
    end
    return tokens;
end

StaticPopupDialogs["DYNAMICCAM_NEW_CUSTOM_SITUATION"] = {
    text = "Enter name for custom situation:",
    button1 = "Create!",
    button2 = "Cancel",
    timeout = 0,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,  -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
    OnShow = function (self, data)
        self.editBox:SetFocus();
    end,
    OnAccept = function (self, data)
        DynamicCam:CreateCustomSituation(self.editBox:GetText());
    end,
    EditBoxOnEnterPressed = function(self)
        DynamicCam:CreateCustomSituation(self:GetParent().editBox:GetText());
		self:GetParent():Hide();
	end,
}

local exportString;
StaticPopupDialogs["DYNAMICCAM_EXPORT"] = {
    text = "DynamicCam Export:",
    button1 = "Done!",
    timeout = 0,
    hasEditBox = true,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,  -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
    OnShow = function (self, data)
        self.editBox:SetText(exportString);
        self.editBox:HighlightText();
    end,
    EditBoxOnEnterPressed = function(self)
		self:GetParent():Hide();
	end,
}

function DynamicCam:OpenMenu(input)
    if (not Options) then
        Options = self.Options;
    end

    Options:SelectSituation();

    -- just open to the frame, double call because blizz bug
    InterfaceOptionsFrame_OpenToCategory(Options.menu);
    InterfaceOptionsFrame_OpenToCategory(Options.menu);
end

function DynamicCam:SaveViewCC(input)
    local tokens = tokenize(input);

    local viewNum = tonumber(tokens[1]);

    if (viewNum and viewNum <= 5 and viewNum > 1) then
        SaveView(viewNum);
    else
        self:Print("Improper view number provided.")
    end
end

function DynamicCam:ZoomInfoCC(input)
    self:Print(string.format("Zoom level: %0.2f", GetCameraZoom()));
end

function DynamicCam:ZoomSlash(input)
    local tokens = tokenize(input);

    local zoom = tonumber(tokens[1]);
    local time = tonumber(tokens[2]);
    local easingFuncName;
    local easingFunc;

    if (not time) then
        -- time not provided, maybe 2nd param is easingfunc?
        easingFuncName = tokens[2];
    else
        easingFuncName = tokens[3];
    end

    -- look up easing func
    if (easingFuncName) then
        easingFunc = LibEasing[easingFuncName] or LibEasing.InOutQuad;
    end

    if (zoom and (zoom <= 39 or zoom >= 0)) then
        local defaultTime = math.abs(zoom - GetCameraZoom()) / tonumber(GetCVar("cameraZoomSpeed"));
        LibCamera:SetZoom(zoom, time or math.min(defaultTime, 0.75), easingFunc);
    end
end

function DynamicCam:PitchSlash(input)
    local tokens = tokenize(input);

    local pitch = tonumber(tokens[1]);
    local time = tonumber(tokens[2]);
    local easingFuncName;
    local easingFunc;

    if (not time) then
        -- time not provided, maybe 2nd param is easingfunc?
        easingFuncName = tokens[2];
    else
        easingFuncName = tokens[3];
    end

    -- look up easing func
    if (easingFuncName) then
        easingFunc = LibEasing[easingFuncName] or LibEasing.InOutQuad;
    end

    if (pitch and (pitch <= 90 or pitch >= -90)) then
        LibCamera:Pitch(pitch, time or 0.75, easingFunc);
    end
end

function DynamicCam:YawSlash(input)
    local tokens = tokenize(input);

    local yaw = tonumber(tokens[1]);
    local time = tonumber(tokens[2]);
    local easingFuncName;
    local easingFunc;

    if (not time) then
        -- time not provided, maybe 2nd param is easingfunc?
        easingFuncName = tokens[2];
    else
        easingFuncName = tokens[3];
    end

    -- look up easing func
    if (easingFuncName) then
        easingFunc = LibEasing[easingFuncName] or LibEasing.InOutQuad;
    end

    if (yaw) then
        LibCamera:Yaw(yaw, time or 0.75, easingFunc);
    end
end

function DynamicCam:PopupCreateCustomProfile()
    StaticPopup_Show("DYNAMICCAM_NEW_CUSTOM_SITUATION");
end

function DynamicCam:PopupExport(str)
    exportString = str;
    StaticPopup_Show("DYNAMICCAM_EXPORT");
end

function DynamicCam:PopupExportProfile()
    self:PopupExport(self:ExportProfile())
end


-----------
-- CVARS --
-----------
function DynamicCam:ResetCVars()
    for cvar, value in pairs(self.db.profile.defaultCvars) do
        DC_SetCVar(cvar, GetCVarDefault(cvar));
    end

    ResetView(1);
    ResetView(2);
    ResetView(3);
    ResetView(4);
    ResetView(5);
end
