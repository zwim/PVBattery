
local VERSION = "V4.6.1"

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

local config = require("configuration")
local util = require("util")
local socket = require("socket")

local state = {
    fail = "fail", -- unknown state
    idle = "idle",
    idle_full = "idle_full",
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
    for _, Device in pairs(config.Device) do
        local BMS = AntBMS:new{
            host = Device.BMS,
            lastFullPeriod = config.lastFullPeriod,
            minCellDiff = config.minCellDiff,
            minPower = config.minPower,
        }
        if Device.BMS ~= nil then
            table.insert(self.BMS, BMS)
        end

        local Inverter = InverterClass:new {
            host = Device.inverter_switch,
            min_power = Device.inverter_min_power,
            time_controlled = Device.inverter_time_controlled,
            BMS = BMS,
        }
        table.insert(self.Inverter, Inverter)

        for i = 1, #Device.charger_switches do
            local Charger = ChargerClass:new{
                host = Device.charger_switches[i],
                max_power = Device.charger_max_power[i],
                BMS = BMS,
            }
            BMS.wakeup = function()
                print("Wakeup charge started")
                Charger:startCharge()
                util.sleep_time(config.sleep_time)
            end
            table.insert(self.Charger, Charger)
        end
    end
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

-- luacheck: ignore P_Grid P_VenusE date
function PVBattery:updateState(date, P_Grid, P_VenusE)
    -- This means that our battery is ahead of all others, but only twice a day

    for _, Charger in ipairs(self.Charger) do
        if Charger:getPowerState() == "on" then
            if Charger.BMS:isLowChargedOrNeedsRescue() and Charger.BMS:needsRescueCharge() then
                return self:setState(state.rescue_charge)
            else
                return self:setState(state.charge)
            end
        end
    end

    for _, Inverter in ipairs(self.Inverter) do
        local powerState = Inverter:getPowerState()
        local dischargeState = Inverter.BMS:getDischargeState()
        if not Inverter.time_controlled then
            if powerState == "on" and dischargeState == "off" then
                return self:setState(state.force_discharge)
            end
            if powerState ~= "off" and dischargeState ~= "off" then
                return self:setState(state.discharge)
            end
        end
    end

    -- Helper to ensure BMS data is available
    local function ensureBMSData(BMS)
        for _ = 1, 5 do
            if BMS:getData() then return true end
            util.sleep_time(2)
            print("Problem getting BMS data")
        end
        return BMS:getData()
    end

    for _, BMS in ipairs(self.BMS) do
        if ensureBMSData(BMS) then
            if BMS:isBatteryFull() then
                if self:getState() ~= state.idle_full then
                    return self:setState(state.idle_full)
                end
                return self:getState()
            elseif BMS:needsBalancing() then
                return self:setState(state.balance)
            elseif BMS:isLowChargedOrNeedsRescue() and BMS:needsRescueCharge() then
                return self:setState(state.rescue_charge)
            elseif BMS.v.LowestVoltage < config.bat_lowest_voltage then
                return self:setState(state.low_cell)
            elseif BMS.v.SOC <= config.bat_SOC_min then
                return self:setState(state.low_battery)
            elseif BMS.v.CellDiff > config.max_cell_diff then
                return self:setState(state.cell_diff)
            elseif self:getState() == state.cell_diff
                and BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
                return self:setState(state.cell_diff)
            end
        else
            self:setState(state.shutdown)
            self[self:getState()](self)
            return self:getState()
        end
    end

    return self:setState(state.idle)
end

function PVBattery:isSellingMoreThan(P_Grid, limit)
    limit = limit or 0
    return -P_Grid > limit
end

function PVBattery:isBuyingMoreThan(P_Grid, limit)
    limit = limit or 0
    return P_Grid > limit
end

function PVBattery:turnOffBestCharger(P_Grid, P_VenusE)
    local charger_num = 0 -- xxx P_VenusE fehlt noch TODO
    local charger_power = 0

    if P_Grid <= 0 then print("Error: req_power " .. P_Grid .. "<0") end

    for i, Charger in pairs(self.Charger) do
        if Charger:getPowerState() == "on" and
            not (Charger.BMS:isLowChargedOrNeedsRescue() and Charger.BMS:needsRescueCharge()) then
            -- process only activated chargers
            local charging_power = Charger:getPower() or math.huge
            if charging_power > P_Grid or charging_power > charger_power then
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
        self.Charger[charger_num]:clearDataAge()
        return true
    end
    return false
end

function PVBattery:turnOffBestInverter(P_Grid, P_VenusE)
    local inverter_num = 0
    local inverter_power = 0
    for i, Inverter in pairs(self.Inverter) do
        if not Inverter.time_controlled and Inverter.BMS then
            if Inverter.BMS:getDischargeState() ~= "off" and Inverter:getPowerState() ~= "off" then
                -- Inverter delivers min_power (positive), VenusE delivers power (positive)
                local max_power = Inverter:getMaxPower()
                if P_VenusE < max_power or (P_VenusE >= 0 and self:isBuyingMoreThan(P_Grid, 50)) then
                    util:log("debug xxx "..i, "P_VenusE ".. P_VenusE, "P_Grid "..P_Grid, "max_power "..max_power)
                    inverter_num = i
                    inverter_power = Inverter:getPower()
                    break
                end
            end
            local _, continue_discharge = Inverter.BMS:readyToDischarge()
            if not continue_discharge then
                util:log("got you sucker xxx")
                inverter_num = i
                inverter_power = Inverter:getPower()
                break
            end
        end
    end

    if inverter_num > 0 then
        util:log(string.format("Deactivate inverter: %s with %s",
                inverter_num, inverter_power))
        self.Inverter[inverter_num]:stopDischarge()
        self.Inverter[inverter_num]:clearDataAge()
        return true
    end
    return false
end


function PVBattery:turnOffBestChargerAndThenTurnOnBestInverter(P_Grid, P_VenusE)
    if self:turnOffBestCharger(P_Grid, P_VenusE) then -- Is there a charger to turn off?
        return false
    end

    local inverter_num = 0
    local inverter_power = 0

    for i, Inverter in pairs(self.Inverter) do
        if not Inverter.time_controlled then
            if Inverter:readyToDischarge() then
                local min_power = math.max(Inverter.min_power, Inverter:getMaxPower())
                -- Inverter delivers min_power (positive), VenusE delivers power (negative)
                -- If req_power is positive, we buy energy
                if self.VenusE:isDischargingMoreThan(P_VenusE, min_power)
                    or (min_power < P_Grid and min_power > inverter_power) then
                    if Inverter.BMS:getDischargeState() ~= "on" or Inverter:getPowerState() ~= "on" then
                        inverter_num = i
                        inverter_power = min_power
                    end
                end
            else
                Inverter:stopDischarge()
            end
        end
    end

    -- Only activate one inverter, as the current is only estimated-
    if inverter_num > 0 then
        util:log(string.format("Activate inverter: %s with %5.2f W",
                inverter_num, inverter_power))
        self.Inverter[inverter_num]:startDischarge(P_Grid)
        self.Inverter[inverter_num]:clearDataAge()
        return true
    end
    return false
end

function PVBattery:turnOffBestInverterAndThenTurnOnBestCharger(P_Grid, P_VenusE)
    if self:turnOffBestInverter(P_Grid, P_VenusE) then -- no inverter running
        return false
    end

    local charger_num = 0
    local charger_power = 0

    for i, Charger in pairs(self.Charger) do
        local max_power = Charger:getMaxPower() or 0
        if (max_power < -P_Grid and max_power > charger_power) or max_power < -P_VenusE then
            if Charger:readyToCharge() then
                if Charger:getPowerState() == "off" then
                    charger_num = i
                    charger_power = max_power
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
    return false
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.cell_diff] = function(self, P_Grid, P_VenusE, date)
    self:turnOffBestInverterAndThenTurnOnBestCharger(P_Grid, P_VenusE)

    for _, BMS in pairs(self.BMS) do
        if BMS:getData() then
            if BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
                BMS:disableDischarge()
            end
        end
    end
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.low_cell] = function(self, P_Grid, P_VenusE, date)
    self:turnOffBestInverterAndThenTurnOnBestCharger(P_Grid, P_VenusE)

    for _, Inverter in pairs(self.Inverter) do
        if Inverter.BMS:isLowChargedOrNeedsRescue() then
            Inverter:stopDischarge()
        end
    end
