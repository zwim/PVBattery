
--local Fronius = require("fronius")
local P1meter = require("p1meter")
local Marstek = require("marstek")

local SunTime = require("suntime/suntime")
local ChargerClass = require("charger")

local config = require("configuration")
local mqtt_reader = require("mqtt_reader")
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
    config:read()

    -- config.compressor = "bzip2 -6"
    config.compressor = "zstd -8 --rm -T3"

    util:setLog(config.log_file_name or "MopedCharger.log")

    util:log("\n#############################################")
    util:log("Moped charger started.")
    util:log("#############################################")

    -- Uhhhohhh we need correct ephemerides ;-)
    local position = config.position
    SunTime:setPosition(position.name, position.latitude, position.longitude,
        position.timezone, position.height, true)

    SunTime:setDate()
    SunTime:calculateTimes()
    local h, m, s
    h, m, s = util.hourToTime(SunTime.rise)
    self.sunrise = string.format("%02d:%02d:%02d", h, m, s)
    util:log("Sun rise at " .. self.sunrise)
    h, m, s = util.hourToTime(SunTime.set)
    self.sunset = string.format("%02d:%02d:%02d", h, m, s)
    util:log("Sun set at " .. self.sunset)

    mqtt_reader:init(config.mqtt_broker_uri, config.mqtt_client_id)

    -- IMPORTANT: Our authorative power meter, which shows if we produce or consume energy
--    Fronius = Fronius:new{host = config.FRONIUS_ADR}
    self.P1meter = P1meter:new{host = "HW-p1meter.lan"}
    self.VenusE = Marstek:new({ip = "192.168.0.208", port=502, slaveId = 1})

    self.Charger = ChargerClass:new{
        host = config.charger,
    }
    mqtt_reader:subscribe(self.Charger.host, 0)
    mqtt_reader:askHost(self.Charger.host)
    mqtt_reader:updateStates()
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
--        Fronius:getPowerFlowRealtimeData()
--        local P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()

        -- Positive values mean power going into Fronius;
        -- e.g. positive P_Grid we buy energy
        --      negative P_Grid we sell energy
        local P_Grid = self.P1meter:getCurrentPower()
        -- Positive values mean power is going into the VenusE
        -- Negative values mean VenusE is discharging
        local P_VenusE = self.VenusE:readACPower()

        mqtt_reader:updateStates()
        local power = self.Charger:getPower()
        if power ~= 0 and power ~= power then
            print("xxx", power)
        end

        local repeat_request = math.min(20, config.sleep_time - 5)
        while (not P_Grid or not P_VenusE) and repeat_request > 0 do
            util:log("Communication error: repeat request:", repeat_request)
            repeat_request = repeat_request - 1
            util.sleepTime(1) -- try again in 1 second
--            P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
            if not P_Grid then
                P_Grid = P1meter:getCurrentPower()
            end
            if not P_VenusE then
                P_VenusE = self.VenusE:readACPower()
            end
        end

        if not P_Grid or not P_VenusE then
            short_sleep = 1
            skip_loop = true
        else
            util:log(string.format("Grid %8.2f W, VenusE %8.2f W", P_Grid, P_VenusE))
        end

        if not skip_loop then
            self:isState(self.Charger:getPowerState(), true)
            if not self:getState("on") and not self:getState("off") then -- try once again
                self:isState(self.Charger:getPowerState(), true)
            end

            skip_loop = not self:getState("on") and not self:getState("off")
        end

        if not skip_loop then
            mqtt_reader:updateStates()

            old_power = curr_power
            curr_power = self.Charger:getPower()
            skip_loop = not curr_power or (curr_power ~= curr_power) -- ether nil or nan
            skip_loop = skip_loop or (curr_power > old_power) -- starting charge
            if curr_power > old_power then
                self.charger_max_power = curr_power or 0
            end
        end

        print("'skip_loop:"..tostring(skip_loop).."'",
              self:getGoal(), self:getState(), P_Grid, P_VenusE, curr_power, self.charger_max_power)

        if not skip_loop then
            if self:isGoal("idle") and curr_power > 0 then
                -- this will happen if the user turns charging on manually
                self:isGoal("mid_charge", true)
            elseif self:isGoal("mid_charge") then
                if self:isState("on") then
                    if P_Grid - math.abs(P_VenusE) > 0 then -- we don't have enough power from PV
                        self.Charger:stopCharge()
                    elseif curr_power < self.charger_max_power * self.charger_mid_percent then
                        self:turnOff()
                    end
                else
                    if -P_Grid + math.abs(P_VenusE) > self.charger_max_power * 1.05 then
                        -- if we have enough power from PV
                        self.Charger:startCharge(15) -- charge for 15s to get a stable charge current
                    end
                end
            elseif self:isGoal("full_charge") then
                if self:isState("on") then
                    if P_Grid - math.abs(P_VenusE) > 0 then -- we don't have enough power from PV
                        self.Charger:stopCharge()
                    elseif curr_power < self.charger_max_power * self.charger_full_percent then
                        self:turnOff()
                    end
                else
                    if -P_Grid + math.abs(P_VenusE) > self.charger_max_power * 1.05 then
                        -- if we have enough power from PV
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

local MyCharger = MopedCharger

MyCharger:init()

while true do
    util:cleanLogs()
    MyCharger:main()
end
