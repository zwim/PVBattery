-- Test for BTRFS compression




local function compress(name)

    -- compress log file
    local handle = io.popen("stat -f -c %T " .. name)
    local result = handle:read("*a")
    handle:close()
    if result:find("btrfs") then
        os.execute("date; btrfs filesystem defragment -r -v -czstd " .. name)
    else
        print("todo log file compression") -- todo
    end
end

local function generate_uncompressed_file(name, data)
    local log_file = io.open(name , "a")
    if not log_file then
        print("ERROR opening log file:", name, log_file)
        return
    end

    log_file:write(data)
    log_file:close()
end

local testfile = "/tmp/test/xxx"


local data = ("1234"):rep(100)

for _ = 1,100 do
    os.execute("ls -al " .. testfile .. "; compsize " .. testfile)
    generate_uncompressed_file(testfile, data)
    os.execute("sleep 0.2")
end

compress(testfile)