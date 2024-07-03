
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
PVBattery.serverCommands = require("servercommands")
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
        local BMS = AntBMS:new{
			host = Device.BMS,
			lastFullPeriod = config.lastFullPeriod,
			minCellDiff = config.minCellDiff,
			minPower = config.minPower,
		}
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
            BMS.wakeup = function()
                Charger:startCharge()
            end
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

-- find an activated charger which is charging with more than req_power
-- or find the activated charger with the highest power.
function PVBattery:findBestChargerToTurnOff(req_power)
    local pos = 0
    local avail_power = 0

    if req_power <= 0 then print("Error 1") end

    for i, Charger in pairs(self.Charger) do
        if Charger:getPowerState() == "on" then
            -- process only activated chargers
            local charging_power = Charger:getCurrentPower() or math.huge
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

function PVBattery:findBestChargerToTurnOn(req_power)
    local pos = 0
    local avail_power = 0

    if req_power <= 0 then print("Error 2") end

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

function PVBattery:findBestInverter(req_power)
    local pos = 0
    local avail_power = 0

    if req_power <= 0 then
		req_power = 0
	end

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

function PVBattery:chargeThreshold(date)
	local curr_hour = date.hour + date.min/60 + date.sec/3600
	if SunTime.rise_civil < curr_hour and curr_hour < SunTime.set_civil then
		return -30
	else
		return 0
	end
end

function PVBattery:isDischarging()
    for _, inverter in pairs(self.Inverter) do
        if not inverter.time_controlled and inverter:getPowerState() == "on" then
            return true
        end
    end
    return false
end

function PVBattery:main(profiling_runs)
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

    self:isStateIdle(true)

    while type(profiling_runs) ~= "number" or profiling_runs > 0 do
        if type(profiling_runs) == "number" then
            profiling_runs = profiling_runs - 1
        end
        local skip_loop = false
        local short_sleep = nil -- a number here will shorten the sleep time
        local _start_time = util.getCurrentTime()

        local charger_num
        local charger_power
        local inverter_num
        local inverter_power

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

        if not P_Grid or not P_Load or not P_PV then
            short_sleep = 1
            skip_loop = true
        else
			util:log(string.format("Grid %8.2f W", P_Grid))
			util:log(string.format("Load %8.2f W", P_Load))
			util:log(string.format("Roof %8.2f W", P_PV))
		end

        if not skip_loop then
            -- Do the test again, as the need of a rescue charge is checked here, too.

            -- Check which battery is on low power; stop discharge for it.
            for _, Inverter in pairs(self.Inverter) do
                if Inverter.time_controlled then
                    local curr_hour = date.hour + date.min/60 + date.sec/3600
                    if curr_hour > SunTime.times[Inverter.time_controlled.off] then
                        Inverter:stopDischarge()
                    elseif curr_hour > SunTime.times[Inverter.time_controlled.on] then
                        Inverter:startDischarge() -- discharge with minimal power
                    else
                        Inverter:stopDischarge()
                    end
                else
                    if Inverter.BMS:isLowChargedOrNeedsRescue() then
                        Inverter:stopDischarge()
                        self:isStateLowBattery(true)
                    end
                end
            end

            -- If there is at least one low power battery; check if a battery needs a rescue charge
            if self:isStateLowBattery() then
                for _, Charger in pairs(self.Charger) do
                    if Charger.BMS:needsRescueCharge() then
                        Charger:startCharge()
                        skip_loop = true
                    end
                    if Charger:getPowerState() == "on"
                        and Charger.BMS:recoveredFromRescueCharge() then
                        -- We come here if state == lowBattery and recoverFromRescueCharge()
                        Charger:stopCharge()
                        self:isStateIdle(true)
                    end
                end
            end

            -- Check which battery need balancing or is full
            for _, BMS in pairs(self.BMS) do
                if BMS:needsBalancing() then
                    BMS:enableDischarge()
                    BMS:setAutoBalance(true)
				elseif BMS:isBatteryFull() then
--                    BMS:disableDischarge()
                    BMS:setAutoBalance(true)
                end
            end

        end

        if not skip_loop then
            if P_Grid > self:chargeThreshold(date) and not self:isStateLowBattery() then
				-- charge
                if self:isCharging() then
                    short_sleep = 0.1
                    charger_num, charger_power = self:findBestChargerToTurnOff(P_Grid)
                    -- Only activate one charger, as the current is only estimated.
                    if charger_num > 0 then
                        print("off", charger_num)
                        self.Charger[charger_num]:stopCharge(charger_power)
                        self.Charger[charger_num]:clearDataAge()
                    end
                    self:isStateIdle(self:isCharging())
                else
                    inverter_num, inverter_power = self:findBestInverter(P_Grid)
                    -- Only activate one inverter, as the current is only estimated-
                    if inverter_num > 0 then
                        util:log(string.format("Activate inverter: %s with %5.2f W",
                                inverter_num, inverter_power))
                        self.Inverter[inverter_num]:startDischarge(P_Grid)
                        short_sleep = 10  -- inverters are slower than chargers
                        self:isStateDischarging(true)
                    end
                end
            elseif P_Grid < self:chargeThreshold(date) then
                -- allow a small power buy instead of a bigger power sell.
                if self:isDischarging() then
                    short_sleep = 1
                    for _, inv in pairs(self.Inverter) do
                        if not inv.time_controlled then
                            inv:stopDischarge()
                            self:isStateIdle(true)
                        end
                    end
                else
                    charger_num, charger_power = self:findBestChargerToTurnOn(math.max(-P_Grid, 10))
                    -- Only activate one charger, as the current is only estimated.
                    if charger_num > 0 then
                        util:log(string.format("Activate charger: %s with %5.2f W",
                                charger_num, charger_power))
                        self.Charger[charger_num]:startCharge()
                        short_sleep = 5  -- inverters are slower than chargers
                        self:isStateCharging(true)
                    end
                end
            else
                -- disable discharge MOS here ???
            end
        end -- if skip_loop

        for _, BMS in pairs(self.BMS) do
            BMS:printValues()
        end

        self:serverCommands(config)

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