end

PVBattery[state.low_battery] = PVBattery[state.low_cell]

function PVBattery:setChargeOrDischarge(P_Grid, P_VenusE)
    if self:isSellingMoreThan(P_Grid, 20) or self.VenusE:isChargingMoreThan(P_VenusE, 100) then
        self:turnOffBestInverterAndThenTurnOnBestCharger(P_Grid, P_VenusE)
        return state.charge
    elseif self:isBuyingMoreThan(P_Grid, 20) or self.VenusE:isDischargingMoreThan(P_VenusE, 100) then
        self:turnOffBestChargerAndThenTurnOnBestInverter(P_Grid, P_VenusE)
        return state.discharge
    end
    return state.idle
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.idle] = function(self, P_Grid, P_VenusE, date)
    local expected_state = self:setChargeOrDischarge(P_Grid, P_VenusE)
--    if expected_state ~= state.idle then
        for _, BMS in pairs(self.BMS) do
            BMS:disableDischarge()
        end
--    end
end

PVBattery[state.idle_full] = PVBattery[state.idle]

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.charge] = function(self, P_Grid, P_VenusE, date)
    local expected_state = self:setChargeOrDischarge(P_Grid, P_VenusE)
    if expected_state == state.charge then
        for _, BMS in pairs(self.BMS) do
            if BMS:isBatteryFull() then
                for _, Charger in pairs(self.Charger) do
                    if Charger.BMS == BMS then
                       Charger:stopCharge()
                    end
                end
            end
            if BMS:needsBalancing() then
                BMS:enableDischarge()
                BMS:setAutoBalance(true)
            end
        end
    end
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.balance] = function(self, P_Grid, P_VenusE, date)
    local needs_balancing, is_full
    for _, BMS in pairs(self.BMS) do
        if BMS:needsBalancing() then
            BMS:enableDischarge()
            BMS:setAutoBalance(true)
            needs_balancing = true
        end
        if BMS:isBatteryFull() then
            is_full = true
        end
    end
    if not needs_balancing and not is_full then
        self:setChargeOrDischarge(P_Grid, P_VenusE)
    end
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.discharge] = function(self, P_Grid, P_VenusE, date)
    local expected_state = self:setChargeOrDischarge(P_Grid, P_VenusE)
    if expected_state == state.discharge then
        for _, BMS in pairs(self.BMS) do
            if BMS:isLowChargedOrNeedsRescue() then
                for _, Charger in pairs(self.Charger) do
                    if Charger.BMS == BMS then
                       Charger:stopDischarge()
                    end
                end
            end
        end
    end
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.full] = function(self, P_Grid, P_VenusE, date)
    for _, Charger in pairs(self.Charger) do
        Charger:stopCharge()
    end

    for _, BMS in pairs(self.BMS) do
        BMS:setAutoBalance(false)
        BMS:disableDischarge()
    end

    self:setState(state.idle_full)
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.rescue_charge] = function(self, P_Grid, P_VenusE, date)
    for _, Charger in pairs(self.Charger) do
        if Charger.BMS:needsRescueCharge() then
            Charger:startCharge()
        end
    end
