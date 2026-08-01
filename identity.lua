local M = {}

-- Helper to generic get/set
function M.get(key)
  local path = sys.get_save_file("phantom_auth", key)
  local data = sys.load(path)
  return data.value
end

function M.set(key, value)
  local path = sys.get_save_file("phantom_auth", key)
  sys.save(path, { value = value })
end

function M.delete(key)
  local path = sys.get_save_file("phantom_auth", key)
  sys.save(path, {}) -- Clear
end

-- Specific Helper for UUID
local UUID_KEY = "phantom_auth_guest_uuid"

function M.get_uuid()
  -- 1. Try System ID (IDFV on iOS, Android ID on Android)
  local info = sys.get_sys_info()
  if info.device_ident and info.device_ident ~= "unknown" and info.device_ident ~= "" then
    return info.device_ident
  end

  -- 2. Fallback to stored UUID
  return M.get(UUID_KEY)
end

function M.save_uuid(uuid)
  M.set(UUID_KEY, uuid)
end

function M.delete_uuid()
  M.delete(UUID_KEY)
end

-- Helper to generate a UUID v4
function M.generate_uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return string.gsub(template, '[xy]', function(c)
    local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format('%x', v)
  end)
end

return M
