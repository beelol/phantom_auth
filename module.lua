local default_identity = require "main.phantom.identity"
local default_providers = require "main.phantom.providers"

local Phantom = {}

local function is_account_linked_error(err)
  local s = tostring(err)
  return s:find("AccountLinked") ~= nil or s:find("403") ~= nil
end

local function resolve_options(opts_or_url)
  if type(opts_or_url) == "table" then
    return opts_or_url
  end

  return {
    backend_url = opts_or_url
  }
end

local function make_instance(opts_or_url)
  local opts = resolve_options(opts_or_url)
  assert(opts.bridge, "phantom.module requires opts.bridge (no default project bridge)")

  local self = {
    bridge = opts.bridge,
    identity = opts.identity or default_identity,
    providers = opts.providers or default_providers,
    gamecenter_state = {
      status = "not_attempted",
      error = nil,
    },
  }

  if opts.backend_url and self.bridge and self.bridge.init then
    self.bridge.init(opts.backend_url)
  end

  function self:auto_sign_in_anon(callback)
    local uuid = self.identity.get_uuid()
    if not uuid then
      uuid = self.identity.generate_uuid()
      self.identity.save_uuid(uuid)
      print("Login: Generated New Guest UUID: " .. uuid)
    else
      print("Login: Using Existing Guest UUID: " .. uuid)
    end

    self.bridge.login_guest(uuid, function(result, err)
      if err then
        print("Login: Guest Login Failed: " .. tostring(err))

        if is_account_linked_error(err) then
          print("LOGIN: Account Linked! Please Sign In.")
          callback(nil, "AccountLinked")
        else
          callback(nil, err)
        end
      else
        print("Login: Guest Login Success")
        callback(result, nil)
      end
    end)
  end

  -- Backward compatibility alias.
  function self:login_guest(callback)
    self:auto_sign_in_anon(callback)
  end

  function self:link_account(provider, current_auth_token, callback)
    print("Login: Linking Account with " .. provider)

    self.providers.get_provider_token(provider, function(id_data, err)
      if err then
        print("Login: Failed to get provider token: " .. tostring(err))
        callback(nil, err)
        return
      end

      print("Login: Provider token acquired for " .. provider)

      self.bridge.link_account(provider, id_data, current_auth_token, function(result, link_err)
        if link_err then
          print("Login: Link Account Failed: " .. tostring(link_err))
          callback(nil, link_err)
        else
          print("Login: Link Account Success")
          callback(result, nil)
        end
      end)
    end)
  end

  function self:try_link_gamecenter_silent(current_auth_token, callback)
    self.gamecenter_state.status = "pending"
    self.gamecenter_state.error = nil

    if not self.providers.is_provider_available("gamecenter") then
      self.gamecenter_state.status = "failed"
      self.gamecenter_state.error = "Game Center unavailable"
      callback(nil, self.gamecenter_state.error)
      return
    end

    self:link_account("gamecenter", current_auth_token, function(result, err)
      if err then
        self.gamecenter_state.status = "failed"
        self.gamecenter_state.error = err
      else
        self.gamecenter_state.status = "success"
        self.gamecenter_state.error = nil
      end
      callback(result, err)
    end)
  end

  function self:get_gamecenter_state()
    local provider_gc = self.providers.get_gamecenter_debug_state and self.providers.get_gamecenter_debug_state() or nil
    if provider_gc then
      return {
        status = provider_gc.status,
        error = provider_gc.last_error,
        initialized = provider_gc.initialized
      }
    end

    return {
      status = self.gamecenter_state.status,
      error = self.gamecenter_state.error
    }
  end

  function self:restore_purchases(receipt_data, callback)
    self.bridge.restore_purchases(receipt_data, function(result, err)
      if err then
        print("Login: Restore Failed: " .. tostring(err))
        callback(nil, err)
      else
        print("Login: Restore Success (Account Switched?)")
        callback(result, nil)
      end
    end)
  end

  return self
end

local default_instance = nil
local default_init_opts = nil

local function require_init()
  assert(default_instance, "phantom.module is not initialized; call Phantom.init({ bridge = ... }) first")
  return default_instance
end

local function assert_same_init_opts(opts)
  if not default_init_opts then
    return
  end

  assert(opts and opts.bridge, "phantom.module requires opts.bridge")

  assert(default_init_opts.bridge == opts.bridge,
    "phantom.module already initialized with a different bridge")

  local current_backend_url = default_init_opts.backend_url
  local requested_backend_url = opts.backend_url
  if current_backend_url ~= requested_backend_url then
    assert(false, "phantom.module already initialized with a different backend_url")
  end
end

function Phantom.new(opts_or_url)
  return make_instance(opts_or_url)
end

-- Singleton-style API retained for compatibility.
function Phantom.init(opts_or_url)
  local opts = resolve_options(opts_or_url)
  default_instance = make_instance(opts)
  default_init_opts = {
    bridge = opts.bridge,
    backend_url = opts.backend_url
  }
  return default_instance
end

function Phantom.ensure_init(opts_or_url)
  local opts = resolve_options(opts_or_url)
  if default_instance then
    assert_same_init_opts(opts)
    return default_instance
  end
  return Phantom.init(opts)
end

function Phantom.auto_sign_in_anon(callback)
  return require_init():auto_sign_in_anon(callback)
end

function Phantom.login_guest(callback)
  return require_init():login_guest(callback)
end

function Phantom.link_account(provider, current_auth_token, callback)
  return require_init():link_account(provider, current_auth_token, callback)
end

function Phantom.try_link_gamecenter_silent(current_auth_token, callback)
  return require_init():try_link_gamecenter_silent(current_auth_token, callback)
end

function Phantom.get_gamecenter_state()
  return require_init():get_gamecenter_state()
end

function Phantom.restore_purchases(receipt_data, callback)
  return require_init():restore_purchases(receipt_data, callback)
end

return Phantom
