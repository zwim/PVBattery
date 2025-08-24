
local VERSION = "V4.9.0"

local Profiler = nil
-- profiler from https://github.com/charlesmallah/lua-profiler
--local Profiler = require("suntime/profiler")
if Profiler then
    Profiler.start()
end

local AntBMS = require("antbms")
local Fronius = require("fronius")
--local P1meter = require("p1meter")
local Marstek = require("marstek")
local SunTime = require("suntime/suntime")
local ChargerClass = require("charger")
local InverterClass = require("inverter")

local Influx = require("influx")

local config = require("configuration")
local mqtt_reader = require("mqtt_reader")
local util = require("util")
local socket = require("socket")

local state = {
    fail = "fail", -- unknown state
    recalculate = "recalculate",
    idle = "idle",
    charge = "charge",
    balance = "balance", -- during charge or on the high side
    full = "full",
    discharge = "discharge",
    low_battery = "low_battery",
    low_cell = "low_cell",
    cell_diff = "cell_diff",
    rescue_charge = "rescue_charge",
    force_discharge = "force_discharge",
    shutdown = "shutdown", -- shut down all charging and discharging ...
}

local PVBattery = {
    BMS = {},
    Charger = {},
    Inverter = {},

    _state = "", -- no state yet

    -- very coarse default sunrise and sunset
    sunrise = 6,
    sunset = 18,
}

-------------------- extend functions from this file
PVBattery.generateHTML = require("PVBatteryHTML")
PVBattery.serverCommands = require("servercommands")
--------------------

-- Helper to format solar times
local function formatSunEvent(label, hourVal)
    local h, m, s = util.hourToTime(hourVal)
    local str = string.format("%02d:%02d:%02d", h, m, s)
    util:log(label .. " at " .. str)
    return str
end


function PVBattery:init()
    config:read()
    util:setLog(config.log_file_name or "PVBattery.log")
    util:setCompressor(config.compressor)

    util:log("\n#############################################")
    util:log("PV-Control started.")
    util:log("#############################################")

    -- Uhhhohhh we need correct ephemerides ;-)
    local position = config.position
    SunTime:setPosition(position.name, position.latitude, position.longitude, position.timezone, position.height, true)

    SunTime:setDate()
    SunTime:calculateTimes()

    self.sunrise = formatSunEvent("Sun rise", SunTime.rise)
    self.sunset  = formatSunEvent("Sun set", SunTime.set)

    -- IMPORTANT: Our authorative power meter, which shows if we produce or consume energy
    Fronius = Fronius:new{host = config.FRONIUS_ADR}
--    P1meter = P1meter:new{host = "HW-p1meter-367096.lan"}

    -- Init all device configurations

    self.VenusE = Marstek:new({ip = "192.168.0.208", port=502, slaveId = 1})

    self.BMS = {}
    self.Charger = {}
    self.Inverter = {}
    for _, Device in ipairs(config.Device) do
        local BMS
        if Device.BMS ~= nil then
            BMS = AntBMS:new{
                host = Device.BMS,
                lastFullPeriod = config.lastFullPeriod,
                min_cell_diff = config.min_cell_diff,
                minPower = config.minPower,
            }
            table.insert(self.BMS, BMS)
        end

        local Inverter = InverterClass:new {
            host = Device.inverter_switch,
            min_power = Device.inverter_min_power,
            time_controlled = Device.inverter_time_controlled,
            BMS = BMS,
        }
        table.insert(self.Inverter, Inverter)
        mqtt_reader:clearRetainedMessages(self.Inverter.host)
        mqtt_reader:askHost(self.Inverter.host)
        mqtt_reader:updateStates()

        for i = 1, #Device.charger_switches do
            local Charger = ChargerClass:new{
                host = Device.charger_switches[i],
                max_power = Device.charger_max_power[i],
                BMS = BMS,
            }
            if BMS then
                BMS.wakeup = function()
                    print("Wakeup charge started")
                    Charger:startCharge()
                    util.sleepTime(config.sleep_time)
                end
            end
            table.insert(self.Charger, Charger)
            mqtt_reader:clearRetainedMessages(self.Charger.host)
            mqtt_reader:askHost(self.Charger.host)
            mqtt_reader:updateStates()
        end
    end

    -- Influx:init("http://localhost:8086", "", "Photovoltaik", "Leistung")
    Influx:init(config.db_url, config.db_token, config.db_org, config.db_bucket)