end

-- luacheck: ignore self P_Grid P_VenusE date
PVBattery[state.shutdown] = function(self, P_Grid, P_VenusE, date)
    print("state -> shutdown")
    for _, Charger in pairs(self.Charger) do
        if Charger:getPowerState() == "on" then
            Charger:stopCharge()
        end
    end
    for _, Inverter in pairs(self.Inverter) do
        if Inverter:getPowerState() ~= "off" and Inverter.BMS:getDischargeState() ~= "off"
            and not Inverter.time_controlled then
            Inverter:stopDischarge()
        end
    end
end

PVBattery[state.force_discharge] = function(self, P_Grid, P_VenusE)
    print("state -> force_discharge")

    for _, Inverter in pairs(self.Inverter) do
        if not Inverter.time_controlled then
            local power_state = Inverter:getPowerState()
            local discharge_state = Inverter.BMS:getDischargeState()
            if power_state ~= discharge_state then
                if Inverter:getPowerState() ~= "off" then
                    Inverter:startDischarge()
                else
                    Inverter:stopDischarge()
                end
            end
        end
    end
end

function PVBattery:clearCache()
    -- Delete all cached values
    for _, BMS in pairs(self.BMS) do
        BMS:clearDataAge()
    end
    for _, Charger in pairs(self.Charger) do
        Charger:clearDataAge()
    end
    for _, Inverter in pairs(self.Inverter) do
        Inverter:clearDataAge()
    end
    Fronius:clearDataAge()
--    P1meter:clearDataAge()
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
    for _, BMS in pairs(self.BMS) do
        addThread(coroutine.create(function() return BMS:getData_coroutine() end))
    end
    for _, Inverter in pairs(self.Inverter) do
        addThread(coroutine.create(function() return Inverter:_getStatus_coroutine() end))
    end
    for _, Charger in pairs(self.Charger) do
        addThread(coroutine.create(function() return Charger:_getStatus_coroutine() end))
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
        for sock_id in pairs(socket_to_thread) do
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
        total = total + age; max_age = math.max(max_age, age)
    end
    for _, B in pairs(self.BMS)     do report("BMS "     ..B.host, B:getDataAge()) end
    for _, C in pairs(self.Charger) do report("Charger " ..C.host, C:getDataAge()) end
    for _, I in pairs(self.Inverter)do report("Inverter "..I.host, I:getDataAge()) end
    report("Fronius "..Fronius.host, Fronius:getDataAge())
