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
}

function PVBattery:init()
    config:read()
    util:setLog(config.log_file_name or "config.lua")

    util:log("\n#############################################")
    util:log("PV-Control started.")
    util:log("#############################################")

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

	Fronius = Fronius:new{host = config.FRONIUS_ADR}

	for i = 1, #config.Device do
		local BMS = AntBMS:new{host = config.Device[i].BMS}
		table.insert(self.BMS, BMS)

		local inv = InverterClass:new {
			inverter_host = config.Device[i].inverter_switch,
			inverter_min_power = config.Device[i].inverter_min_power,
			skip = config.Device[i].inverter_skip,
			BMS = BMS,
		}
		table.insert(self.Inverter, inv)

		for j = 1, #config.Device[i].charger_switch do
			local chg = ChargerClass:new{
				switch_host = config.Device[i].charger_switch[j],
				BMS = BMS,
			}
			table.insert(self.Charger, chg)
		end
	end

	-- set max_power to a small value, will get updated during run
	for _, chg in pairs (self.Charger) do
		chg.Switch.max_power = 50
	end

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
		local min_power = inv.inverter_min_power or math.huge
		if min_power < req_power and min_power > avail_power then<<<<<<< HEAD
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
		if not inverter.inverter_skip and inverter:getPowerState() == "on" then
			return true
		end
	end
	return false
end

function PVBattery:generateHTML(P_Grid, P_Load, P_PV)

	local TEMPLATE_PARSER = {
		{"_$DATE", ""},
		{"_$SUNRISE", self.sunrise},
		{"_$SUNSET", self.sunset},
		{"_$FRONIUS_ADR", config.FRONIUS_ADR},
		{"_$STATE_OF_OPERATION", self.state},
		{"_$P_GRID", string.format("%7.2f", P_Grid)},
		{"_$P_SELL_GRID", P_Grid < 0 and string.format("%7.2f", P_Grid) or "0.00"},
		{"_$P_BUY_GRID", P_Grid > 0 and string.format("%7.2f", P_Grid) or "0.00"},
		{"_$P_LOAD", string.format("%7.2f", P_Load)},
		{"_$P_ROOF", string.format("%7.2f", P_PV)},
		{"_$BMS1_INFO", "http://" .. self.BMS[1].host .. "/show"},
		{"_$BMS1_BALANCE", "http://" .. self.BMS[1].host .. "/balance.toggle"},

		{"_$BATTERY_CHARGER1_POWER",
			string.format("%7.2f", self.Charger[1]:getCurrentPower())},
		{"_$BATTERY_CHARGER1", self.Charger[1].switch_host},
		{"_$BATTERY_CHARGER2_POWER",
			string.format("%7.2f", self.Charger[2]:getCurrentPower())},
		{"_$BATTERY_CHARGER2", self.Charger[2].switch_host},
		{"_$BATTERY_INVERTER_POWER",
			string.format("%7.2f", self.Inverter[1]:getCurrentPower())},
		{"_$BATTERY_INVERTER", self.Inverter[1].inverter_host},
		{"_$GARAGE_INVERTER_POWER",
			string.format("%7.2f", self.Inverter[2]:getCurrentPower())},
		{"_$GARAGE_INVERTER", self.Inverter[2].inverter_host},
		{"_$MOPED_CHARGER_POWER",
			string.format("%7.2f", self.Charger[3]:getCurrentPower())},
		{"_$MOPED_CHARGER", self.Charger[3].switch_host},
		{"_$MOPED_INVERTER_POWER",
			string.format("%7.2f", self.Inverter[3]:getCurrentPower())},
		{"_$MOPED_INVERTER", self.Inverter[3].inverter_host},
	}

	local sinks = 0
	for _, chg in pairs(self.Charger) do
		local x = chg:getCurrentPower()
		sinks = sinks + (x or 0)
	end
	table.insert(TEMPLATE_PARSER, {"_$POWER_SINKS",
			string.format("%7.2f", sinks)})

	local sources = 0
	for _, inv in pairs(self.Inverter) do
		local x = inv:getCurrentPower()
		sources = sources + (x or 0)
	end
	table.insert(TEMPLATE_PARSER, {"_$POWER_SOURCES",
			string.format("%7.2f", sources)})

	table.insert(TEMPLATE_PARSER, {"_$POWER_CONSUMED",
			string.format("%7.2f", P_Grid + sources - sinks)})

	local date = os.date("*t")

	TEMPLATE_PARSER[1][2] = string.format("%d/%d/%d-%02d:%02d:%02d",
		date.year, date.month, date.day, date.hour, date.min, date.sec)

    local template_descriptor = io.open("./index_template.html", "r")
	if not template_descriptor then
		print("Error opening: ", config.html_main)
		return
	end

	local content = template_descriptor:read("*a")
    template_descriptor:close()

	for _, v in pairs(TEMPLATE_PARSER) do
		while content:find(v[1]) do
			content = content:gsub(v[1], v[2])
		end
	end

    local index_descriptor = io.open(config.html_main, "w")
	if not index_descriptor then
		print("Error opening: ", config.html_main)
		return
	end
    index_descriptor:write(content)
    index_descriptor:close()
