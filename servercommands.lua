--- This function checks if there is a new command for PVBattery
-- Commands are stored in the file config.command_file_name

local util = require("util")


return function(self, config)
    local file_name = config.command_file_name or "/tmp/PVCommands"

    local file = io.open(file_name, "r")

    if not file then
        return
    end

    util:log("Opening command file: " .. file_name)

    local commands={}
    while true do
        local command = file:read("*line")
        if not command then
            break
        end
        table.insert(commands, command)
    end
    file:close()

    for i = 1, #commands do
        local command = commands[i]
        local action, cfg_file

        if command:find("^bms para[a-z]* backup +") then
            action = "backup"
            cfg_file = command:gsub("^bms para[a-z]* backup +", "")
            for _, BMS in pairs(self.BMS) do
                BMS:getParameters()
            end

        elseif command:find("^bms para[a-z]* restore +") then
            action = "restore"
            cfg_file = command:gsub("^bms para[a-z]* restore +", "")
        elseif command:find("^bms para[a-z]* print *") then
            action = "print"
        end
        print(action, cfg_file)
    end

    print(config.command_file_name)



end