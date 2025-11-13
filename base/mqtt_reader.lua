-- load mqtt_reader module

--luacheck: globals config
local mqtt = require("mqtt")
local util = require("base/util")

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
    base_id = nil, -- Neu: Basis-ID ohne Zufallszahl speichern
    id = nil, -- Aktuelle ID mit Zufallszahl
    client = nil,
    ioloop = nil,
    states = {},
    got_message_in_last_iteration = false,
}

-- ##############################################################
-- HELPER FUNCTIONS
-- ##############################################################

-- Safe table lookup
local function safe_get(table, key)
    return (table and table[key]) or nil
end

--luacheck: ignore self
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
-- DISCONNECTION
-- ##############################################################
function mqtt_reader:disconnect()
    if not self.client then
        log(1, "Client is already disconnected.")
        return
    end

    log(1, "Disconnecting MQTT client " .. (self.id or "Unknown"))

    -- 1. Client aus dem I/O-Loop entfernen
    if self.ioloop then
        self.ioloop:remove(self.client)
    end

    -- 2. DISCONNECT-Paket senden und zugrundeliegende Verbindung schließen
    local ok, err = self.client:disconnect()
    if not ok then
        log(0, "Warning: Error during MQTT disconnect:", err)
        util.restart("Error during MQTT disconnect:", 12)
    end

    -- 3. Interne Referenzen aufräumen
    self.client = nil
    self.ioloop = nil
    self.states = {}
    self.id = nil -- Aktuelle ID löschen

    log(1, "MQTT client disconnected and resources cleaned up.")
end

-- ##############################################################
-- RE-INITIALIZATION / RECONNECT
-- ##############################################################
function mqtt_reader:_reinitialize_and_connect(reason)
    log(0, "Full Re-Initialization requested due to:", reason or "Error")

    -- 1. Saubere Trennung des alten Clients
    self:disconnect()

    -- Kurze Pause, um Socket-Timeouts abzuwarten
    util.sleepTime(5)

    -- 2. Neuinitialisierung mit der gespeicherten Basis-ID
    if self.uri and self.base_id then
        -- init() erstellt einen neuen Client und einen neuen I/O-Loop-Eintrag
        self:init(self.uri, self.base_id)

        -- 3. Neuer Verbindungsversuch
        log(1, "Attempting new full connection cycle...")
        local ok, err = self:connect()
        if not ok then
            log(0, "Warning: New connection attempt failed:", err)
            util.restart("MQTT: New connection attempt failed:", 12)
        end
    else
        log(0, "Cannot re-initialize: URI or Base ID missing. Exiting.")
        util.restart("MQTT: Cannot re-initialize: URI or Base ID missing. Exiting.", 12)
    end
end

-- ##############################################################
-- INITIALIZATION (SETUP)
-- ##############################################################
function mqtt_reader:init(uri, base_id, _retry_count) -- base_id verwenden
    assert(uri and uri ~= "", "MQTT URI required")
    assert(base_id and base_id ~= "", "MQTT client ID required")

    _retry_count = _retry_count or 0
    if _retry_count > 10 then
        util.sleepTime(2)
        print("[mqtt_reader] retried to init itself more than " .. _retry_count .. " times")
        util.restart("[mqtt_reader] retried to init itself more than " .. _retry_count .. " times", 12)
    end

    -- Basis-ID und URI speichern
    self.base_id = base_id
    self.uri = uri

    -- Neue, zufällige ID erstellen und speichern
    local current_id = base_id .. tostring(math.random(9999))
    self.id = current_id

    log(1, "Initializing MQTT client " .. uri .. " with id=" .. current_id)

    self.client = mqtt.client{
        id = current_id, -- current_id verwenden
        uri = uri,
        clean = false,
        reconnect = false, -- WICHTIG: interne Reconnect-Logik der Bibliothek deaktiviert
    }

    -- ##############################################################
    -- MQTT CALLBACKS
    -- ##############################################################
    self.client:on{
        -- Connection callback
        connect = function(connack)
            if connack.rc ~= 0 then
                log(0, "MQTT connect failed:", connack:reason_string())
                log(1, "Retrying connection via full re-init...")

                -- NEUER RECONNECT-AUFRUF
                mqtt_reader:_reinitialize_and_connect("Connect failed: " .. connack:reason_string())
                return
            end
            log(1, "Connected to MQTT broker " .. uri .. " with id=" .. current_id)
        end,

        -- Message callback (Unverändert)
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

            local decoded = util.safe_json_decode(msg.payload:lower())
            if not decoded or type(decoded) == "number" then return end

            -- Handle Tasmota-like messages
            if prefix == "tele" or prefix == "stat" then
                if not self.states[topic] then
                    self.states[topic] = {}
                end
                local s = self.states[topic]

                if data == "STATE" or data == "STATUS" or data == "RESULT" or data == "POWER" then
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
            log(0, "Attempting full re-init...")
            util.sleepTime(3 + _retry_count)

            -- NEUER RECONNECT-AUFRUF (ersetzt disconnect/connect)
            mqtt_reader:_reinitialize_and_connect("Error callback: " .. tostring(err))
        end,

        close = function()
            print("mqtt closed connection 🔌. Attempting full re-init...")
            -- Auch bei sauberem Close, das zum Problem führen kann, neu initialisieren
--            mqtt_reader:_reinitialize_and_connect("Close callback")
        end,
    }

    self.ioloop = mqtt.get_ioloop()
    self.ioloop:add(self.client)