end

function PVBattery:getState()
    return self._state or state.fail
end

function PVBattery:setState(new_state)
    if state[new_state] == new_state then
        self._state = new_state
    else
        print("Error wrong state selected", new_state)
        self._state = state.fail
    end
    return self._state
end

local function printStackTrace(this)
    local stackTrace = debug.traceback()
    print("Stack Trace:")
    print(stackTrace)
    for i, v in pairs(this) do
        print(i, v)
    end
    for i,v in pairs(mqtt_reader.states) do
        print(i,v)
    end
end

function PVBattery:updateState()
      -- Helper to ensure BMS data is available
    local function ensureBMSData(BMS)
        for _ = 1, 5 do
            if BMS:getData() then return true end
            util.sleepTime(2)
            print("Problem getting BMS data")
        end
        return BMS:getData()
    end

    -- first check the critical parts of the battery
    for _, BMS in ipairs(self.BMS) do
        if ensureBMSData(BMS) then
            if BMS:isLowChargedOrNeedsRescue() and BMS:needsRescueCharge() then
                return self:setState(state.rescue_charge)
            elseif BMS.v.SOC <= config.bat_SOC_min then
                return self:setState(state.low_battery)
            elseif BMS.v.CellDiff > config.max_cell_diff then
                return self:setState(state.cell_diff)
            elseif self:getState() == state.cell_diff
                and BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
                return self:setState(state.cell_diff)
            end
        else
            return self:callStateHandler(state.shutdown)
        end
    end

    for _, Charger in ipairs(self.Charger) do
        if Charger:getPowerState() == "on" then
            return self:setState(state.charge)
        end
    end

    for _, Inverter in ipairs(self.Inverter) do
        if not Inverter.time_controlled then
            local power_state = Inverter:getPowerState()
            if power_state == "on" then
                local discharge_state = Inverter.BMS:getDischargeState()
                if discharge_state == "off" then
--                    printStackTrace(self)
                    return self:setState(state.force_discharge)
                elseif discharge_state == "on" then
                    return self:setState(state.discharge)
                end
            end
        end
    end

    -- Do the not so critical battery care
    for _, BMS in ipairs(self.BMS) do
        if ensureBMSData(BMS) then
            if BMS:needsBalancing() then
                return self:setState(state.balance)
            end
        end
    end

    return self:setState(state.idle)
end

function PVBattery:callStateHandler(new_state)
    local stateHandler = self[new_state or self._state]
    if stateHandler then
        stateHandler(self) -- execute the state
        return self._state
    end
    return false
end

-- luacheck: ignore self
function PVBattery:isSellingMoreThan(limit)
    limit = limit or 0
    return -self.P_Grid > limit
end

-- luacheck: ignore self
function PVBattery:isBuyingMoreThan(limit)
    limit = limit or 0
    return self.P_Grid > limit
end

function PVBattery:turnOffBestCharger()
    local charger_num = 0
    local charger_power = 0

    -- If we sell more than 20W and VenusE is charging then
    if self:isSellingMoreThan(10) and self.VenusE:isChargingMoreThan(0) then
        print("Error: req_power " .. self.P_Grid .. " < 10W and VenusE is Charging")
    end

    for i, Charger in ipairs(self.Charger) do
        if Charger:getPowerState() == "on" and
            not (Charger.BMS:isLowChargedOrNeedsRescue() and Charger.BMS:needsRescueCharge()) then
            -- process only activated chargers
            local charging_power = Charger:getPower() or math.huge
            if charging_power > self.P_Grid or charging_power > charger_power then
                -- either one charging power that is larger than requested power (✓)
                -- or the largest charging power (✓)
                charger_num = i
                charger_power = charging_power
            end
        end
    end

    -- allow a small power buy instead of a bigger power sell.
    -- Only activate one inverter, as the current is only estimated-
    if charger_num > 0 then
        util:log(string.format("Deactivate Charger: %s with %s W",
                charger_num, charger_power))
        self.Charger[charger_num]:stopCharge()
        return true
    end
    return false
end

