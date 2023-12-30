local AntBMS = require("antbms")
local Fronius = require("fronius")
local SunTime = require("suntime/suntime")
local ChargerClass = require("charger")
local InverterClass = require("inverter")

local config = require("configuration")
local util = require("util")

local PVBattery = {
    BMS = {},
    Charger = {},
    Inverter = {},

    -- state can be idle, lowBattery, charging, discharging
    _state = "", -- no state yet

    -- very coarse default sunrise and sunset
    sunrise = 6,
    sunset = 18,
}

-------------------- extend functions from this file
PVBattery.generateHTML = require("PVBatteryHTML")
--------------------

function PVBattery:init()
    config:read()
    util:setLog(config.log_file_name or "PVBattery.log")

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
        local BMS = AntBMS:new{host = Device.BMS}
        table.insert(self.BMS, BMS)

        local Inverter = InverterClass:new {
            host = Device.inverter_switch,
            min_power = Device.inverter_min_power,
            time_controlled = Device.inverter_time_controlled,
            BMS = BMS,
        }
        table.insert(self.Inverter, Inverter)

        for i = 1, #Device.charger_switches do
            local Charger = ChargerClass:new{
                switch_host = Device.charger_switches[i],
                max_power = Device.charger_max_power[i],
                BMS = BMS,
            }
            table.insert(self.Charger, Charger)
        end
    end
end

--- Get the current State of the whole battery cluster
-- return string
function PVBattery:getState()
    return self._state
end

--- Get or set the idle state
function PVBattery:isStateIdle(set)
    if set then
        self._state = "idle"
    end
    return self._state == "idle"
end

function PVBattery:isStateCharging(set)
    if set then
        self._state = "charging"
    end
    return self._state == "charging"
end

function PVBattery:isStateDischarging(set)
    if set then
        self._state = "discharging"
    end
    return self._state == "discharging"
end
function PVBattery:isStateLowBattery(set)
    if set then
        self._state = "lowBattery"
    end
    return self._state == "lowBattery"
end

function PVBattery:findBestCharger(req_power)
    local pos = 0
    local avail_power = 0

    for i, chg in pairs(self.Charger) do
        local max_power = chg:getMaxPower() or 0
        if max_power < req_power and max_power > avail_power then
            if chg:readyToCharge() then
                if chg:getPowerState() == "off" then
                    pos = i
                    avail_power = max_power
                end
            end
        end
    end

    return pos, avail_power
end

function PVBattery:findBestInverter(req_power)
    local pos = 0
    local avail_power = 0

    for i, inv in pairs(self.Inverter) do
        local min_power = inv.min_power or math.huge
        if min_power < req_power and min_power > avail_power then
            if inv:readyToDischarge() then
                if inv:getPowerState() ~= "on" then
                    pos = i
                    avail_power = min_power
                end
            end
        end
    end

    return pos, avail_power
end

function PVBattery:isCharging()
    for _, charger in pairs(self.Charger) do
        if charger:getPowerState() == "on" then
            return true
        end
    end
    return false
end

function PVBattery:isDischarging()
    for _, inverter in pairs(self.Inverter) do
        if not inverter.time_controlled and inverter:getPowerState() == "on" then
            return true
        end
    end
    return false
end

function PVBattery:main()
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

    self:isStateIdle(true)

    while true do
        local skip_loop = false
        local short_sleep = nil -- a number here will shorten the sleep time
        local _start_time = util.getCurrentTime()

        local charger_num
        local charger_power
        local inverter_num
        local inverter_power

        -- if config has changed, reload it
        if config:read() ~= nil then
            short_sleep = 1
        end

        last_date = date
        date = os.date("*t")
        util:log("\n#############################################")

        local date_string = string.format("%d/%d/%d-%02d:%02d:%02d",
        last_date.year, last_date.month, last_date.day,
        last_date.hour, last_date.min, last_date.sec)

        util:log(date_string)
