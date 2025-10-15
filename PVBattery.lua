
-- ###############################################################
-- CONFIGURATION
-- ###############################################################
local VERSION = "V5.0.0"

local Profiler = nil
-- profiler from https://github.com/charlesmallah/lua-profiler
--local Profiler = require("suntime/profiler")
if Profiler then
    Profiler.start()
end

local MIN_CHARGE_POWER = 20
local MIN_DISCHARGE_POWER = 20

------------------------------------------------------------------

-- luacheck: globals config
config = require("configuration") -- this one is global

local mqtt_reader = require("mqtt_reader")
local util = require("util")

local SunTime = require("suntime/suntime")

local Influx = require("influx")

local BaseClass = require("BaseClass")
local CustomBattery = require("CustomBattery")
local MarstekBattery = require("MarstekBattery")
local EnvertechInverter = require("EnvertechInverter")
local FroniusInverter = require("FroniusInverter")
local Homewizard = require("Homewizard")

local PVBattery = BaseClass:extend{
    __name = "PVBattery",
    __loglevel = 3,
    _state = "", -- no state yet

    -- very coarse default sunrise and sunset
    sunrise = 6,
    sunset = 18,

    P_Grid = 0,
    P_Load = 0,
    P_PV = 0,
    P_AC = 0,
}

-------------------- extend functions from this file
PVBattery.generateJSON = require("PVBatteryJSON")
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
--    config:read()
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
--    self.P1meter = P1meter:new{host = "HW-p1meter.lan"}

    -- Init all device configurations

    mqtt_reader:init(config.mqtt_broker_uri, config.mqtt_client_id)

    self.Battery = {}      -- all batteries
    self.SmartBattery = {} -- a subset of stupid custom batteries from all batteries
    self.USPBattery = {}   -- a subset of smart batteries from all batteries

    self.Inverter = {}
    self.Smartmeter = {}
    for _, Device in ipairs(config.Device) do
        local typ = Device.typ:lower()
        local brand = Device.brand:lower()
        if typ == "battery" then
            if  brand == "custom" then
                local cBatt = CustomBattery:new{Device = Device}
                table.insert(self.Battery, cBatt)
                table.insert(self.USPBattery, cBatt)
            elseif brand == "marstek" then
                local mBatt = MarstekBattery:new{Device = Device}
                table.insert(self.Battery, mBatt)
                table.insert(self.SmartBattery, mBatt)
            else
                assert(false, "Wrong configuration, battery brand not known")
            end
        elseif typ == "inverter" then
            if brand == "envertech" then
                local eInv = EnvertechInverter:new{Device = Device}
                table.insert(self.Inverter, eInv)
            elseif brand == "fronius" then
                table.insert(self.Inverter, FroniusInverter:new{Device = Device})
            else
                assert(false, "Wrong configuration, inverter brand not known")
            end
        elseif typ == "smartmeter" then
            table.insert(self.Smartmeter, Homewizard:new{Device = Device})
        end
    end

    -- Influx:init("http://localhost:8086", "", "Photovoltaik", "Leistung")