function PVBattery:turnOffBestInverter()
    local inverter_num = 0
    for i, Inverter in ipairs(self.Inverter) do
        if not Inverter.time_controlled and Inverter.BMS then
            if Inverter.BMS:getDischargeState() == "on" and Inverter:getPowerState() == "on" then
                -- Inverter delivers min_power (positive), VenusE delivers power (positive)
                local max_power = Inverter:getMaxPower()
                if self.P_VenusE < max_power or (self.P_VenusE >= 0 and self:isSellingMoreThan(50)) then
                    util:log("debug xxx "..i, "P_VenusE ".. self.P_VenusE, "P_Grid "..self.P_Grid,
                        "max_power "..max_power)
                    inverter_num = i
                    break
                end
            end
            local _, continue_discharge = Inverter.BMS:readyToDischarge()
            if not continue_discharge then
                util:log("got you sucker xxx")
                inverter_num = i
                break
            end
        end
    end

    if inverter_num > 0 then
        util:log(string.format("Deactivate inverter: %s", inverter_num))
        self.Inverter[inverter_num]:stopDischarge()
        return true
    end
    return false
end


function PVBattery:turnOffBestChargerAndThenTurnOnBestInverter()
    if self:turnOffBestCharger() then -- Is there a charger to turn off?
        return false
    end

    local inverter_num = 0
    local inverter_power = 0
    local already_discharging = false

    for i, Inverter in ipairs(self.Inverter) do
        if not Inverter.time_controlled then
            local start_discharge, continue_discharge = Inverter.BMS:readyToDischarge()
            if start_discharge then
                local min_power = math.max(Inverter.min_power, Inverter:getMaxPower())
                -- Inverter delivers min_power (positive), VenusE delivers power (negative)
                -- If req_power is positive, we buy energy
                if self.VenusE:isDischargingMoreThan(min_power)
                    or (min_power < self.P_Grid and min_power > inverter_power) then
                    if Inverter.BMS:getDischargeState() == "off" or Inverter:getPowerState() == "off" then
                        inverter_num = i
                        inverter_power = min_power
                    end
                end
            elseif not continue_discharge then
                Inverter:stopDischarge()
            end
            if Inverter:getPowerState() == "on" then
                already_discharging = true
            end
        end
    end

    -- Only activate one inverter, as the current is only estimated-
    if inverter_num > 0 then
        util:log(string.format("Activate inverter: %s with %5.2f W",
                inverter_num, inverter_power))
        self.Inverter[inverter_num]:startDischarge(self.P_Grid)
        return true
    end
    return already_discharging
end

function PVBattery:turnOffBestInverterAndThenTurnOnBestCharger()
    if self:turnOffBestInverter() then -- no inverter running
        return false
    end

    local charger_num = 0
    local charger_power = 0
    local already_charging = false

    for i, Charger in ipairs(self.Charger) do
        local max_power = Charger:getMaxPower() or 0
        if (max_power < -self.P_Grid and max_power > charger_power) or max_power < -self.P_VenusE then
            if Charger:readyToCharge() then
                local power_state = Charger:getPowerState()
                if  power_state == "off" then
                    charger_num = i
                    charger_power = max_power
                elseif power_state == "on" then
                    already_charging = true
                end
            end
        end
    end

    -- Activate one charger, as the current is only estimated.
    if charger_num > 0 then
        util:log(string.format("Activate charger: %s with %5.2f W",
                charger_num, charger_power))

        self.Charger[charger_num]:startCharge()
        return true
    end
    return already_charging
end

-- luacheck: ignore self
PVBattery[state.cell_diff] = function(self)
    if self:turnOffBestInverterAndThenTurnOnBestCharger() then
        self:setState(state.charge)
    end

    for _, BMS in ipairs(self.BMS) do
        if BMS:getData() then
            if BMS.v.SOC > config.bat_SOC_max - 5 then
                if BMS:needsBalancing() then
                    BMS:enableDischarge()
                    BMS:setAutoBalance(true)
                end
            end
        end
    end

    for _, Inverter in ipairs(self.Inverter) do
        if not Inverter.time_controlled then
            Inverter:stopDischarge()
        end
    end
end

-- luacheck: ignore self
PVBattery[state.low_cell] = function(self)
    if self:turnOffBestInverterAndThenTurnOnBestCharger() then
        self:setState(state.charge)
    end

    for _, Inverter in ipairs(self.Inverter) do
        if not Inverter.time_controlled then
            if Inverter.BMS:isLowChargedOrNeedsRescue() then
                Inverter:stopDischarge()
            end
        end
    end