--        print(date_string)

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

        -- Delete all cached values
        for _, BMS in pairs(self.BMS) do
            BMS:clearDataAge()
        end

        for _, Charger in pairs(self.Charger) do
            Charger.Switch:clearDataAge()
        end

        for _, Inverter in pairs(self.Inverter) do
            Inverter.Switch:clearDataAge()
        end

        -- Update Fronius
        util:log("\n-------- Total Overview:")
        Fronius:getPowerFlowRealtimeData()
        local P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        local repeat_request = math.min(20, config.sleep_time - 5)
        while (not P_Grid or not P_Load or not P_PV) and repeat_request > 0 do
            util:log("Communication error: repeat request:", repeat_request)
            repeat_request = repeat_request - 1
            util.sleep_time(1) -- try again in 1 second
            P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        end

        if not P_Grid then
            short_sleep = 1
            skip_loop = true
        end

        util:log(string.format("Grid %8.2f W", P_Grid))
        util:log(string.format("Load %8.2f W", P_Load))
        util:log(string.format("Roof %8.2f W", P_PV))

        if not skip_loop then
            -- Do the test again, as the need of a rescue charge is checked here, too.

            -- Check which battery is on low power; stop discharge for it.
            for _,inv in pairs(self.Inverter) do
                if inv.time_controlled then
                    local curr_hour = date.hour + date.min/60 + date.sec/3600
                    if curr_hour > SunTime.times[inv.time_controlled.off] then
                        inv:stopDischarge()
                    elseif curr_hour > SunTime.times[inv.time_controlled.on] then
                        inv:startDischarge(10) -- just any power > 0
                    else
                        inv:stopDischarge()
                    end
                else
                    if inv.BMS:isLowChargedOrNeedsRescue() then
                        inv:stopDischarge()
                        self:isStateLowBattery(true)
                    end
                end
            end

            -- If there is at least one low power battery; check if a battery needs a rescue charge
            if self:isStateLowBattery() then
                for _,charger in pairs(self.Charger) do
                    if charger.BMS:needsRescueCharge() then
                        charger:startCharge()
                        skip_loop = true
                    end
                    if charger.BMS:recoveredFromRescueCharge() then
                        -- We come here if state == lowBattery and recoverFromRescueCharge()
                        charger:stopCharge()
                        self:isStateIdle(true)
                    end
                end
            end

            -- Check which battery need balancing
            for _,bms in pairs(self.BMS) do
                bms:evaluateParameters(true)
                if next(bms.v) then -- check for non empty array
                    if bms.v.CellDiff >= config.max_cell_diff
                            or bms.v.HighestVoltage >= config.bat_highest_voltage
                            or bms.v.SOC >= config.bat_SOC_max then
                        bms:enableDischarge()
                        util.sleep_time(1)
                        bms:setAutoBalance(true)
                    end
                end
            end

--[[
            -- Check which battery need balancing (on the high side only)
            for _,bms in pairs(self.BMS) do
                bms:evaluateParameters(true)
                if bms.v.Current and bms.v.Current < 0.99 and bms.v.SOC > 80 then
                    if bms.v.HighestVoltage >= config.bat_highest_voltage
                            or bms.v.CellDiff >= config.max_cell_diff
                            or bms.v.SOC >= config.bat_SOC_max then
                        bms:setAutoBalance(true)
                    end
                end
            end
--]]

        end

        if not skip_loop then
            if P_Grid > 0 and not self:isStateLowBattery() then
                if self:isCharging() then
                    short_sleep = 5
                    for _, charger in pairs(self.Charger) do
                        charger:stopCharge()
                        self:isStateIdle(true)
                    end
                else
                    inverter_num, inverter_power = self:findBestInverter(P_Grid)
                    if inverter_num > 0 then
--                        print("xxx activate additional inverter:", inverter_num, inverter_power)
                        util:log(string.format("Activate inverter: %s with %5.2f W",
                                inverter_num, inverter_power))
                        self.Inverter[inverter_num]:startDischarge(P_Grid)
                        short_sleep = 10  -- inverters are slower than chargers
                        self:isStateDischarging(true)
                    end
                end
            elseif P_Grid < 0 then
                if self:isDischarging() then
                    short_sleep = 5
                    for _, inv in pairs(self.Inverter) do
                        if not inv.time_controlled then
                            inv:stopDischarge()
                            self:isStateIdle(true)
                        end
                    end
                else
                    charger_num, charger_power = self:findBestCharger(-P_Grid)
                    if charger_num > 0 then
--                        print("xxx activate additional charger:", charger_num, charger_power)
                        util:log(string.format("Activate charger: %s with %5.2f W",
                                charger_num, charger_power))
                        self.Charger[charger_num]:startCharge()
                        short_sleep = 10  -- inverters are slower than chargers
                        self:isStateCharging(true)
                    end
                end
            else
                -- disable discharge MOS here ???
            end
        end -- if skip__loop

        for _, bms in pairs(self.BMS) do
            bms:printValues()
        end

        util:log("New state: " .. self:getState())
        util:log("\n. . . . . . . . . sleep . . . . . . . . . . . .")
        self:generateHTML(config, P_Grid, P_Load, P_PV)

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

-- this is the outer loop, a safety-net if the inner loop is broken with `break`
while true do
    util:cleanLogs()
    MyBatteries:main()
end