end

function PVBattery:main()
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

	-- state can be idle, lowBattery, lowSoc, highBattery, highSoc, charging, discharging
	self.state = "idle"

    while true do
		local skip = false
        local short_sleep = nil -- a number here will shorten the sleep time
        local _start_time = util.getCurrentTime()

		local charger_num = 0
		local charger_power
		local inverter_num = 0
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
        Fronius:getPowerFlowRealtimeData()
        local P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        local repeat_request = math.min(20, config.sleep_time - 5)
        while not P_Grid or not P_Load or not P_PV and repeat_request > 0 do
            util:log("Communication error: repeat request:", repeat_request)
            repeat_request = repeat_request - 1
            util.sleep_time(1) -- try again in 1 second
            P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        end

		if not P_Grid then
			short_sleep = 1
			skip = true
		end

        util:log(string.format("Grid %8.2f W", P_Grid))
        util:log(string.format("Load %8.2f W", P_Load))
        util:log(string.format("Roof %8.2f W", P_PV))

--        util:log("\n-------- Battery status:")

        if not skip then
			print("P_GRID", P_Grid)

			for _,charger in pairs(self.Charger) do
				if charger.BMS:isLowCharged() then
					skip = true
				end
			end
			if skip then
				for _,inv in pairs(self.Inverter) do
					if inv.BMS:isLowCharged() then
						inv:stopDischarge()
						self.state = "lowBattery"
					end
				end
			end
		end

		if not skip then
			if P_Grid > 0 and self.state ~= "lowBattery" then
				if self:isCharging() then
					short_sleep = 1
					for _, chg in pairs(self.Charger) do
						chg:stopCharge()
					end
					self.state = "idle"
				else
					inverter_num, inverter_power = self:findBestInverter(P_Grid)
					print(inverter_num, inverter_power)
					print("xxx activate inverter:", inverter_num)
					if inverter_num > 0 then
						self.Inverter[inverter_num]:startDischarge(P_Grid)
						short_sleep = 10  -- inverters are slower than chargers
						self.state = "discharging"
					end
				end
			elseif P_Grid < 0 then
				if self:isDischarging() then
					short_sleep = 1
					for _, inv in pairs(self.Inverter) do
						inv:stopDischarge()
					end
					self.state = "idle"
				else
					charger_num, charger_power = self:findBestCharger(-P_Grid)
					print(charger_num, charger_power)
					print("xxx activate charger:", charger_num)
					if charger_num > 0 then
						self.Charger[charger_num]:startCharge()
						short_sleep = 10  -- inverters are slower than chargers
						print("switch: ", charger_num, " max_power", self.Charger[charger_num].Switch.max_power)
						self.state = "charging"
					end
				end
			end
        end -- if skip

		for _, bms in pairs(self.BMS) do
			bms:printValues()
		end

        self:generateHTML(P_Grid, P_Load, P_PV)

		print("new state", self.state)
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

util:cleanLogs()

while true do
    MyBatteries:main()
end