end

PVBattery[state.low_battery] = PVBattery[state.low_cell]

function PVBattery:setChargeOrDischarge()
    if (self:isSellingMoreThan(30) and self.VenusE:isIdle()) or self.VenusE:isChargingMoreThan(100) then
        if self:turnOffBestInverterAndThenTurnOnBestCharger() then
            return state.charge
        end
    elseif (self:isBuyingMoreThan(0) and self.VenusE:isIdle()) or self.VenusE:isDischargingMoreThan(10) then
        if self:turnOffBestChargerAndThenTurnOnBestInverter() then
            return state.discharge
        end
    end
    return state.idle
end

-- luacheck: ignore self
PVBattery[state.idle] = function(self, expected_state)
    expected_state = expected_state or self:setChargeOrDischarge()
    if expected_state == state.charge or expected_state == state.discharge then
        self[expected_state](self, expected_state)
    else
        for _, Charger in ipairs(self.Charger) do
            Charger:safeStopCharge()
        end
        for _, BMS in ipairs(self.BMS) do
            BMS:disableDischarge()
        end
        for _, Inverter in ipairs(self.Inverter) do
            if not Inverter.time_controlled then
                Inverter:stopDischarge()
            end
        end
        self:setState(state.recalculate)
    end
end

-- luacheck: ignore self
PVBattery[state.charge] = function(self, expected_state)
    expected_state = expected_state or self:setChargeOrDischarge()
    self:setState(expected_state)
    if expected_state == state.charge then
        for _, BMS in ipairs(self.BMS) do
            local is_full = BMS:isBatteryFull()
            local needs_balancing = BMS:needsBalancing()
            if is_full then
                for _, Charger in ipairs(self.Charger) do
                    if Charger.BMS == BMS then
                        Charger:stopCharge()
                        self:setState(state.recalculate)
                    end
                end
            end
            if needs_balancing then
                BMS:enableDischarge()
                BMS:setAutoBalance(true)
                self:setState(state.balance)
            end
--[[            if not needs_balancing and not is_full then
                for _, Charger in ipairs(self.Charger) do
                    if Charger.BMS == BMS then
                        Charger:startCharge()
                        self:setState(state.recalculate)
                    end
                end
            end
        ]]
        end
    elseif expected_state == state.discharge then
        PVBattery[state.discharge](self, expected_state)
    end
end

-- luacheck: ignore self
PVBattery[state.balance] = function(self)
    local expected_state = self:setChargeOrDischarge()

    if expected_state == state.idle then
        for _, Charger in ipairs(self.Charger) do
            Charger:stopCharge()
            self:setState(state.recalculate)
        end
    end

    for _, BMS in ipairs(self.BMS) do
        if BMS:needsBalancing() then
            BMS:enableDischarge()
            BMS:setAutoBalance(true)
            return
        end
        if BMS:isBatteryFull() then
            self:setState(state.full)
            return
        end
    end
    if expected_state == state.charge then
        self:setState(state.charge)
    elseif expected_state == state.discharge then
        self:setState(state.discharge)
    end
end

-- luacheck: ignore self
PVBattery[state.discharge] = function(self, expected_state)
    expected_state = expected_state or self:setChargeOrDischarge()
    self:setState(expected_state)
    if expected_state == state.discharge then

--[[        for _, BMS in ipairs(self.BMS) do
                for _, Inverter in ipairs(self.Inverter) do
                    if Inverter.BMS == BMS then
                        Inverter:startDischarge()
                    end
                end
            end
        end
        ]]
    else
        PVBattery[expected_state](self, expected_state)
    end
end

-- luacheck: ignore self
PVBattery[state.full] = function(self)
    for _, Charger in ipairs(self.Charger) do
        Charger:stopCharge()
    end

    for _, BMS in ipairs(self.BMS) do
        BMS:setAutoBalance(false)
        BMS:disableDischarge()
        self:setState(state.balance)
    end
end

-- luacheck: ignore self
PVBattery[state.rescue_charge] = function(self)
    for _, Charger in ipairs(self.Charger) do
        if Charger.BMS:needsRescueCharge() then
            Charger:startCharge()
            self:setState(state.recalculate)
        end
    end
end