--    Influx:init(config.db_url, config.db_token, config.db_org, config.db_bucket) -- xx

    -- self.SmartBattery[2//]:take(200)
    -- self.SmartBattery[1]:take(200)

    self:log(0, "Initialisation completed")
end

function PVBattery:getValues()
    -- Attention, this accesses self.SmartBattery and self.USPBattery as well
    for _, Battery in ipairs(self.Battery) do
--        local start_time
--        start_time = util.getCurrentTime()
        Battery.SOC = Battery:getSOC(true) or 0 -- force recalculation
--        print("time SOC: ", util.getCurrentTime() - start_time, Battery.SOC .. "%")
--        start_time = util.getCurrentTime()
        Battery.state = Battery:getState() or {}
--        print("time state: ", util.getCurrentTime() - start_time)
    end
end

local P_exzess_old = 0
function PVBattery:doTheMagic()
    local battery_string = ""

    self.P_Battery = 0
    for _, Battery in ipairs(self.Battery) do
        Battery.power = Battery:getPower() -- negative, if dischargeing
        self.P_Battery = self.P_Battery + Battery.power
        battery_string = battery_string .. string.format("%s: %5.0f   ", Battery.Device.name, Battery.power)
    end
    self:log(3, "Battery ... ", battery_string)

--[[
    self:log(3, "     ------")
    self:log(3, "Inverter: " .. string.format("%5.1f", P_Inverter), "Battery: " .. string.format("%5.1f", P_Battery))

    local status_string = ""
    for _, Battery in ipairs(self.Battery) do
        status_string = status_string .. Battery.Device.name .. ": " .. self.listValues(Battery:getState()) .. "   "
    end
    for _, Inverter in ipairs(self.Inverter) do
        status_string = status_string .. Inverter.Device.name .. ": " .. self.listValues(Inverter:getState()) .. "   "
    end
    self:log(3, "Status:", status_string)
]]
    -- P_exzess is the power we could
    --     store in our batteries if negative
    --     reclaim from our batteries if positive

    local inverter_string = ""
    local P_Inverter = 0
    self.P_Grid = 0
    for _, Inverter in ipairs(self.Inverter) do
        local power, Grid, Load, PV, AC  = Inverter:getPower()
        if Grid then
            self.P_Load, self.P_PV, self.P_AC = Load, PV, AC
        end
        P_Inverter = P_Inverter + power
        inverter_string = inverter_string .. string.format("%s: %5.0f   ", Inverter.Device.name, power)
    end
    self:log(3, "Inverter ... ", inverter_string)

    local value , is_data_old = self.Smartmeter[1]:getPower()

    if is_data_old then
        self:log(1, "P1Meter: no new data")
        return
    end

    self.P_Grid = value

    self:log(3, "P_Grid ... ", self.P_Grid)

--    self.P_Grid = self.P_Grid < 2000 -- simulate 2000 W form PV

    local P_exzess = self.P_Grid + self.P_Battery
    self:log(1, string.format("P_exzess: %5.1f, %5.1f", P_exzess, P_exzess_old))

    if math.abs(self.P_Grid) < 10 then
        return false
    end

    -- if at least one battery does not, what is expected, turn it of and retrun early
    -- we get here soon again ;)
    local clear_any_battery
    if P_exzess > MIN_DISCHARGE_POWER then -- discharge batteries
        for _, Battery in ipairs(self.Battery) do
            if Battery.state.take then
                Battery:take(0)
                clear_any_battery = "taken"
            end
        end
    elseif P_exzess < -MIN_CHARGE_POWER then -- charge batteries
        for _, Battery in ipairs(self.Battery) do
            if Battery.state.give then
                Battery:give(0)
                clear_any_battery = "given"
            end
        end
    end
    if clear_any_battery then
        self:log(3, clear_any_battery)
        return true
    end

    if math.abs(P_exzess - P_exzess_old) < 10 then
        return false
    end


    P_exzess_old = P_exzess

    if P_exzess > MIN_DISCHARGE_POWER then -- discharge batteries
        for _, Battery in ipairs(self.USPBattery) do
            local max_discharge_power_power = -Battery.Inverter:getMaxPower() -- negative, maximal discharge of the USP
            if P_exzess + max_discharge_power_power > 0 then
                local state = Battery.state
                if state.idle or state.give or state.can_give then
                    Battery:give(math.abs(P_exzess))
                    mqtt_reader:sleepAndCallMQTT(2)
                    Battery.power = Battery:getPower() -- negative, if dischargeing
                    self:log(2, "GIVE", Battery.Device.name, Battery.power)
                    P_exzess = P_exzess - Battery.power
                end
            else
                P_exzess = P_exzess + Battery.power -- because we stop battery soon
                Battery:give(0)
                Battery.power = 0
                self:log(2, "GIVE", Battery.Device.name, 0)
            end
        end

        local sum_remaining_SOC = 0
        for _, Battery in ipairs(self.SmartBattery) do
            sum_remaining_SOC = sum_remaining_SOC + math.max(0, Battery.SOC - Battery.Device.SOC_min)
            Battery.batt_req_power = 0
        end
        if sum_remaining_SOC > 1 then
            local nb_batteries = #self.SmartBattery
            local not_distributed_power = P_exzess -- positive
            -- first distribute power depending on SOC
            for _, Battery in ipairs(self.SmartBattery) do
                local p = 0
                if Battery.SOC >= Battery.Device.SOC_min then
                    p = P_exzess * (Battery.SOC - Battery.Device.SOC_min) / sum_remaining_SOC -- proportional share
                    if p > Battery.Device.discharge_max_power then
                        p = Battery.Device.discharge_max_power
                        nb_batteries = nb_batteries - 1
                    end
                    if p < MIN_CHARGE_POWER then
                        p = 0 -- no power for now
                    end
                end
                Battery.batt_req_power = p -- is positive or zero
                not_distributed_power = not_distributed_power - p -- should be and stay positive
            end

