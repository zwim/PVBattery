
local VERSION = "V4.2.2"

local Profiler = nil
-- profiler from https://github.com/charlesmallah/lua-profiler
--local Profiler = require("suntime/profiler")
if Profiler then
    Profiler.start()
end

local AntBMS = require("antbms")
local Fronius = require("fronius")
local SunTime = require("suntime/suntime")
local ChargerClass = require("charger")
local InverterClass = require("inverter")

local config = require("configuration")
local util = require("util")
local socket = require("socket")

local state = {
    fail = "fail", -- unknown state
    idle = "idle",
    charge = "charge",
    balance = "balance", -- during charge or on the high side
    full = "full",
    discharge = "discharge",
    low_battery = "low_battery",
    low_cell = "low_cell",
    cell_diff = "cell_diff",
    rescue_charge = "rescue_charge",
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
    local h, m, s
    h, m, s = util.hourToTime(SunTime.rise)
    self.sunrise = string.format("%02d:%02d:%02d", h, m, s)
    util:log("Sun rise at " .. self.sunrise)
    h, m, s = util.hourToTime(SunTime.set)
    self.sunset = string.format("%02d:%02d:%02d", h, m, s)
    util:log("Sun set at " .. self.sunset)

    -- IMPORTANT: Our authorative power meter, which shows if we produce or consume energy
    Fronius = Fronius:new{host = config.FRONIUS_ADR}

    -- Init all device configurations
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
        self:setState(state.fail)
    end
end

-- might be neccesary, if the user switches something manually
function PVBattery:updateState()
    for _, Charger in pairs(self.Charger) do
        if Charger:getPowerState() == "on" then
            if Charger.BMS:isLowChargedOrNeedsRescue() and Charger.BMS:needsRescueCharge() then
                self:setState(state.rescue_charge)
            else
                self:setState(state.charge)
            end
            return self:getState()
        end
    end

    for _, Inverter in pairs(self.Inverter) do
        if Inverter:getPowerState() == "on" and not Inverter.time_controlled then
            self:setState(state.discharge)
            return self:getState()
        end
    end

    for _, BMS in pairs(self.BMS) do
        if BMS:getData() then
            if BMS:isBatteryFull() then
                self:setState(state.full)
                return self:getState()
            elseif BMS:needsBalancing() then
                self:setState(state.balance)
                return self:getState()
            elseif BMS:isLowChargedOrNeedsRescue() and BMS:needsRescueCharge() then
                self:setState(state.rescue_charge)
                return self:getState()
            elseif BMS.v.LowestVoltage < config.bat_lowest_voltage then
                self:setState(state.low_cell)
                return self:getState()
            elseif BMS.v.SOC <= config.bat_SOC_min then
                self:setState(state.low_battery)
                return self:getState()
            elseif BMS.v.CellDiff > config.max_cell_diff then
                self:setState(state.cell_diff)
                return self:getState()
            elseif self:getState() == state.cell_diff
                and BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
                self:setState(state.cell_diff)
                return self:getState()
            end
        else -- can not read BMS -> shutdown
            self:setState(state.shutdown)
            self[self:getState()](self)
            return self:getState()
        end
    end

    self:setState(state.idle)
    return self:getState()
end

-- find an activated charger which is charging with more than req_power
-- or find the activated charger with the highest power.
function PVBattery:findBestChargerToTurnOff(req_power)
    local pos = 0
    local avail_power = 0

    if req_power <= 0 then print("Error: req_power " .. req_power .. "<0") end

    for i, Charger in pairs(self.Charger) do
        if Charger:getPowerState() == "on" and
            not (Charger.BMS:isLowChargedOrNeedsRescue() and Charger.BMS:needsRescueCharge()) then
            -- process only activated chargers
            local charging_power = Charger:getPower() or math.huge
            if charging_power > req_power or charging_power > avail_power then
                -- either one charging power that is larger than requested power (✓)
                -- or the largest charging power (✓)
                pos = i
                avail_power = charging_power
            end
        end
    end

    return pos, avail_power
end

function PVBattery:turnOffBestCharger(P_Grid)
    -- allow a small power buy instead of a bigger power sell.
    local charger_num, charger_power = self:findBestChargerToTurnOff(P_Grid)
    -- Only activate one inverter, as the current is only estimated-
    if charger_num > 0 then
        util:log(string.format("Deactivated Charger: %s with %s W",
                charger_num, charger_power))
        self.Charger[charger_num]:stopCharge(P_Grid)
        self.Charger[charger_num]:clearDataAge()
        return true
    end
end

function PVBattery:findBestChargerToTurnOn(req_power)
    local pos = 0
    local avail_power = 0

    if req_power > 0 then print("Error 3") end
    req_power = -req_power -- as we compare to positive values in max_power

    for i, Charger in pairs(self.Charger) do
        local max_power = Charger:getMaxPower() or 0
        if max_power < req_power and max_power > avail_power then
            if Charger:readyToCharge() then
                if Charger:getPowerState() == "off" then
                    pos = i
                    avail_power = max_power
                end
            end
        end
    end

    return pos, avail_power
end

function PVBattery:turnOnBestCharger(P_Grid)
    local charger_num, charger_power = self:findBestChargerToTurnOn(P_Grid)
    -- Activate one charger, as the current is only estimated.
    if charger_num > 0 then
        util:log(string.format("Activate charger: %s with %5.2f W",
                charger_num, charger_power))
        self.Charger[charger_num]:startCharge()
        return true
    end
end

-- ToDo: If we have more than one inverter on, find the best with Inverter:getPower
function PVBattery:findBestInverterToTurnOff(req_power)
    for i, Inverter in pairs(self.Inverter) do
        if not Inverter.time_controlled and Inverter.BMS then
            if Inverter.BMS:getDischargeState() ~= "off" and Inverter:getPowerState() ~= "off" then
                if req_power < 0 then
                    return i, Inverter:getPower()
                end
            end
            local start_discharge, continue_discharge = Inverter.BMS:readyToDischarge()
            if not continue_discharge then
                return i, Inverter:getPower()
            end
        end
    end
    return 0, 0
end

function PVBattery:turnOffBestInverter(req_power)
    local inverter_num, power = self:findBestInverterToTurnOff(req_power)
    if inverter_num > 0 then
        util:log(string.format("Deactivate inverter: %s with %s",
                inverter_num, power))
        self.Inverter[inverter_num]:stopDischarge()
        self.Inverter[inverter_num]:clearDataAge()
        return true
    end
end

function PVBattery:findBestInverterToTurnOn(req_power)
    local pos = 0
    local avail_power = 0

    if req_power < 0 then
        req_power = 0
    end

    for i, Inverter in pairs(self.Inverter) do
        if not Inverter.time_controlled then
            local min_power = math.max(Inverter.min_power, Inverter:getMaxPower())
            if Inverter:readyToDischarge() then
                if min_power < req_power and min_power > avail_power then
                    if Inverter.BMS:getDischargeState() ~= "on" or Inverter:getPowerState() ~= "on" then
                        pos = i
                        avail_power = min_power
                    end
                end
            else
                Inverter:stopDischarge()
            end
        end
    end

    return pos, avail_power
end

function PVBattery:turnOnBestInverter(req_power)
    -- allow a small power buy instead of a bigger power sell.
    local inverter_num, inverter_power = self:findBestInverterToTurnOn(req_power)
    -- Only activate one inverter, as the current is only estimated-
    if inverter_num > 0 then
        util:log(string.format("Activate inverter: %s with %5.2f W",
                inverter_num, inverter_power))
        self.Inverter[inverter_num]:startDischarge(req_power)
        self.Inverter[inverter_num]:clearDataAge()
        return true
    end
end

function PVBattery:chargeThreshold(date)
    local curr_hour = date.hour + date.min/60 + date.sec/3600
    if SunTime.rise_civil < curr_hour and curr_hour < SunTime.set_civil then
        return -10
    else
        return 0
    end
end

PVBattery[state.cell_diff] = function(self, P_Grid, date)
    if P_Grid < self:chargeThreshold(date) then -- sell more than threhold energy
        self:turnOnBestCharger(P_Grid)
    else
        for _, BMS in pairs(self.BMS) do
            if BMS:getData() then
                if BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
                    BMS:disableDischarge()
                end
            end
        end
    end
end

PVBattery[state.low_cell] = function(self, P_Grid, date)
    if P_Grid < self:chargeThreshold(date) then -- sell more than threhold energy
        self:turnOnBestCharger(P_Grid)
    else
        for _, Inverter in pairs(self.Inverter) do
            if Inverter.BMS:isLowChargedOrNeedsRescue() then
                Inverter:stopDischarge()
            end
        end
    end
end

PVBattery[state.low_battery] = PVBattery[state.low_cell]

PVBattery[state.charge] = function(self, P_Grid, date)
    for _, Inverter in pairs(self.Inverter) do
        if not Inverter.time_controlled and Inverter:getPowerState() ~= "off" then
            Inverter:stopDischarge()
        end
    end
    if P_Grid < self:chargeThreshold(date) then -- sell more than threhold energy
        self:turnOnBestCharger(P_Grid)
    elseif P_Grid > 0 then -- buying energy
        if not self:turnOffBestCharger(P_Grid) then
            print("Huston we have a problem")
        end
    end
end

PVBattery[state.discharge] = function(self, P_Grid)
    for _, Charger in pairs(self.Charger) do
        if Charger:getPowerState() ~= "off" then
            Charger:stopCharge()
        end
    end
    local inverter_turned_on
    if P_Grid > 0 then -- sell more than threshold
        inverter_turned_on = self:turnOnBestInverter(P_Grid)
    end

    if P_Grid < 0 or not inverter_turned_on then
        self:turnOffBestInverter(P_Grid)
    end
end

PVBattery[state.balance] = function(self, P_Grid, date)
    -- this is almost same as in idle, but no disableDischarge here
    if P_Grid < self:chargeThreshold(date) then -- sell more than threshold energy
        if not self:turnOffBestInverter(P_Grid) then -- no inverter running
            self:turnOnBestCharger(P_Grid)
        end
    elseif P_Grid > 0 then -- buying energy
        if not self:turnOffBestCharger(P_Grid) then -- no charger on
            self:turnOnBestInverter(P_Grid)
        end
    end

    for _, BMS in pairs(self.BMS) do
        if BMS:needsBalancing() then
            BMS:enableDischarge()
            BMS:setAutoBalance(true)
        end
    end
end

PVBattery[state.full] = function(self, P_Grid, date)
    if P_Grid < self:chargeThreshold(date) then -- sell more than threshold energy
        if not self:turnOffBestInverter(P_Grid) then -- no inverter running
            self:turnOnBestCharger(P_Grid)
        end
    elseif P_Grid > 0 then
        for _, BMS in pairs(self.BMS) do
            if BMS:isBatteryFull() then
                BMS:disableDischarge()
            end
        end
    end
end

PVBattery[state.rescue_charge] = function(self)
    for _, Charger in pairs(self.Charger) do
        if Charger.BMS:needsRescueCharge() then
            Charger:startCharge()
        end
    end
end

PVBattery[state.idle] = function(self, P_Grid, date)
    if P_Grid < self:chargeThreshold(date) then -- sell more than threshold energy
        if not self:turnOffBestInverter(P_Grid) then -- no inverter running
            self:turnOnBestCharger(P_Grid)
        end
    elseif P_Grid > 0 then -- buying energy
        if not self:turnOffBestCharger(P_Grid) then -- no charger on
            self:turnOnBestInverter(P_Grid)
        end
    else
        for _, BMS in pairs(self.BMS) do
            BMS:disableDischarge()
        end
    end
end

PVBattery[state.shutdown] = function(self)
    print("state -> shutdown")
    for _, Charger in pairs(self.Charger) do
        if Charger:getPowerState() == "on" then
            Charger:stopCharge()
        end
    end
    for _, Inverter in pairs(self.Inverter) do
        if Inverter:getPowerState() == "on" and not Inverter.time_controlled then
            Inverter:stopDischarge()
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
    local threads = {}    -- list of all live threads

    for _, BMS in pairs(self.BMS) do
        local co = coroutine.create(function()
            BMS:getData_coroutine()
        end)
        table.insert(threads, co)
    end
    for _, Inverter in pairs(self.Inverter) do
        local co = coroutine.create(function()
            Inverter:_getStatus_coroutine()
        end)
        table.insert(threads, co)
    end
    for _, Charger in pairs(self.Charger) do
        local co = coroutine.create(function()
            Charger:_getStatus_coroutine()
        end)
        table.insert(threads, co)
    end

    local co = coroutine.create(function()
        Fronius:getPowerFlowRealtimeData_coroutine()
    end)
    table.insert(threads, co)

    while true do
        local n = #threads
        if n == 0 then
            break
        end   -- no more threads to run
        local connections = {}
        for i=1,n do
            local status, res = coroutine.resume(threads[i])
            if not res then    -- thread finished its task?
                table.remove(threads, i)
                break
            else    -- timeout
                table.insert(connections, res)
            end
        end
        if #connections == n then
            socket.select(connections)
        end
    end
end

function PVBattery:getCacheDataAge(print_all_values)
    local output = print
    if not print_all_values then
        output = function() end
    end

    local total_fetch_time = 0
    local current_fetch_time = 0
    for _, BMS in pairs(self.BMS) do
        output(string.format("BMS %s, %2f", BMS.host, BMS:getDataAge()))
        total_fetch_time = total_fetch_time + BMS:getDataAge()
        current_fetch_time = math.max(current_fetch_time, BMS:getDataAge())
    end
    for _, Charger in pairs(self.Charger) do
        output(string.format("Charger %s %2f", Charger.switch_host, Charger:getDataAge()))
        total_fetch_time = total_fetch_time + Charger:getDataAge()
        current_fetch_time = math.max(current_fetch_time, Charger:getDataAge())
    end
    for _, Inverter in pairs(self.Inverter) do
        output(string.format("Inverter %s %2f", Inverter.host, Inverter:getDataAge()))
        total_fetch_time = total_fetch_time + Inverter:getDataAge()
        current_fetch_time = math.max(current_fetch_time, Inverter:getDataAge())
    end

    output(string.format("Fronius %s %2f", Fronius.host, Fronius:getDataAge()))
    total_fetch_time = total_fetch_time + Fronius:getDataAge()
    current_fetch_time = math.max(current_fetch_time, Fronius:getDataAge())

    util:log(string.format("Savings: %2f s, sequential %2f s, parallel %2f s)",
            total_fetch_time - current_fetch_time,
            total_fetch_time,
            current_fetch_time))
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
        self:getCacheDataAge()

        -- Update Fronius
        util:log("\n-------- Total Overview:")
        local xxx = util.getCurrentTime()
        local P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        local repeat_request = math.min(20, config.sleep_time - 5)
        while (not P_Grid or not P_Load or not P_PV) and repeat_request > 0 do
            util:log("Communication error: repeat request:", repeat_request)
            repeat_request = repeat_request - 1
            util.sleep_time(1) -- try again in 1 second
            P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        end

        if not P_Grid or not P_Load or not P_PV then
            short_sleep = 4
            skip_loop = true
            rescue_stop = rescue_stop - 1
            if rescue_stop < 0 then
                self[state.shutdown](self)
            end
        else
            rescue_stop = math.floor(60/4) + 1
        end

        local oldstate

        if not skip_loop then
            util:log(string.format("Grid %8.2f W (%s)", P_Grid, P_Grid > 0 and "optaining" or "selling"))
            util:log(string.format("Load %8.2f W", P_Load))
            util:log(string.format("Roof %8.2f W", P_PV))

            -- update state, as the battery may have changed or the user could have changed something manually
            oldstate = self:getState()
            if oldstate ~= self:updateState() then
                local f = io.popen("date", "r")
                print(f:read(), "State: ", oldstate, "->", self:getState(), "P_Grid", P_Grid, "P_Load", P_Load)
                f:close()
                -- save the new state to oldstate for reference
            end

            util:log("State: ", oldstate, "->", self:getState())

            if self[self:getState()] then
                self[self:getState()](self, P_Grid, date) -- execute the state
            else
                local error_msg = "Error: state '"..tostring(self:getState()).."' not implemented yet"
                util:log(error_msg)
                print(error_msg)
            end

            oldstate = self:getState()
            self:clearCache()
            self:fillCache()
            self:getCacheDataAge()
            if oldstate ~= self:updateState() then
                local f = io.popen("date", "r")
                print(f:read(), "State: ", oldstate, "->", self:getState(), "P_Grid", P_Grid, "P_Load", P_Load)
                f:close()
            end

            self:generateHTML(config, P_Grid, P_Load, P_PV, VERSION)
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

os.execute("date; echo Init done")

if not Profiler then
    -- this is the outer loop, a safety-net if the inner loop is broken with `break`
    while true do
        util:cleanLogs()
        MyBatteries:main()
    end
else -- if Profiler
    MyBatteries:main(1)
    Profiler.stop()
    Profiler.report("test-profiler.log")
end