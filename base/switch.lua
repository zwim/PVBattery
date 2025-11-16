
local mqtt_reader = require("base/mqtt_reader")
local util = require("base/util")

local http = require("socket.http")
http.TIMEOUT=5

local Switch = {
    socket = nil, -- tcp.socket, will be filled automatically
    host = nil,
    port = 80,
    max_power = 0,
    topic_name = nil,
}

function Switch:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Switch:new(o)
    o = self:extend(o)
    if o.host then
        o.host = o.host:lower()
    end
    o.topic_name = o.host:match("^(.*)%.")
    if o.init then
        o:init()
    end
    mqtt_reader:subscribeAndAskHost(o.host, 2)
    return o
end

function Switch:init()
    if not self.max_power then
        self.max_power = 0
    end
--    self.topic_name = self.host:match("^(.*)%.")
end

function Switch:updateState(timeout)
    if not self.host or self.host == "" then
        return
    end

    mqtt_reader:askHost(self.host, 2)

    if timeout then
        mqtt_reader:sleepAndCallMQTT(timeout, nil)
    end
end

function Switch:getEnergyTotal()
    mqtt_reader:processMessages()

    local state = mqtt_reader.states[self.topic_name]
    if not state or not state.total then
        mqtt_reader:askHost(self.host, 2)
        mqtt_reader:sleepAndCallMQTT(4, nil)
        state = mqtt_reader.states[self.topic_name]
    end

    local Energy = state and state.total or (0/0)
    return Energy
end

function Switch:getEnergyToday()
    mqtt_reader:processMessages()

    local state = mqtt_reader.states[self.topic_name]
    if not state or not state.today then
        mqtt_reader:askHost(self.host, 2)
        mqtt_reader:sleepAndCallMQTT(4, nil)
        state = mqtt_reader.states[self.topic_name]
    end

    local Energy = state and state.today or (0/0)
    return Energy
end

function Switch:getEnergyYesterday()
    mqtt_reader:processMessages()

    local state = mqtt_reader.states[self.topic_name]
    if not state or not state.yesterday then
        mqtt_reader:askHost(self.host, 2)
        mqtt_reader:sleepAndCallMQTT(4, nil)
        state = mqtt_reader.states[self.topic_name]
    end

    local Energy = state and state.yesterday or (0/0)
    return Energy
end

function Switch:getPower()
    mqtt_reader:processMessages()

    local state = mqtt_reader.states[self.topic_name]
    if not state or not state.power then
        mqtt_reader:askHost(self.host, 2)
        mqtt_reader:sleepAndCallMQTT(4, nil)
        state = mqtt_reader.states[self.topic_name]
    end

    if not state then
        return (0/0)
    end

    local power = state.power

    if power and power > 20 then
        local weight = 0.2
        self.max_power = (1-weight)*self.max_power + weight*power
    end
    return power or 0
end

function Switch:getMaxPower()
    return self.max_power
end

function Switch:getPowerState()
    mqtt_reader:processMessages()

    local state = mqtt_reader.states[self.topic_name]
    if not state or not state.switch1 then
        mqtt_reader:askHost(self.host, 2)
        mqtt_reader:sleepAndCallMQTT(4, nil)
        state = mqtt_reader.states[self.topic_name]
    end

    if not state or not state.switch1 then
        return ""
    end

    local power_state = state.switch1

    power_state = power_state:lower()

    if power_state == 0 or power_state == "0" or power_state:find("^0.") then
        return "off"
    elseif power_state == 1 or power_state == "1" or power_state:find("^1.") then
        return "on"
    else
        return power_state
    end
end

--- toggles switch:
-- on: 0 ... off
-- on: 1 ... on
-- on: 2 ... toggle
function Switch:toggle(on)
    if not self.host then return end

    if not on then
        on = "2"
    end
    local url = string.format("http://%s/cm?cmnd=Power0%%20%s", self.host, tostring(on))
    local _ = http.request(url)
    util.sleepTime(0.2)
    mqtt_reader:processMessages()
end

function Switch:getStatus()
    if not self.host or self.host == "" then return end

    local url = string.format("http://%s/cm?cmnd=Status0%%20%s", self.host, tostring(0))
    local _ = http.request(url)
    util.sleepTime(0.2)
    mqtt_reader:processMessages()
end

return Switch