nb_batteries = - 1 -- keine nachvewrteilugn
            -- if there is not_distributed_power and
            while not_distributed_power > MIN_DISCHARGE_POWER and nb_batteries > 0 do
                local remaining_power = not_distributed_power / nb_batteries
                if remaining_power < MIN_DISCHARGE_POWER then
                    remaining_power = not_distributed_power -- give it all to one
                end
                for _, Battery in ipairs(self.SmartBattery) do
                    if Battery.Device.charge_max_power > Battery.batt_req_power then -- may get some power too
                        local power_to_add = remaining_power
                        if Battery.Device.discharge_max_power < Battery.batt_req_power + power_to_add   then
                            power_to_add = Battery.batt_req_power + power_to_add - Battery.Device.discharge_max_power
                        end
                        Battery.batt_req_power = Battery.batt_req_power + power_to_add
                        not_distributed_power = not_distributed_power - power_to_add
                        nb_batteries = nb_batteries - 1
                        if not_distributed_power <= 0 or nb_batteries < 1 then
                            break
                        end
                    end
                end
            end
        end -- sum_remaining_SOC

        for _, Battery in ipairs(self.SmartBattery) do
            Battery.batt_req_power = math.min(Battery.batt_req_power, Battery.Device.discharge_max_power)
            Battery:give(math.floor(Battery.batt_req_power))
            self:log(2, "GIVE", Battery.Device.name, Battery.batt_req_power)
            Battery.power = Battery.batt_req_power
        end

    elseif P_exzess < -MIN_CHARGE_POWER then -- charge batteries

        for _, Battery in ipairs(self.USPBattery) do
            local max_charger_power = math.min(Battery.Charger[1]:getMaxPower(),Battery.Charger[2]:getMaxPower())
            if   P_exzess + max_charger_power < 0 then
                local state = Battery.state
                if state.idle or state.take or state.can_take then
                    Battery:take(math.abs(P_exzess))
                    mqtt_reader:sleepAndCallMQTT(2)
                    Battery.power = Battery:getPower() -- negative if dischargeing
                    self:log(2, "TAKE", Battery.Device.name, Battery.power)
                    P_exzess = P_exzess - Battery.power
                end
            else
                P_exzess = P_exzess + Battery.power
                Battery:take(0)
                Battery.power = 0
                self:log(2, "TAKE", Battery.Device.name, 0)
            end
        end

        local sum_missing_SOC = 0
        for _, Battery in ipairs(self.SmartBattery) do
            sum_missing_SOC = sum_missing_SOC + math.max(0, Battery.Device.SOC_max - Battery.SOC)
            Battery.batt_req_power = 0
        end
        if sum_missing_SOC > 1 then
            local nb_batteries = #self.SmartBattery
            local not_distributed_power = P_exzess --negative
            -- first distribute power depending on SOC
            for _, Battery in ipairs(self.SmartBattery) do
                local p = 0
                if Battery.SOC <= Battery.Device.SOC_max then
                    p = (P_exzess * (Battery.Device.SOC_max - Battery.SOC) / sum_missing_SOC) -- proportional share
                    if p < -Battery.Device.charge_max_power then
                        p = -Battery.Device.charge_max_power
                        nb_batteries = nb_batteries - 1
                    end
                    if p > -MIN_CHARGE_POWER then
                        p = 0 -- no power for now
                    end
                end
                Battery.batt_req_power = p -- is negative
                not_distributed_power = not_distributed_power - p -- should be and stay negative
            end

            -- if there is not_distributed_power and
            while not_distributed_power < -MIN_CHARGE_POWER and nb_batteries > 0 do
                self:log(3, "distributing Power: " .. not_distributed_power)
                local remaining_power = not_distributed_power / nb_batteries
                if remaining_power > -MIN_CHARGE_POWER then
                    remaining_power = not_distributed_power
                end
                for _, Battery in ipairs(self.SmartBattery) do
                    if -Battery.Device.charge_max_power < Battery.batt_req_power then -- may get some power too
                        local power_to_add = remaining_power
                        if -Battery.Device.charge_max_power > Battery.batt_req_power + power_to_add   then
                            power_to_add = Battery.batt_req_power + power_to_add - Battery.Device.charge_max_power
                        end
                        Battery.batt_req_power = Battery.batt_req_power + power_to_add
                        not_distributed_power = not_distributed_power - power_to_add
                        nb_batteries = nb_batteries - 1
                        if not_distributed_power >= 0 or nb_batteries < 1 then
                            break
                        end
                    end
                end
            end

        end -- sum_missing_SOC
        for _, Battery in ipairs(self.SmartBattery) do
            Battery.batt_req_power = math.min(Battery.batt_req_power, Battery.Device.discharge_max_power)
            Battery:take(math.floor(math.max(0, -Battery.batt_req_power)))
            self:log(2, "TAKE", Battery.Device.name, Battery.batt_req_power)
            Battery.power = Battery.batt_req_power
        end
    end
    return true
