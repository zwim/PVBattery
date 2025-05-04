
local Profiler = nil
--[[
-- profiler from https://github.com/charlesmallah/lua-profiler
local Profiler = require("suntime/profiler")
if Profiler then
    Profiler.start()
end
]]

local CHARGER_IP = "192.168.0.50"

local Fronius = require("fronius")
local SunTime = require("suntime/suntime")
local ChargerClass = require("charger")

local config = require("configuration")
local util = require("util")

local MopedCharger = {
    Charger = nil,

    -- state can be idle, mid_charge, full_charge
    _state = "", -- no state yet
    _goal = "", -- see state

    -- very coarse default sunrise and sunset
    sunrise = 6,
    sunset = 18,

    charger_max_power = 0,
    charger_mid_percent = 1900/2013,
    charger_full_percent = 30/2013,
}

function MopedCharger:init()
    config.config_file_name = "moped-config.lua"
    config.log_file_name = "/var/log/MopedCharger.log"

    util:setLog(config.log_file_name or "MopedCharger.log")

    util:log("\n#############################################")
    util:log("Moped charger started.")
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

    self.Charger = ChargerClass:new{
        host = CHARGER_IP,
    }

end

function MopedCharger:getState() return self._state end
function MopedCharger:getGoal() return self._goal end

--- Get or set the state
function MopedCharger:isState(state, set)
    if set then
        self._state = state
    end
    return self._state == state
end

--- Get or set the goal
function MopedCharger:isGoal(goal, set)
    if set then
        self._goal = goal
    end
    return self._goal == goal
end

function MopedCharger:turnOff()
    self.Charger:stopCharge()
    self:isGoal("idle", true)
end

function MopedCharger:isCharging()
    return self.Charger:getPowerState() == "on"
end

function MopedCharger:main(profiling_runs)
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

    self:isState("idle", true)
    self:isGoal("idle", true)

    local curr_power = 0
    local old_power
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
                skip_loop = true
            end
        end

        last_date = date
        date = os.date("*t")
        util:log("\n#############################################")

        self.Charger:clearDataAge()

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

        -- Update Fronius
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
            self:isState(self.Charger:getPowerState(), true)
            if not self:getState("on") and not self:GetState("off") then -- try onece again
                self:isState(self.Charger:getPowerState(), true)
            end

            skip_loop = not self:getState("on") and not self:GetState("off")
        end

        if not skip_loop then
            old_power = curr_power
            curr_power = self.Charger:getPower()
            skip_loop = not curr_power or (curr_power ~= curr_power) -- ether nil or nan
            skip_loop = skip_loop or (curr_power > old_power) -- starting charge
            if curr_power > old_power then
                self.charger_max_power = curr_power or 0
            end
        end

        print("'skip_loop?"..tostring(skip_loop).."'", self:getGoal(), self:getState(), P_Grid, curr_power, self.charger_max_power)

        if not skip_loop then
            if self:isGoal("idle") and curr_power > 0 then
                -- this will happen if the user turns charging on manually
                self:isGoal("mid_charge", true)
            elseif self:isGoal("mid_charge") then
                if self:isState("on") then
                    if P_Grid > 0 then -- we don't have enough power from PV
                        self.Charger:stopCharge()
                    elseif curr_power < self.charger_max_power * self.charger_mid_percent then
                        self:turnOff()
                    end
                else
                    if -P_Grid > self.charger_max_power * 1.05 then -- if we have enough power from PV
                        self.Charger:startCharge(15) -- charge for 15s to get a stable charge current
                    end
                end
            elseif self:isGoal("full_charge") then
                if self:isState("on") then
                    if P_Grid > 0 then -- we don't have enough power from PV
                        self.Charger:stopCharge()
                    elseif curr_power < self.charger_max_power * self.charger_full_percent then
                        self:turnOff()
                    end
                else
                    if -P_Grid > self.charger_max_power * 1.05 then -- if we have enough power from PV
                        self.Charger:startCharge(15) -- charge for 15s to get a stable charge current
                    end
                end
            else -- wrong goal
                self:turnOff()
            end
        end

        if skip_loop then
            short_sleep = math.min(short_sleep or 1, 1)
        end

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

local MyCharger = MopedCharger

MyCharger:init()

if not Profiler then
    -- this is the outer loop, a safety-net if the inner loop is broken with `break`
    while true do
        util:cleanLogs()
        MyCharger:main()
    end
else -- if Profiler
    MyCharger:main(1)
    Profiler.stop()
    Profiler.report("test-profiler.log")
end