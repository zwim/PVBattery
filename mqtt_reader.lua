-- load mqtt_reader module

local json = require("dkjson")
local mqtt = require("mqtt")
local util = require("util")

math.randomseed(os.time() + os.clock() * 10000)

-- ##############################################################
-- CONFIGURATION
-- ##############################################################
local LOGLEVEL = 4 -- 0 = silent, 1 = info, 2 = debug, 3 = verbose, 4 = chatty

local function log(level, ...)
    if level <= LOGLEVEL then
        print(os.date("%Y/%m/%d-%H:%M:%S [mqtt_reader]"), ...)
    end
end

-- ##############################################################
-- MAIN OBJECT
-- ##############################################################
local mqtt_reader = {
    uri = nil,
    id = nil,
    client = nil,
    ioloop = nil,
    states = {},
    got_message_in_last_iteration = false,
}

-- ##############################################################
-- HELPER FUNCTIONS
-- ##############################################################

-- Safe JSON decode: prevents crashes on invalid JSON
local function safe_json_decode(payload)
    local ok, result = pcall(json.decode, payload)
    if not ok then
        log(2, "JSON decode error:", result)
        return nil
    end
    return result
end

-- Safe table lookup
local function safe_get(table, key)
    return (table and table[key]) or nil
end

function mqtt_reader:setLogLevel(new_level)
	LOGLEVEL = new_level
end

-- ##############################################################
-- PRINT DEVICE STATES
-- ##############################################################
function mqtt_reader:printStates(clear)
    if not next(self.states) then return end
    for name, v in pairs(self.states) do
        if type(v) == "table" and (v.switch1 or v.power) then
            local t = v.time and os.date("%Y-%m-%d %H:%M:%S", v.time) or "-"
            print(string.format("%-19s %-20s %-5s %-8s", t, name, tostring(v.switch1), tostring(v.power)))
			if clear then
				self.states[name] = {}
			end
        end
    end
end

-- ##############################################################
-- INITIALIZATION
-- ##############################################################
--luacheck: ignore _retry_count
function mqtt_reader:init(uri, id, _retry_count)
    assert(uri and uri ~= "", "MQTT URI required")
    assert(id and id ~= "", "MQTT client ID required")

	_retry_count = _retry_count or 0
	if _retry_count > 10 then
		util.sleepTime(2)
		error("[mqtt_reader] retried to init itself more than " .. _retry_count .. " times")
	end

	id = id .. tostring(math.random(9999))
    self.uri = uri
    self.id = id

    log(1, "Initializing MQTT client " .. uri .. " with id=" .. id)

    self.client = mqtt.client{
        id = id,
        uri = uri,
        clean = false,
		reconnect = true,
    }

    -- ##############################################################
    -- MQTT CALLBACKS
    -- ##############################################################
    self.client:on{
        -- Connection callback
        connect = function(connack)
            if connack.rc ~= 0 then
                log(0, "MQTT connect failed:", connack:reason_string())
                util.sleepTime(5)
                log(1, "Retrying connection...")
                self:init(uri, id, _retry_count + 1)
                return
            end
            log(1, "Connected to MQTT broker " .. uri .. " with id=" .. id)
        end,

        -- Message callback
        message = function(msg)
            if not msg.payload then return end
			if not msg.topic then return end

            -- Split topic into prefix / device / data
            local topic_str = msg.topic
            local parts = {}
            for part in topic_str:gmatch("[^/]+") do
                table.insert(parts, part)
            end
            if #parts < 3 then return end

            local prefix = parts[1]
            local topic = parts[2]:lower()
            local data = parts[3]:upper()

            local decoded = safe_json_decode(msg.payload:lower())
            if not decoded or type(decoded) == "number" then return end

            -- Handle Tasmota-like messages
            if prefix == "tele" or prefix == "stat" then
--				print(prefix, topic, data:sub(1, 20))
				if not self.states[topic] then
					self.states[topic] = {}
				end
				local s = self.states[topic]

                if data == "STATE" or data == "STATUS"  or data == "RESULT" or data == "POWER" then
                    if decoded.power or decoded.power1 then
                        s.switch1 = decoded.power or decoded.power1
						self.got_message_in_last_iteration = true
                    elseif decoded.power2 then
                        s.switch2 = decoded.power2
						self.got_message_in_last_iteration = true
                    end
                elseif (data == "SENSOR" and decoded.energy) then
                    s.power = decoded.energy.power
                    if s.power and s.power > 0 then
						s.switch1 = "on"
					end
                    s.today = decoded.energy.today
                    s.yesterday = decoded.energy.yesterday
                    s.total = decoded.energy.total
					self.got_message_in_last_iteration = true
                elseif (data == "STATUS10" and decoded.statussns) then
                    local e = decoded.statussns.energy
                    s.power = safe_get(e, "power")
                    if s.power and s.power > 0 then
						s.switch1 = "on"
					end
                    s.today = safe_get(e, "today")
                    s.yesterday = safe_get(e, "yesterday")
                    s.total = safe_get(e, "total")
					self.got_message_in_last_iteration = true
                end
				if self.got_message_in_last_iteration then
					s.time = util.getCurrentTime()
				end
            end
        end,

        -- Error callback
        error = function(err)
            log(0, "MQTT client error:", err)
            log(0, "Reconnecting in " .. _retry_count .. " s")
            util.sleepTime(3 + _retry_count)

			self.client:close()

			local ok, connack = self.client:connect(self.uri)  -- oder passenden reconnect-Aufruf
			if not ok then
				log(0, "Reconnect failed, re-initing new client", _retry_count + 1)
				self:init(self.uri, self.id,  _retry_count + 1)
			end
		end,

        close = function()
            print("mqtt closed connection 🔌")
            self.client = nil
        end,
    }

    self.ioloop = mqtt.get_ioloop()
    self.ioloop:add(self.client)