end

function PVBattery:outputTheLog(date_string)
    local log_string
    log_string = string.format("%s  P_Grid=%5.0fW, P_Load=%5.0fW, Battery=%5.0fW, P_VenusE1=%5.0fW, P_VenusE1=%5.0fW",
        date_string, self.P_Grid or 0, self.P_Load or 0,
        self.Battery[1].power or 0,
        self.Battery[2].power or 0,
        self.Battery[3].power or 0)

    util:log(log_string)
end

function PVBattery:writeToDatabase()
    print("no influx for now")
    if true then return end

    local datum = "Leistung"
    Influx:writeLine("garage-inverter", datum, self.Inverter[1]:getPower())
    Influx:writeLine("battery-inverter", datum, self.Inverter[2]:getPower())
    Influx:writeLine("balkon-inverter", datum, self.Inverter[3]:getPower())

    Influx:writeLine("battery-charger", datum, self.Charger[1]:getPower())
    Influx:writeLine("battery-charger2", datum, self.Charger[2]:getPower())

    Influx:writeLine("P_PV", datum, self.P_PV)
    Influx:writeLine("P_Grid", datum, self.P_Grid)
    Influx:writeLine("P_Load", datum, self.P_Load)

    Influx:writeLine("P_VenusE", datum, self.SmartBattery[1].power)
    Influx:writeLine("P_VenusE2", datum, self.SmartBattery[2].power)

    Influx:writeLine("Status", "Status", self:getState())

    datum = "Energie"
    Influx:writeLine("garage-inverter", datum, self.Inverter[1]:getEnergyTotal())
    Influx:writeLine("battery-inverter", datum, self.Inverter[2]:getEnergyTotal())
    Influx:writeLine("balkon-inverter", datum, self.Inverter[3]:getEnergyTotal())

    Influx:writeLine("battery-charger", datum, self.Charger[1]:getEnergyTotal())
    Influx:writeLine("battery-charger2", datum, self.Charger[2]:getEnergyTotal())
end

function PVBattery:main(profiling_runs)
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

    while type(profiling_runs) ~= "number" or profiling_runs > 0 do
        self:log(0, "-----------------------")
        if type(profiling_runs) == "number" then
            profiling_runs = profiling_runs - 1
        end
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
        end

        util:log("\n-------- Total Overview:")
        util:log(string.format("Grid %8f W (%s)", self.P_Grid, self.P_Grid > 0 and "optaining" or "selling"))
        util:log(string.format("Load %8f W", self.P_Load))
        util:log(string.format("Roof %8f W", self.P_PV))
        util:log(string.format("VenusE1 %8f W", self.SmartBattery[1].power))
        util:log(string.format("VenusE2 %8f W", self.SmartBattery[2].power))

        self:getValues()

        -- update state, as the battery may have changed or the user could have changed something manually
        self:outputTheLog(date_string)
        self:writeToDatabase()

--        self:log(2, "generate JSON")
--        local ok, result = pcall(self.generateJSON, self, VERSION)
--        if not ok then
--            print("Error on generateJSON", result)
--        end

        self:log(2, "dothemagic")

        ---------------------------------------------------
        if self:doTheMagic() then
            short_sleep = 1
        end

        self:getValues()

        self:log(2, "generate JSON")
        local ok, result = pcall(self.generateJSON, self, VERSION)
        if not ok then
            print("Error on generateJSON", result)
        end

        self:serverCommands()

        util:log("\n. . . . . . . . . sleep . . . . . . . . . . . .")

        mqtt_reader:sleepAndCallMQTT(short_sleep, _start_time)
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

util.deleteRunningInstances("PVBattery")

local MyBatteries = PVBattery:new{}

MyBatteries:log(0, "Istantiation done")

if not Profiler then
    -- this is the outer loop, a safety-net if the inner loop is broken with `break`
    while true do
        util:cleanLogs()
        MyBatteries:main()
        ------- todo
--        MyBatteries.BMS[1].timeOfLastFullBalancing = util.getCurrentTime() - 26*3600 -- yesterday the same time
        local ok, result = xpcall(function() MyBatteries:main() end, util.crashHandler)
--        MyBatteries:main()
        if ok then
            print("[Main] Erfolgreich beendet. Das sollte nicht passieren")
        else
            if tostring(result):match("interrupted") then
                print("Ctrl+C (SIGINT)")
                -- todo: set mode to auto
                os.exit(0)
            else
                print("[Main] Fehler:", result, "Restart main loop")
            end
        end
    end
else -- if Profiler
    MyBatteries:main(1)
    Profiler.stop()
    Profiler.report("test-profiler.log")
end