-- luacheck: ignore self
PVBattery[state.shutdown] = function(self)
    print("state -> shutdown")
    for _, Charger in ipairs(self.Charger) do
        Charger:safeStopCharge()
    end
    for _, Inverter in ipairs(self.Inverter) do
        if Inverter:getPowerState() == "on" and Inverter.BMS:getDischargeState() == "on"
            and not Inverter.time_controlled then
            Inverter:stopDischarge()
        end
    end
end

PVBattery[state.force_discharge] = function(self)
    print("state -> force_discharge")

    for _, Inverter in ipairs(self.Inverter) do
        if not Inverter.time_controlled then
            local power_state = Inverter:getPowerState()
            local discharge_state = Inverter.BMS:getDischargeState()
            if power_state ~= discharge_state then
                if Inverter:getPowerState() == "on" then
                    Inverter:startDischarge()
                    self:setState(state.discharge)
                else
                    Inverter:stopDischarge()
                    self:setState(state.recalculate)
                end
            end
        end
    end
end

--[[
-- Prefetch all switch values
function PVBattery:fillCache_sequential()
    for _, BMS in pairs(self.BMS) do
        BMS:getData()
    end
    for _, Inverter in pairs(self.Inverter) do
        Inverter:_getStatus()
    end
    for _, Charger in pairs(self.Charger) do
        Charger:_getStatus()
    end
end
]]

-- Prefetch all switch values
function PVBattery:fillCache()
    local threads = {}
    local socket_to_thread = {}
    local readable_sockets = {}

    local function addThread(co)
        table.insert(threads, { co = co })
    end

    -- Alle Coroutine-Erzeugungen
    for _, BMS in ipairs(self.BMS) do
        addThread(coroutine.create(function() return BMS:getData_coroutine() end))
    end
    addThread(coroutine.create(function() return Fronius:getPowerFlowRealtimeData_coroutine() end))
    -- addThread(coroutine.create(function() return P1meter:getData_coroutine() end))

    -- Erste Runde: starten der Coroutinen und Zuordnung zu Sockets
    for i = #threads, 1, -1 do
        local thread = threads[i]
        local ok, result = coroutine.resume(thread.co)

        if not ok then
            util:log("Coroutine error:", result)
            table.remove(threads, i)
        elseif type(result) == "boolean" then
            -- Keine Socket, Coroutine ist fertig
            table.remove(threads, i)
        else
            local sock_id = tostring(result)
            socket_to_thread[sock_id] = thread.co
            table.insert(readable_sockets, result)
        end
    end

    local timeout = util.getCurrentTime() + config.update_interval
    while #readable_sockets > 0 and util.getCurrentTime() < timeout do
        local ready = socket.select(readable_sockets, nil, 1)

        for _, sock in ipairs(ready) do
            local sock_id = tostring(sock)
            local thread = socket_to_thread[sock_id]

            if thread then
                local ok, result = coroutine.resume(thread)

                if not ok then
                    util:log("Coroutine resume error:", result)
                    socket_to_thread[sock_id] = nil
                elseif type(result) == "boolean" then
                    -- Coroutine ist fertig
                    socket_to_thread[sock_id] = nil
                else
                    socket_to_thread[sock_id] = thread
                end
            end
        end

        readable_sockets = {}
        for sock_id in ipairs(socket_to_thread) do
            local sock = socket.fromtostring and socket.fromtostring(sock_id)
            if sock then
                table.insert(readable_sockets, sock)
            end
        end
    end
end

function PVBattery:showCacheDataAge(verbose)
    local log = verbose and print or function() end
    local total, max_age = 0, 0
    local function report(name, age)
        log(string.format("%s: %5f s", name, age))
        total = total + age
        max_age = math.max(max_age, age)
    end
    for _, B in ipairs(self.BMS)     do report("BMS "     ..B.host, B:getDataAge()) end
    for _, C in ipairs(self.Charger) do report("Charger " ..C.host, C:getDataAge()) end
    for _, I in ipairs(self.Inverter)do report("Inverter "..I.host, I:getDataAge()) end
    report("Fronius "..Fronius.host, Fronius:getDataAge())
--    report("P1meter "..P1meter.host, P1meter:getDataAge())
    util:log(string.format("Savings: %5f s, sequential %5f s, parallel %5f s)", total - max_age, total, max_age))
end

function PVBattery:refreshCache()
--    local oldtime = util.getCurrentTime()
    self:fillCache()