--	self:processMessages()
end

-- ##############################################################
-- SUBSCRIBE TO TOPIC
-- ##############################################################
function mqtt_reader:subscribe(topic, qos)
    qos = qos or 0
    topic = topic:match("^(.*)%.") or topic
    topic = topic:lower()
    local pattern = topic and "+/" .. topic .. "/#" or "+/#"

	self:processMessages()

    self.client:subscribe{
        topic = pattern,
        qos = qos,
        callback = function(suback)
            log(1, "Subscribed to", pattern, "QoS=", qos)
        end,
    }

	self:processMessages()
end

-- ##############################################################
-- ASK DEVICE FOR STATUS
-- ##############################################################
function mqtt_reader:askHost(host, qos)
    if not host or host == "" then return end
    host = host:match("^(.*)%.") or host
    host = host:lower()

	if not qos then
		qos = 0
	end
    self.client:publish{ topic = "cmnd/" .. host .. "/Power", payload = "", qos = qos }
    self.client:publish{ topic = "cmnd/" .. host .. "/Status", payload = "8", qos = qos }
--    self.ioloop:iteration()
	self:processMessages()
end

-- ##############################################################
-- SUBSCRIBE TO TOPIC AND ASK HOST FOR STATUS
-- ##############################################################
function mqtt_reader:subscribeAndAskHost(topic, qos)
	self:subscribe(topic, qos)
	self:askHost(topic, qos)
end

-- ##############################################################
-- CLEAR RETAINED MESSAGES
-- ##############################################################
function mqtt_reader:clearRetainedMessages(topic)
    if not topic or topic == "" then return end

	self:processMessages()
    self.client:publish{
        topic = topic,
        payload = "",
        retain = true,
        qos = 0,
    }
    self.ioloop:iteration()
end

-- ##############################################################
-- UPDATE LOOP
-- ##############################################################
--[[function mqtt_reader:processMessages(wait_time)
    wait_time = wait_time or 0.1
    local got_message = false
    while true do
        self.got_message_in_last_iteration = false
        self.ioloop:iteration()
        if not self.got_message_in_last_iteration then break end
        got_message = true
        util.sleepTime(wait_time)
    end
    return got_message
end
]]

function mqtt_reader:processMessages(wait_time)
	wait_time = wait_time or 0.1
	local timeout = 5  -- maximale Wartezeit in Sekunden für QoS-2-Handshake
	local end_time = util.getCurrentTime() + timeout
	local got_message = false
	local inflight
	while true do
		self.got_message_in_last_iteration = false
		self.ioloop:iteration()

		-- Prüfen, ob eingehende Nachricht bearbeitet wurde
		if self.got_message_in_last_iteration then
			got_message = true
		end

		-- Prüfen, ob QoS2-Nachrichten noch "in flight" sind
		inflight = 0
		if self.client and self.client.outgoing then
			for _, msg in pairs(self.client.outgoing) do
				if msg.qos == 2 then
					inflight = inflight + 1
				end
			end
		end

		-- Debug-Information
		if inflight > 0 then
			log(3, string.format("MQTT QoS2 in-flight messages: %d", inflight))
		end

		-- Bedingung zum Beenden:
		-- 1. Keine eingehende Message mehr
		-- 2. Keine QoS2-Nachricht mehr in flight
		-- 3. Oder Timeout erreicht
		if (not self.got_message_in_last_iteration and inflight == 0)
			or (util.getCurrentTime() > end_time)
		then
			break
		end

		util.sleepTime(wait_time)
	end

	-- Optional: nach dem Timeout nochmal prüfen
	if inflight > 0 then
		log(1, string.format("Warning: %d QoS2 message(s) still in flight after timeout", inflight))
	end

	return got_message
end

-- sleeps some time an process mqtt messages
-- if short_sleep not given, sleep vor config.sleep_time
-- start_time defaults to current time
-- returns number of messages received
function mqtt_reader:sleepAndCallMQTT(short_sleep, start_time)
    start_time = start_time or util.getCurrentTime()
    local sleep_time
    if short_sleep then
        sleep_time = short_sleep - (util.getCurrentTime() - start_time)
    else
        sleep_time = config.sleep_time - (util.getCurrentTime() - start_time)
    end

    local sleep_period = 0.10
	local got = 0
    repeat
        util.sleepTime(math.min(sleep_time, sleep_period))
        sleep_time = sleep_time - sleep_period
        if mqtt_reader:processMessages(0.01) then -- got message
            got = got + 1
        end
    until sleep_time <= 0
    return got
end


-- ##############################################################
-- STANDALONE MODE FOR TESTING
-- ##############################################################
function mqtt_reader:_test()
	mqtt_reader:setLogLevel(2)
    mqtt_reader:init("battery-control.lan", "mqtt_reader_standalone")
	mqtt_reader:subscribeAndAskHost("moped-charger.lan", 1)
	mqtt_reader:subscribeAndAskHost("battery-inverter.lan", 1)
	mqtt_reader:subscribeAndAskHost("balkon-inverter.lan", 2)
	mqtt_reader:subscribeAndAskHost("battery-inverter.lan", 2)

    util.sleepTime(1)

    log(1, "Waiting for MQTT messages...")

    while true do
        if mqtt_reader:processMessages() then
            mqtt_reader:printStates(true)
            util.sleepTime(0.1)
        else
            util.sleepTime(1)
        end
    end
end



if arg and arg[0] and arg[0]:find("mqtt_reader.lua") then
	mqtt_reader:_test()
end

return mqtt_reader
