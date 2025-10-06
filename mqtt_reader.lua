-- load mqtt module
local json = require ("dkjson")
local mqtt = require("mqtt")
local util = require("util")

local mqtt_reader = {
    client = nil,
    ioloop = nil,
	states = {},
    got_message_in_last_iteration = false,
}

function mqtt_reader:printStates()
	if not next(self.states) then return end
	for i, v in pairs(self.states) do
		if type(v) == "table" and v and (v.switch1 or v.power) then
			local time = os.date("%Y-%m-%d %H:%M:%S", v.time)
			print(time, i, v.switch1, v.power)
		end
	end
end

function mqtt_reader:init(uri, id)
	assert(id ~= nil and id ~= "")
	-- create mqtt client
	self.client = mqtt.client{
	--[[
		username = "stPwSVV73Eqw5LSv0iMXbc4EguS7JyuZR9lxU5uLxI5tiNM8ToTVqNpu85pFtJv9",
		clean = true,
	]]
		id = id,
		uri = uri,
		clean = true,
	}

	self.client:on{
		connect = function(connack)
			if connack.rc ~= 0 then
				print("connection to broker failed:", connack:reason_string(), connack)
				return
			else
				print("connected to broker")
			end

		end, -- connect

		message = function(msg)
	--		if not client:acknowledge(msg) then
	--			return
	--		end
			if not msg.payload then
				return
			end

			self.got_message_in_last_iteration = true

			local msg_topic = msg.topic
			local pos = msg_topic:find("/")
			if not pos then return end

			local prefix = msg_topic:sub(1, pos-1)
			msg_topic = msg_topic:sub(pos+1)

			pos = msg_topic:find("/")
			if not pos then return end

			local topic = msg_topic:sub(1, pos-1):lower()
			msg_topic = msg_topic:sub(pos+1)

			local data = msg_topic

			msg.payload = msg.payload:lower()

			local decoded = json.decode(msg.payload)
			if self.states[topic] == nil then
				self.states[topic] = {}
			end

--			print(prefix, topic, data)

			if decoded and type(decoded) ~= "number" then
				self.states[topic].time = util.getCurrentTime()
				if prefix == "tele" or prefix == "stat" then
					if data == "STATE" or data == "STATUS" then
						if decoded.power or decoded.power1 then	-- tele
							self.states[topic].switch1 = decoded.power or decoded.power1
						elseif decoded.power2 then	-- tele
							self.states[topic].switch2 = decoded.power2
						end
					elseif data == "SENSOR" and decoded.energy then -- tele
						self.states[topic].power = decoded.energy.power
						if self.states[topic].power and self.states[topic].power > 0 then
							self.states[topic].switch1 = "on"
						end
						self.states[topic].today = decoded.energy.today
						self.states[topic].yesterday = decoded.energy.yesterday
						self.states[topic].total = decoded.energy.total
					elseif data == "STATUS10" and decoded.statussns then -- stat
						self.states[topic].power = decoded.statussns.energy.power
						if self.states[topic].power and self.states[topic].power > 0 then
							self.states[topic].switch1 = "on"
						end
						self.states[topic].today = decoded.statussns.energy.today
						self.states[topic].yesterday = decoded.statussns.energy.yesterday
						self.states[topic].total = decoded.statussns.energy.total
					elseif data == "RESULT" then
						if decoded.power then
							self.states[topic].switch1 = decoded.power
						end
					elseif data == "POWER" then
						if decoded.power then
							self.states[topic].switch1 = decoded.power
						end
					end
				end
			end
		end,

		error = function(err)
			print("MQTT client error:", err)
		end,
	}

	self.ioloop = mqtt.get_ioloop()
	self.ioloop:add(self.client)
end

function mqtt_reader:subscribe(topic, qos)
	if not qos then qos = 0 end

	topic = topic:match("^(.*)%.") or topic
	topic = topic:lower()

	if topic then
		topic = "+/" .. topic .. "/#"
	else
		topic = "+/#"
	end
	--[[
	QoS 0: Die Nachricht wird höchstens einmal zugestellt (Fire and Forget).
	QoS 1: Die Nachricht wird mindestens einmal zugestellt (Acknowledged Delivery).
	QoS 2: Die Nachricht wird genau einmal zugestellt (Assured Delivery).
	]]
	-- subscribe to test topic and publish message after it
	self.client:subscribe{
		topic = topic,
		qos = qos,
		callback = function(suback)
			print("subscribed ro to " .. topic .. " with qos=", qos, suback)
		end,
	}
end

function mqtt_reader:askHost(host)
	if not host or host == "" then return end
	host = host:match("^(.*)%.") or host
	host = host:lower()

	self.client:publish{
		topic = "cmnd/" .. host .. "/Power",
		payload = "",
		qos = 0,
	}
	self.client:publish{
		topic = "cmnd/" .. host .. "/Status",
		payload = "",
		qos = 0,
	}
    self.ioloop:iteration()
end

function mqtt_reader:clearRetainedMessages(topic)
	if not topic or topic == "" then return end

	self.client:publish{
		topic = topic,
		payload = "",
		retain = true,
		qos = 0,
	}
	self.ioloop:iteration()
end

-- luacheck: ignore self
function mqtt_reader:updateStates(wait_time)
	wait_time = wait_time or 0.2
	local got_message
    while true do
        mqtt_reader.got_message_in_last_iteration = false
        mqtt_reader.ioloop:iteration()
		if not mqtt_reader.got_message_in_last_iteration then
			break
		end
		got_message = true
        util.sleepTime(wait_time)
    end
	return got_message
end

if arg[0]:find("mqtt_reader.lua") then

	mqtt_reader:init("battery-control.lan", "newone")  -- "192.168.0.12"
	mqtt_reader:updateStates()

--[[
	mqtt_reader:subscribe("moped-charger.lan", 0)
	util.sleepTime(1)
	mqtt_reader:updateStates()
	util.sleepTime(1)
	mqtt_reader:askHost("moped-charger.lan")
	mqtt_reader:updateStates()
]]
	util.sleepTime(1)

	mqtt_reader:subscribe("battery-charger2.lan", 0)
	util.sleepTime(1)
	mqtt_reader:updateStates()

    print("now waiting for messages")
    while true do
		if mqtt_reader:updateStates() then
			mqtt_reader:printStates()
			os.execute("sleep 0.1")
		else
			os.execute("sleep 1s")
		end
    end
end

return mqtt_reader
