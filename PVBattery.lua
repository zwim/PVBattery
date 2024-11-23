
local VERSION = "V4.0"

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

local state = {
	fail = "fail",
	idle = "idle",
	charge = "charge",
	balance = "balance", -- during charge or on the high side
	full = "full",
	discharge = "discharge",
	low_battery = "low_battery",
	low_cell = "low_cell",
	cell_diff = "cell_diff",
	rescue_charge = "rescue_charge",
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

-- might be neccesary, if the user switches something manually
function PVBattery:updateState()
	for _, Charger in pairs(self.Charger) do
        if Charger:getPowerState() == "on" then
			self._state = state.charge
			return self._state
        end
    end

    for _, Inverter in pairs(self.Inverter) do
		if Inverter:getPowerState() == "on" and not Inverter.time_controlled then
            self._state = state.discharge
			return self._state
        end
    end

	for _, BMS in pairs(self.BMS) do
		if BMS:evaluateData() then
			if BMS:isBatteryFull() then
				self._state = state.full
				return self._state
			elseif BMS:needsBalancing() then
				self._state = state.balance
				return self._state
			elseif BMS.v.SOC < config.bat_SOC_min_rescue then
				self._state = state.rescue_charge
				return self._state
			elseif BMS.v.LowestVoltage < config.bat_lowest_voltage then
				self._state = state.low_cell
				return self._state
			elseif BMS.v.SOC <= config.bat_SOC_min then
				self._state = state.low_battery
				return self._state
			elseif BMS.v.CellDiff > config.max_cell_diff then
				self._state = state.cell_diff
				return self._state
			elseif self._state == state.cell_diff
				and BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
				self._state = state.cell_diff
				return self._state
			end
		end
	end

	self._state = state.idle
	return self._state
end

-- find an activated charger which is charging with more than req_power
-- or find the activated charger with the highest power.
function PVBattery:findBestChargerToTurnOff(req_power)
    local pos = 0
    local avail_power = 0

    if req_power <= 0 then print("Error: req_power " .. req_power .. "<0") end

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

function PVBattery:turnOffBestCharger(P_Grid)
	-- allow a small power buy instead of a bigger power sell.
	local charger_num, charger_power = self:findBestChargerToTurnOff(P_Grid)
	-- Only activate one inverter, as the current is only estimated-
	if charger_num > 0 then
		util:log(string.format("Deactivated Charger: %s",
				charger_num))
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

-- ToDo: If we have more than one inverte once, find the best wich Inverter:getCurrentPower
function PVBattery:findBestInverterToTurnOff(req_power)
    for i, Inverter in pairs(self.Inverter) do
		if not Inverter.time_controlled then
			if Inverter.BMS:getDischargeState() ~= "off" or Inverter:getPowerState() ~= "off" then
				return i, Inverter:getCurrentPower()
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
	end
end

function PVBattery:findBestInverterToTurnOn(req_power)
    local pos = 0
    local avail_power = 0

    if req_power < 0 then
		req_power = 0
	end

    for i, Inverter in pairs(self.Inverter) do
        local min_power = Inverter.min_power or math.huge
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
		return -10
	else
		return 0
	end
end

function PVBattery:isDischarging()
    for _, Inverter in pairs(self.Inverter) do
        if not Inverter.time_controlled and Inverter:getPowerState() == "on"
			and math.abs(Inverter:getCurrentPower()) > 10 then
            return true
        end
    end
    return false
end

PVBattery[state.cell_diff] = function(self, P_Grid, date)
	if P_Grid < self:chargeThreshold(date) then -- sell more than threhold energy
		self:turnOnBestCharger(P_Grid)
	else
		for _, BMS in pairs(self.BMS) do
			if BMS:evaluateData() then
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
	if P_Grid < self:chargeThreshold(date) then -- sell more than threhold energy
		self:turnOnBestCharger(P_Grid)
	elseif P_Grid > 0 then -- buying energy
		if not self:turnOffBestCharger(P_Grid) then
			print("Huston we have a problem")
		end
	end
end

PVBattery[state.discharge] = function(self, P_Grid)
	if P_Grid > 0 then -- sell more than threshold
		self:turnOnBestInverter(P_Grid)
	else
		self:turnOffBestInverter(P_Grid)
	end
end

PVBattery[state.balance] = function(self, P_Grid, date)
	-- this is almost same as in idle, but no disableDischarge here
	if P_Grid < self:chargeThreshold(date) then -- sell more than threhold energy
		self:turnOnBestCharger(P_Grid)
	elseif P_Grid > 0 then -- buying energy
		self:turnOffBestCharger(P_Grid)
	end

	for _, BMS in pairs(self.BMS) do
		if BMS:needsBalancing() then
			BMS:enableDischarge()
			BMS:setAutoBalance(true)
		end
	end
end

PVBattery[state.full] = function(self)
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

function PVBattery:main(profiling_runs)
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

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
            short_sleep = 4
            skip_loop = true
        end

		if not skip_loop then
			util:log(string.format("Grid %8.2f W (%s)", P_Grid, P_Grid > 0 and "optaining" or "selling"))
			util:log(string.format("Load %8.2f W", P_Load))
			util:log(string.format("Roof %8.2f W", P_PV))

			-- update state, as the battery may have changed or the user could have changed something manually
			local oldstate = self._state or ""
			if oldstate ~= self:updateState() then
				os.execute("date")
				print("State: ", oldstate, "->", self._state)
			end
			util:log("State: ", oldstate, "->", self._state)

			self:generateHTML(config, P_Grid, P_Load, P_PV, VERSION)

			if self[self._state] then
				self[self._state](self, P_Grid, date) -- execute the state
			else
				local error_msg = "Error: state '"..tostring(self._state).."' not implemented yet"
				util:log(error_msg)
				print(error_msg)
			end

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