local default_providers = require "main.phantom.providers"

local Phantom = {}

local function default_logger(event, fields)
  local parts = { "[phantom-auth]", "event=" .. tostring(event) }
  local keys = {}
  for key in pairs(fields or {}) do
    table.insert(keys, key)
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    table.insert(parts, tostring(key) .. "=" .. tostring(fields[key]))
  end
  print(table.concat(parts, " "))
end

local function error_code(err)
  if type(err) ~= "table" then
    return tostring(err or "unknown")
  end
  if type(err.error) == "table" and err.error.code then
    return tostring(err.error.code)
  end
  if type(err.data) == "table" and type(err.data.error) == "table" and err.data.error.code then
    return tostring(err.data.error.code)
  end
  if type(err.data) == "table" and type(err.data.data) == "table"
    and type(err.data.data.error) == "table" and err.data.data.error.code then
    return tostring(err.data.data.error.code)
  end
  return tostring(err.code or err.status or err.message or "unknown")
end

local function is_account_linked_error(err)
  return error_code(err) == "account_linked" or tostring(err):find("AccountLinked") ~= nil
end

local function linked_account_provider(err)
  if type(err) ~= "table" then
    return nil
  end
  if type(err.data) == "table" then
    if type(err.data.provider) == "string" then
      return err.data.provider
    end
    if type(err.data.data) == "table" and type(err.data.data.provider) == "string" then
      return err.data.data.provider
    end
  end
  return nil
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
  assert(opts.credentials, "phantom.module requires opts.credentials")

  local self = {
    bridge = opts.bridge,
    credentials = opts.credentials,
    providers = opts.providers or default_providers,
    logger = opts.logger or default_logger,
    gamecenter_state = {
      status = "not_attempted",
      error = nil,
    },
  }

  if self.providers.set_logger then
    self.providers.set_logger(self.logger)
  end

  function self:log(event, fields)
    self.logger(event, fields or {})
  end

  if opts.backend_url and self.bridge and self.bridge.init then
    self.bridge.init(opts.backend_url)
  end

  function self:auto_sign_in_anon(callback)
    self:log("auth.guest.started")
    local credential, load_err = self.credentials.load_guest()
    if load_err then
      self:log("auth.storage.read_failed", { error_code = error_code(load_err) })
      callback(nil, load_err)
      return
    end

    self.bridge.login_guest(credential, function(result, err)
      if err then
        if is_account_linked_error(err) then
          self:log("auth.guest.account_linked", { error_code = "account_linked" })
          callback(nil, {
            code = "account_linked",
            provider = linked_account_provider(err),
            message = "AccountLinked",
          })
        else
          self:log("auth.guest.failed", { error_code = error_code(err) })
          callback(nil, err)
        end
      else
        if not credential then
          local issued = result and result.meta and result.meta.guest_credential
          if type(issued) ~= "string" or issued == "" then
            self:log("auth.guest.failed", { error_code = "guest_credential_missing" })
            callback(nil, "Backend created a guest without returning its credential")
            return
          end
          local saved, save_err = self.credentials.save_guest(issued)
          if not saved then
            self:log("auth.storage.write_failed", { error_code = error_code(save_err) })
            callback(nil, save_err or "Failed to save guest credential")
            return
          end
          result.meta.guest_credential = nil
          if next(result.meta) == nil then
            result.meta = nil
          end
          self:log("auth.guest.credential_saved")
        end
        self:log("auth.guest.succeeded", {
          user_id = result and result.record and result.record.id or "unknown",
          restored = credential ~= nil,
        })
        callback(result, nil, {
          restored = credential ~= nil,
        })
      end
    end)
  end

  -- Backward compatibility alias.
  function self:login_guest(callback)
    self:auto_sign_in_anon(callback)
  end

  function self:link_account(provider, current_auth_token, callback)
    self:log("auth.platform_link.started", { provider = provider })

    self.providers.get_provider_token(provider, function(id_data, err)
      if err then
        self:log("auth.platform_link.failed", { provider = provider, error_code = error_code(err) })
        callback(nil, err)
        return
      end

      self.bridge.link_account(provider, id_data, current_auth_token, function(result, link_err)
        if link_err then
          self:log("auth.platform_link.failed", { provider = provider, error_code = error_code(link_err) })
          callback(nil, link_err)
        else
          self:log("auth.platform_link.succeeded", { provider = provider })
          callback(result, nil)
        end
      end)
    end)
  end

  function self:sign_in(provider, current_auth_token, callback)
    self:log("auth.provider.started", { provider = provider })
    if not self.providers.is_provider_available(provider) then
      local err = "Provider unavailable: " .. tostring(provider)
      self:log("auth.provider.failed", { provider = provider, error_code = "provider_unavailable" })
      callback(nil, err)
      return
    end

    self.providers.get_provider_token(provider, function(id_data, token_err)
      if token_err then
        self:log("auth.provider.failed", { provider = provider, error_code = error_code(token_err) })
        callback(nil, token_err)
        return
      end

      self:log("auth.provider.token_received", { provider = provider })
      self.bridge.sign_in(provider, id_data, current_auth_token, function(result, sign_in_err)
        if sign_in_err then
          self:log("auth.provider.failed", { provider = provider, error_code = error_code(sign_in_err) })
          callback(nil, sign_in_err)
          return
        end

        self:log("auth.provider.succeeded", {
          provider = provider,
          user_id = result and result.record and result.record.id or "unknown"
        })
        if type(result) == "table" and type(id_data) == "table" then
          result._provider_user_id = id_data.user_id
        end
        callback(result, nil)
      end)
    end)
  end

  function self:get_credential_state(provider, user_id, callback)
    if not self.providers.get_credential_state then
      callback(nil, "Credential-state checks unavailable")
      return
    end
    self.providers.get_credential_state(provider, user_id, callback)
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
        self:log("auth.restore.failed", { error_code = error_code(err) })
        callback(nil, err)
      else
        self:log("auth.restore.succeeded")
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
  assert(opts.credentials, "phantom.module requires opts.credentials")

  assert(default_init_opts.bridge == opts.bridge,
    "phantom.module already initialized with a different bridge")

  assert(default_init_opts.credentials == opts.credentials,
    "phantom.module already initialized with different credentials")

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
    credentials = opts.credentials,
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

function Phantom.sign_in(provider, current_auth_token, callback)
  return require_init():sign_in(provider, current_auth_token, callback)
end

function Phantom.is_provider_available(provider)
  local instance = require_init()
  return instance.providers.is_provider_available(provider)
end

function Phantom.get_credential_state(provider, user_id, callback)
  return require_init():get_credential_state(provider, user_id, callback)
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
