
local config = require("configuration")
local json = require ("dkjson")
local socket = require("socket")
local util = require("util")

local http = require("socket.http")
http.TIMEOUT=5

local Switch = {
    socket = nil, -- tcp.socket, will be filled automatically
    host = nil,
    timeOfLastRequiredData = 0, -- no data requiered yet
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
    return o
end

function Switch:init()
    if not self.timeOfLastRequiredData then
        self.timeOfLastRequiredData = 0
    end
    if not self.max_power then
        self.max_power = 0
    end
end

function Switch:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function Switch:setDataAge()
    self.timeOfLastRequiredData = util.getCurrentTime()
end

function Switch:clearDataAge()
    self.timeOfLastRequiredData = 0
    self.decoded = nil
end

-- Use this method for receivinge values from one switch
function Switch:_getStatus()
    if not self.host then
        return false
    end

    if self:getDataAge() < config.update_interval and self.decoded then
        return true
    end

    local url = string.format("http://%s/cm?cmnd=status%%200", self.host)
    local body, code = http.request(url)
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        self.decoded = nil
        return false
    end
    self.decoded = body and json.decode(body) or {}

    self:setDataAge()
    return true
end

local READ_DATA_SIZE = 2048*2
-- Use this method to collect values from all switches with coroutines
function Switch:_getStatus_coroutine()
    if not self.host or self.host == "" then
        return false
    end

    if self:getDataAge() < config.update_interval and self.decoded then
        return true
    end

    local ok, err
    self.socket = socket.tcp()
    self.socket:settimeout(2)
    self.socket:setoption("keepalive", true)
    ok, err = self.socket:connect(self.host, 80)
    if not ok then
        util:log("Error opening connection to", self.host, ":", err)
        print("Error opening connection to", self.host, ":", err)
        self.socket = nil
        return false
    end

    local path = "/cm?cmnd=status0"
    self.socket:send("GET " .. path .. " HTTP/1.0\r\n\r\n")
    self.socket:settimeout(0)   -- do not block

    local body = ""
    while true do
        local s, status, partial = self.socket:receive(READ_DATA_SIZE)
        if s and s ~= "" then
            body = body .. s
        end
        if partial and partial ~= "" then
            body = body .. partial
        end

        if #body >= READ_DATA_SIZE or status == "closed" then
            self.socket:close()
            self.socket = nil
            break
        elseif status == "timeout" then
            coroutine.yield(self.socket)
        end
    end

    local header_end = body:find("\r\n\r\n", 1, true)
    if header_end then
        body = body:sub(header_end + 4)
    end
    self.decoded = body and json.decode(body) or {}

    self:setDataAge()
    return true
end


function Switch:getEnergyTotal()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Total or (0/0)
    return Energy
end

function Switch:getEnergyToday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Today or (0/0)
    return Energy
end

function Switch:getEnergyYesterday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Yesterday or (0/0)
    return Energy
end

function Switch:getPower()
    if not self:_getStatus() then
        return (0/0)
    end

    local Power = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Power or (0/0)

    if Power and Power > 20 then
        local weight = 0.2
        self.max_power = (1-weight)*self.max_power + weight*Power
    end
    return Power
end

function Switch:getMaxPower()
    return self.max_power
end

function Switch:getPowerState()
    if not self:_getStatus() then
        return ""
    end

    if self:getDataAge() > config.update_interval then
        self:getPower() -- update max_power
    end

    local power_state = self.decoded and self.decoded.Status and self.decoded.Status.Power or ""
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
    _ = http.request(url)
    self:clearDataAge()
--[[
    local body, code = http.request(url)
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        return
    end
    local decoded = body and json.decode(body) or {}
    local Result =
    if decoded then
        Result = decoded.power
    end

    self:setDataAge()
    return Result
]]
end

return Switch