--    print("time:", util.getCurrentTime() - oldtime)
    self:showCacheDataAge()
    self:getCurrentValues()
end

function PVBattery:outputTheLog(date_string, oldstate, newstate)
    local log_string
    log_string = string.format("%s  P_Grid=%5.0fW, P_Load=%5.0fW, Battery=%5.0fW, P_VenusE=%5.0fW",
        date_string, self.P_Grid or 0, self.P_Load or 0, self.BMS[1].v.CurrentPower or 0, self.P_VenusE or 0)
    log_string = log_string .. string.format(" %8s -> %8s", oldstate, newstate)

    if oldstate ~= newstate then
        print(log_string)

    end
    util:log(log_string)
    pcall(function() self:generateHTML(config, VERSION) end)
end

function PVBattery:writeToDatabase()
    local datum = "Leistung"
    Influx:writeLine("garage-inverter", datum, self.Inverter[1]:getPower())
    Influx:writeLine("battery-inverter", datum, self.Inverter[2]:getPower())
    Influx:writeLine("balkon-inverter", datum, self.Inverter[3]:getPower())

    Influx:writeLine("battery-charger", datum, self.Charger[1]:getPower())
    Influx:writeLine("battery-charger2", datum, self.Charger[2]:getPower())

    Influx:writeLine("P_PV", datum, self.P_PV)
    Influx:writeLine("P_Grid", datum, self.P_Grid)
    Influx:writeLine("P_Load", datum, self.P_Load)

    Influx:writeLine("P_VenusE", datum, self.P_VenusE)

    Influx:writeLine("Status", "Status", self:getState())


    datum = "Energie"
    Influx:writeLine("garage-inverter", datum, self.Inverter[1]:getEnergyTotal())
    Influx:writeLine("battery-inverter", datum, self.Inverter[2]:getEnergyTotal())
    Influx:writeLine("balkon-inverter", datum, self.Inverter[3]:getEnergyTotal())

    Influx:writeLine("battery-charger", datum, self.Charger[1]:getEnergyTotal())
    Influx:writeLine("battery-charger2", datum, self.Charger[2]:getEnergyTotal())


end

function PVBattery:getCurrentValues()
    -- Positive values mean power going into Fronius;
    -- e.g. positive P_Grid we buy energy
    --      negative P_Grid we sell energy
    local P_Grid, P_Load, P_PV, P_AC = Fronius:getGridLoadPV()

    -- Positive values mean VenusE is discharging
    -- Nagative values mean power is charging
    local P_VenusE = self.VenusE:readACPower()
    P_VenusE = P_VenusE and math.floor(P_VenusE) or 0
    local VenusE_SOC = self.VenusE:readBatterySOC()

    local repeat_request = 5
    while (not self.P_Grid or not self.P_Load or not self.P_PV or not self.P_VenusE) and repeat_request > 0 do
        repeat_request = repeat_request - 1
        util.sleepTime(1) -- try again in 1 second
        if not P_Grid or not P_Load or not P_PV then
            util:log("Communication error: repeat request:", repeat_request)
            P_Grid, P_Load, P_PV, P_AC = Fronius:getGridLoadPV()
        end
        if not P_VenusE then
            P_VenusE = self.VenusE:readACPower()
        end
    end

    -- Normally P_PV comes from panel and P_AC is less, so use the smaller one
    if P_PV and P_AC then
        P_PV = math.min(P_PV, P_AC)
    end
    self.P_Grid = P_Grid
    self.P_Load = P_Load
    self.P_PV = P_PV
    self.P_VenusE = P_VenusE
    -- Defautlt to 0 % or 0 W if no marstek is found.
    self.VenusE_SOC = VenusE_SOC and math.floor(VenusE_SOC) or 0

--    mqtt_reader:askHost("battery-inverter")
--    mqtt_reader:askHost("garage-inverter")

    mqtt_reader:updateStates()
end

