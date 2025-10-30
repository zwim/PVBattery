-- dnshelper.lua
-- ultra-robuster DNS-Resolver für LuaSocket-basierte Anwendungen

local socket = require("socket")

local M = {}

-- === Einstellungen ===
M.retry_count     = 3       -- Anzahl Wiederholungen bei Fehler
M.retry_delay     = 0.3     -- Sekunden zwischen Wiederholungen
M.cache_ttl       = 3600    -- Sekunden, wie lange Cache gültig bleibt
M.debug           = false   -- true = Debug-Ausgaben

-- === interner Cache ===
local cache = {}

local function log(...)
  if M.debug then
    print("[dnshelper]", ...)
  end
end

-- === Low-Level Auflösung mit socket.dns.toip ===
local function resolve_socket(host)
  for i = 1, M.retry_count do
    local ip, err = socket.dns.toip(host)
    if ip then
      log(string.format("socket.dns.toip('%s') → %s", host, ip))
      return ip
    end
    log(string.format("socket.dns.toip('%s') Versuch %d fehlgeschlagen: %s", host, i, tostring(err)))
    socket.sleep(M.retry_delay)
  end
  return nil, "socket.dns.toip fehlgeschlagen"
end

-- === System-Fallback (getent, nslookup, dig) ===
local function resolve_system(host)
  local cmds = {
    "getent hosts " .. host .. " 2>/dev/null",
    "dig +short " .. host .. " 2>/dev/null"
--    "nslookup " .. host .. " 2>/dev/null",
  }
  for _, cmd in ipairs(cmds) do
    local f = io.popen(cmd)
    if f then
      local line = f:read("*l")
      f:close()
      if line then
        local ip = line:match("(%d+%.%d+%.%d+%.%d+)")
        if ip then
          log(string.format("%s → %s", cmd, ip))
          return ip
        end
      end
    end
  end
  return nil, "system resolver fehlgeschlagen"
end

-- === Hauptfunktion mit Cache, Retry & Fallback ===
function M.toip(host)
  host = host:lower()
  if host:find("_") then
      log("String contains an underscore '_', this is not allowed")
  end

  local now = os.time()

  -- 1. Cache prüfen
  local entry = cache[host]
  if entry and (now - entry.time) < M.cache_ttl then
    log(string.format("Cache hit für %s → %s", host, entry.ip))
    return entry.ip
  end

  -- 2. Auflösen via socket.dns
  local ip, err = resolve_socket(host)
  if not ip then
    -- 3. Fallback: system call
    ip, err = resolve_system(host)
  end

  -- 4. Ergebnis behandeln
  if ip then
    cache[host] = { ip = ip, time = now }
    return ip
  else
    -- Wenn alter Cache vorhanden: als "best guess" zurückgeben
    if entry then
      log(string.format("DNS-Fehler (%s), verwende Cache → %s", tostring(err), entry.ip))
      return entry.ip
    end
    log(string.format("DNS komplett fehlgeschlagen: %s", tostring(err)))
    return nil, err
  end
end

-- === Hilfsfunktion: Cache leeren ===
function M.clear_cache()
  cache = {}
  log("Cache geleert")
end

return M