--    report("P1meter "..P1meter.host, P1meter:getDataAge())
    util:log(string.format("Savings: %5f s, sequential %5f s, parallel %5f s)", total - max_age, total, max_age))
end

function PVBattery:outputTheLog(P_Grid, P_Load, P_PV, P_VenusE, date, date_string)
    local oldstate, newstate
    oldstate = self:getState()
    newstate = self:updateState(date, P_Grid, P_VenusE)

    local log_string
    log_string = string.format("%s  P_Grid=%5.0fW, P_Load=%5.0fW, P_VenusE=%5.0fW",
        date_string, P_Grid, P_Load, P_VenusE)
    log_string = log_string .. string.format(" %8s -> %8s", oldstate, newstate)

    if oldstate ~= newstate then
        print(log_string)

    end
    util:log(log_string)
    self:generateHTML(config, P_Grid, P_Load, P_PV, P_VenusE, VERSION)
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
        self:clearCache()
        self:fillCache()
        self:showCacheDataAge()

        -- Update Fronius
        util:log("\n-------- Total Overview:")
        -- Positive values mean power going into Fronius;
        -- e.g. positive P_Grid we buy energy
        --      negative P_Grid we sell energy
        local P_Grid, P_Load, P_PV, P_AC = Fronius:getGridLoadPV()

        -- Positive values mean VenusE is discharging
        -- Nagative values mean power is charging
        local P_VenusE = self.VenusE:readACPower()
        P_VenusE = P_VenusE and math.floor(P_VenusE)
        local VenusE_SOC = self.VenusE:readBatterySOC()

        local repeat_request = 5
        while (not P_Grid or not P_Load or not P_PV or not P_VenusE) and repeat_request > 0 do
            repeat_request = repeat_request - 1
            util.sleep_time(1) -- try again in 1 second
            if not P_Grid or not P_Load or not P_PV then
                util:log("Communication error: repeat request:", repeat_request)
                self:clearCache()
                self:fillCache()
                self:showCacheDataAge()
                P_Grid, P_Load, P_PV, P_AC = Fronius:getGridLoadPV()
            end
            if not P_VenusE then
                P_VenusE = self.VenusE:readACPower()
            end
        end

        -- Defautlt to 0 % or 0 W if no marstek is found.
        self.VenusE_SOC = VenusE_SOC and math.floor(VenusE_SOC) or 0
        P_VenusE = P_VenusE or 0

        -- Normally P_PV comes from panel and P_AC is less, so use the smaller one
        if P_PV and P_AC then
            P_PV = math.min(P_PV, P_AC)
        end

        if not P_Grid or not P_Load or not P_PV or not P_VenusE then
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
            util:log(string.format("Grid %8f W (%s)", P_Grid, P_Grid > 0 and "optaining" or "selling"))
            util:log(string.format("Load %8f W", P_Load))
            util:log(string.format("Roof %8f W", P_PV))
            util:log(string.format("VenusE %8f W", P_VenusE))

            -- update state, as the battery may have changed or the user could have changed something manually
            self:outputTheLog(P_Grid, P_Load, P_PV, P_VenusE, date, date_string)

            -- Here the dragons fly (aka the datastructure of the states knowk in)
            local stateHandler = self[self:getState()]
            if stateHandler then
                stateHandler(self, P_Grid, P_VenusE, date) -- execute the state
            else
                local error_msg = "Error: state '" .. tostring(self:getState()) .. "' not implemented yet"
                util:log(error_msg)
                print(error_msg)
            end

            self:clearCache()
            self:fillCache()
            self:showCacheDataAge()

            self:outputTheLog(P_Grid, P_Load, P_PV, P_VenusE, date, date_string)
        end

        -- Do the time controlled switching
        for _, Inverter in pairs(self.Inverter) do
            if Inverter.time_controlled then
                local curr_hour = date.hour + date.min/60 + date.sec/3600
                if SunTime.rise_civil < curr_hour and curr_hour < SunTime.set_civil then
                    if Inverter:getPowerState() ~= "on" then
                        Inverter:startDischarge()
                    end
                else
                    if Inverter:getPowerState() ~= "off" then
                        Inverter:stopDischarge()
                    end
                end
            end
        end

        self:serverCommands(config)

        for _, BMS in pairs(self.BMS) do
            BMS:printValues()
        end

        util:log("\n. . . . . . . . . sleep . . . . . . . . . . . .")

        if short_sleep then
            util.sleep_time(short_sleep - (util.getCurrentTime() - _start_time))
        else
            util.sleep_time(config.sleep_time - (util.getCurrentTime() - _start_time))
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