function PVBattery:main(profiling_runs)
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

    local rescue_stop = math.floor(60/4) + 1
    while type(profiling_runs) ~= "number" or profiling_runs > 0 do
        if type(profiling_runs) == "number" then
            profiling_runs = profiling_runs - 1
        end
        local skip_loop = false
        local short_sleep = nil -- a number here will shorten the sleep time
        local _start_time = util.getCurrentTime()

        -- if config has changed, reload it
        if config:needUpdate() then
            if config:read(true) then
                short_sleep = 1
            end
        end

        last_date = date
        date = os.date("*t")
        util:log("\n#############################################")

        local date_string = string.format("%d/%d/%d-%02d:%02d:%02d",
        last_date.year, last_date.month, last_date.day,
        last_date.hour, last_date.min, last_date.sec)

        util:log(date_string)

        -- Do the sun set and rise calculations if necessary
        if last_date.day ~= date.day or last_date.isdst ~= date.isdst then
            SunTime:setDate()
            SunTime:calculateTimes()
            util:cleanLogs()
            local h, m, s
            h, m, s = util.hourToTime(SunTime.rise)
            self.sunrise = string.format("%02d:%02d:%02d", h, m, s)
            util:log("Sun rise at " .. self.sunrise)
            h, m, s = util.hourToTime(SunTime.set)
            self.sunset = string.format("%02d:%02d:%02d", h, m, s)
            util:log("Sun set at " .. self.sunset)
            short_sleep = 1
        end

        -- Update Fronius
        util:log("\n-------- Total Overview:")

        self:refreshCache()

        if not self.P_Grid or not self.P_Load or not self.P_PV or not self.P_VenusE then
            short_sleep = 4
            skip_loop = true
            rescue_stop = rescue_stop - 1
            if rescue_stop < 0 then
                self[state.shutdown](self)
            end
        else
            rescue_stop = math.floor(60/4) + 1
        end

        if not skip_loop then
            util:log(string.format("Grid %8f W (%s)", self.P_Grid, self.P_Grid > 0 and "optaining" or "selling"))
            util:log(string.format("Load %8f W", self.P_Load))
            util:log(string.format("Roof %8f W", self.P_PV))
            util:log(string.format("VenusE %8f W", self.P_VenusE))

            mqtt_reader:updateStates()
            local oldstate = self:getState()
            local newstate = self:updateState()

            mqtt_reader:updateStates()

            -- update state, as the battery may have changed or the user could have changed something manually
            self:outputTheLog(date_string, oldstate, newstate)

            self:writeToDatabase()

            -- Here the dragons fly (aka the datastructure of the states knowk in)
            if not self:callStateHandler() then
                local error_msg = "Error: state '" .. tostring(self:getState()) .. "' not implemented yet"
                util:log(error_msg)
                print(error_msg)
            end

            -- Update Fronius
            util:log("\n-------- Total Overview:")
            date = os.date("*t")
            self:refreshCache()

            oldstate = newstate
            newstate = self:getState()
            if oldstate ~= newstate then
                newstate = self:updateState()
                self:outputTheLog(date_string, oldstate, newstate)
            end

        end

        -- Do the time controlled switching
        for _, Inverter in ipairs(self.Inverter) do
            if Inverter.time_controlled then
                local curr_hour = date.hour + date.min/60 + date.sec/3600
                if SunTime.rise_civil < curr_hour and curr_hour < SunTime.set_civil then
                    Inverter:safeStartDischarge()
                else
                    Inverter:safeStopDischarge()
                end
            end
        end

        self:serverCommands(config)

        for _, BMS in ipairs(self.BMS) do
            BMS:printValues()
        end

        util:log("\n. . . . . . . . . sleep . . . . . . . . . . . .")

        if short_sleep then
            util.sleepTime(short_sleep - (util.getCurrentTime() - _start_time))
        else
            util.sleepTime(config.sleep_time - (util.getCurrentTime() - _start_time))
        end
    end -- end of inner loop
end

-------------------------------------------------------------------------------

if #arg > 2 then
    if arg[1] and arg[1] == "-c" then
        if arg[2] then
            config.config_file_name = arg[2]
        end
    end
end

local MyBatteries = PVBattery
MyBatteries:init()

util.deleteRunningInstances("PVBattery")

os.execute("date; echo Init done")

if not Profiler then
    -- this is the outer loop, a safety-net if the inner loop is broken with `break`
    while true do
        util:cleanLogs()
        MyBatteries.BMS[1].timeOfLastFullBalancing = util.getCurrentTime() - 26*3600 -- yesterday the same time
        MyBatteries:main()
    end
else -- if Profiler
    MyBatteries:main(1)
    Profiler.stop()
    Profiler.report("test-profiler.log")
end