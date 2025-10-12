
-- local config = require("configuration")
-- local json = require("dkjson")
local mqtt_reader = require("mqtt_reader")
local util = require("util")

local http = require("socket.http")
http.TIMEOUT=5

local Switch = {
    socket = nil, -- tcp.socket, will be filled automatically
    host = nil,
    port = 80,
    max_power = 0,
}

function Switch:extend(subclass_prototype)
    local o = subclass_prototype or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Switch:new(o)
    o = self:extend(o)
    if o.init then
        o:init()
    end
    o.host = o.host:lower()
    mqtt_reader:askHost(o.host)
    return o
end

function Switch:init()
    if not self.max_power then
        self.max_power = 0
    end
end

function Switch:getDataAge()
    local name = self.host:match("^(.*)%.")
    local state = mqtt_reader.states[name]
    if state and state.time then
        return util.getCurrentTime() - state.time
    end
    return 0
end

function Switch:updateStatus()
    if not self.host then
        return false
    end

    local name = self.host:match("^(.*)%.")
    mqtt_reader.askHost(name)
    mqtt_reader:processMessages()
end

function Switch:getEnergyTotal()
    mqtt_reader:processMessages()
    local name = self.host:match("^(.*)%.")
    local state = mqtt_reader.states[name]
    if not state then
        return (0/0)
    end

    local Energy = state.Total or (0/0)
    return Energy
end

function Switch:getEnergyToday()
    local name = self.host:match("^(.*)%.")
    local state = mqtt_reader.states[name]
    if not state then
        return (0/0)
    end

    local Energy = state.Today or (0/0)
    return Energy
end

function Switch:getEnergyYesterday()
    mqtt_reader:processMessages()

    local name = self.host:match("^(.*)%.")
    local state = mqtt_reader.states[name]
    if not state then
        return (0/0)
    end

    local Energy = state.Yesterday or (0/0)
    return Energy
end

function Switch:getPower()
    mqtt_reader:processMessages()

    local name = self.host:match("^(.*)%.")
    local state = mqtt_reader.states[name]
    if not state then
        return (0/0)
    end

    local power = state.power
    local power_state = self:getPowerState()

    if not power or power_state == "" or power_state == "off" then
       return 0
    end

    if power > 20 then
        local weight = 0.2
        self.max_power = (1-weight)*self.max_power + weight*power
    end
    return power or (0/0)
end

function Switch:getMaxPower()
    return self.max_power
end

function Switch:getPowerState()
    mqtt_reader:processMessages()

    local name = self.host:match("^(.*)%.")
    local state = mqtt_reader.states[name]
    if not state then
        return ""
    end

    local power_state = state.switch1
    if not power_state then
        return ""
    end

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

return Switch
