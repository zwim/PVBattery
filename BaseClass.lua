-- Base Class for all other classes
-- contains logging

-- If a config.loglevel exist, the minimum of this and the class loglevel
-- is used

-- luacheck: globals config
local BaseClass = {
    __name = "BaseClass",
    -- ##############################################################
    -- CONFIGURATION
    -- ##############################################################
    --levels: 0 = silent, 1 = info, 2 = debug, 3 = verbose
    __loglevel = 3,
}

function BaseClass:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BaseClass:new(o)
    o = self:extend(o)
    if o.init then
        o:init()
    end
    return o
end

function BaseClass:init()
    return self
end

function BaseClass:log(level, ...)
    local loglevel = self.__loglevel or 3
    if config and config.loglevel then
        loglevel = math.min(loglevel, config.loglevel)
    end
    if level <= loglevel then
        print(os.date("%Y/%m/%d-%H:%M:%S ["..(getmetatable(self).__name or "???").."]"), ...)
    end
end

function BaseClass.listValues(obj)
    if obj == nil then return "nil" end
    local result = {}
    for i, v in pairs(obj) do
        table.insert(result, tostring(i) .. ":" .. tostring(v))
    end
    return table.concat(result, ", ")
end

return BaseClass