end

-- ##############################################################
-- CONNECT LOGIC
-- ##############################################################
-- Startet den initialen Verbindungsversuch zum Broker.
function mqtt_reader:connect()
    if not self.client or not self.uri then
        log(0, "Client not initialized. Call :init(uri, id) first.")
        return false, "Client not initialized"
    end

    log(2, "Starting connection to broker using client:start_connecting()...")

    local ok, err = self.client:start_connecting()

    if not ok then
        log(0, "Initial/Immediate start_connecting attempt failed:", err)
        util.restart("Initial/Immediate start_connecting attempt failed:" .. tostring(err), 12)
    end

    return ok, err
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
            log(1, "Subscribed to", pattern, "QoS=", qos, tostring(suback))
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

function mqtt_reader:processMessages(wait_time)
    wait_time = wait_time or 0.1
    local timeout = 5
    local end_time = util.getCurrentTime() + timeout
    local got_message = false
    local inflight
    while true do
        self.got_message_in_last_iteration = false
        if self.ioloop and self.client then -- Sicherheitscheck
            self.ioloop:iteration()
        else
            break
        end

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
        if (not self.got_message_in_last_iteration and inflight == 0)
        or (util.getCurrentTime() > end_time)
        then
            break
        end

        util.sleepTime(wait_time)
    end

    if inflight > 0 then
        log(1, string.format("Warning: %d QoS2 message(s) still in flight after timeout", inflight))
    end

    return got_message
end

-- sleeps some time an process mqtt messages
function mqtt_reader:sleepAndCallMQTT(short_sleep, start_time)
    start_time = start_time or util.getCurrentTime()
    local sleep_time
    if short_sleep then
        sleep_time = short_sleep - (util.getCurrentTime() - start_time)
    else
        sleep_time = (config and config.sleep_time or 5) - (util.getCurrentTime() - start_time)
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

    -- 1. INIT (Setup)
    -- Verwenden der Basis-ID
    mqtt_reader:init("battery-control.lan", "mqtt_reader_standalone")

    -- 2. CONNECT (Start)
    local ok, err = mqtt_reader:connect()
    if not ok then
        log(0, "Initial connection failed: " .. tostring(err))
        return
    end

    -- Subscriptions und Statusabfragen
    mqtt_reader:subscribeAndAskHost("moped-charger.lan", 1)
    mqtt_reader:subscribeAndAskHost("battery-inverter.lan", 1)
    mqtt_reader:subscribeAndAskHost("balkon-inverter.lan", 2)
    mqtt_reader:subscribeAndAskHost("battery-inverter.lan", 2)

    util.sleepTime(1)

    log(1, "Waiting for MQTT messages...")

    local start_time = util.getCurrentTime()
    local max_runtime = 15 -- Läuft maximal 15 Sekunden für den Test

    while (util.getCurrentTime() - start_time) < max_runtime do
        if mqtt_reader:processMessages() then
            mqtt_reader:printStates(true)
            util.sleepTime(0.1)
        else
            util.sleepTime(1)
        end
    end

    log(1, "Max runtime reached. Disconnecting.")

    -- 3. DISCONNECT (Sauber beenden)
    mqtt_reader:disconnect()

    log(1, "Test finished.")
end


if arg and arg[0] and arg[0]:find("mqtt_reader.lua") then
    mqtt_reader:_test()
end

return mqtt_reader