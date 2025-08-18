-- load mqtt module
local json = require ("dkjson")
local mqtt = require("mqtt")
local util = require("util")

local mqtt_reader = {
    client,
    ioloop,
    hosts = {},
	states = {},
}

function mqtt_reader:printStates()
	if not next(self.states) then return end
	for i, v in pairs(self.states) do
		if type(v) == "table" and v and (v.switch1 or v.power) then
			if i == "VenusE" then
				local time = os.date("%Y-%m-%d %H:%M:%S", v.time)
				print(time, i, v.switch1, v.power)
			end
		end
	end
end

function mqtt_reader:init(uri)
	-- create mqtt client
	self.client = mqtt.client{
	--[[
		username = "stPwSVV73Eqw5LSv0iMXbc4EguS7JyuZR9lxU5uLxI5tiNM8ToTVqNpu85pFtJv9",
		clean = true,
	]]
		uri = uri,
		clean = true,
	}
	print("created MQTT client", self.client)

	self.client:on{
		connect = function(connack)
			if connack.rc ~= 0 then
				print("connection to broker failed:", connack:reason_string(), connack)
				return
			end
	--		print("connected:", connack) -- successful connection

--[[
QoS 0: Die Nachricht wird höchstens einmal zugestellt (Fire and Forget).
QoS 1: Die Nachricht wird mindestens einmal zugestellt (Acknowledged Delivery).
QoS 2: Die Nachricht wird genau einmal zugestellt (Assured Delivery).
]]

			-- subscribe to test topic and publish message after it
			self.client:subscribe{
				topic="+/#",
				qos = 1,
				callback = function(suback)
					print("subscribed:", suback)
				end,
			}
		end, -- connect

		message = function(msg)
	--		if not client:acknowledge(msg) then
	--			return
	--		end
			if not msg.payload then
				return
			end

			self.got_message_in_last_iteration = true

			local full_topic = msg.topic
			local pos = full_topic:find("/")
			if not pos then return end

			local prefix = full_topic:sub(1, pos-1)
			full_topic = full_topic:sub(pos+1)

			pos = full_topic:find("/")
			if not pos then return end

			local topic = full_topic:sub(1, pos-1):lower()
			full_topic = full_topic:sub(pos+1)

			local data = full_topic

			local decoded = json.decode(msg.payload)
			if self.states[topic] == nil then
				self.states[topic] = {}
			end

			if topic == "VenusE" then
				print("xxx", string.format("%s|%s|%s", msg.topic, prefix, data))
				print("xxx", msg.payload)
				print("")
			end

			if decoded and type(decoded) ~= "number" then
				self.states[topic].time = util.getCurrentTime()
				if prefix == "tele" then
					if data == "STATE" then
						if decoded.POWER or decoded.POWER1 then	-- tele
							self.states[topic].switch1 = decoded.POWER or decoded.POWER1
						elseif decoded.POWER2 then	-- tele
							self.states[topic].switch2 = decoded.POWER2
						end
					elseif data == "SENSOR" and decoded.ENERGY then -- tele
						self.states[topic].power = decoded.ENERGY.Power
						if self.states[topic].power and self.states[topic].power > 0 then
							self.states[topic].switch1 = "ON"
						end
						self.states[topic].Today = decoded.ENERGY.Today
						self.states[topic].Yesterday = decoded.ENERGY.Yesterday
						self.states[topic].Total = decoded.ENERGY.Total
					end
				elseif prefix == "stat" then
					if data == "STATUS" then
						if decoded.Power or decoded.Power1 then -- stat
							self.states[topic].switch1 = decoded.Power or decoded.Power1
						elseif decoded.Power2 then	-- tele
							self.states[topic].switch2 = decoded.Power2
						end
					elseif data == "STATUS10" and decoded.StatusSNS then -- stat
						self.states[topic].power = decoded.StatusSNS.ENERGY.Power
						if self.states[topic].power and self.states[topic].power > 0 then
							self.states[topic].switch1 = "ON"
						end
						self.states[topic].Today = decoded.StatusSNS.ENERGY.Today
						self.states[topic].Yesterday = decoded.StatusSNS.ENERGY.Yesterday
						self.states[topic].Total = decoded.StatusSNS.ENERGY.Total
					end
				end
			end

	--[[
			if topic == "Charger" then
				print(prefix, topic, data, decoded, ".")
				print(msg)
				printStates(states)
				print(" ")
			end
			]]
	--			print(msg)
		end,

		error = function(err)
			print("MQTT client error:", err)
		end,
	}

	self.ioloop = mqtt.get_ioloop()
	self.ioloop:add(mqtt_reader.client)
end

function mqtt_reader:askHost(host)
	if not host or host == "" then return end
	host = host:lower()

	table.insert(self.hosts, host)

	self.client:publish{
		topic = "cmnd/" .. host .. "/Power",
		payload = "",
		qos = 1,
	}
	self.ioloop:iteration()
	self.client:publish{
		topic = "cmnd/" .. host .. "/Status",
		payload = "",
		qos = 1,
	}
    self.ioloop:iteration()
end

if arg[0]:find("mqtt_reader.lua") then

	mqtt_reader:init("battery-control.lan")  -- "192.168.0.12"

--	mqtt_reader:askHost("Moped-Inverter")
	mqtt_reader:askHost("Battery-Charger")
--	mqtt_reader:askHost("Battery-Charger2")
--	mqtt_reader:askHost("Garage-Inverter")
--	mqtt_reader:askHost("Battery-Inverter")

    print("now waiting for messages")
    while true do
        repeat
            mqtt_reader.ioloop:iteration()
            if mqtt_reader.got_message_in_last_iteration then
	            mqtt_reader:printStates()
				mqtt_reader.got_message_in_last_iteration = nil
				os.execute("sleep 0.1")
            else
				os.execute("sleep 1s")
			end

        until (false)
    end
end

mqtt_reader:init("battery-control.lan")  -- "192.168.0.12"

return mqtt_reader
