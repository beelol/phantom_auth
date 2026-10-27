local function equal(expected, actual, label)
  if expected ~= actual then
    error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function truthy(value, label)
  if not value then error(label or "expected truthy value") end
end

local function load_module()
  package.loaded["main.phantom.providers"] = nil
  package.preload["main.phantom.providers"] = function() return {} end
  return dofile("module.lua")
end

local function credentials()
  return { load_guest = function() return nil end, save_guest = function() return true end }
end

local function new_instance(overrides)
  overrides = overrides or {}
  local provider_calls = 0
  local provider_callback
  local provider_options
  local bridge_sign_in_callback
  local sign_in_payload
  local sign_in_auth
  local challenge_callback
  local challenge_auth
  local callbacks = {}
  local providers = {
    is_provider_available = function() return true end,
    get_provider_token = function(_, callback, options)
      provider_calls = provider_calls + 1
      provider_callback = callback
      provider_options = options
    end,
  }
  local bridge = {
    login_guest = function() end,
    link_account = function() end,
    restore_purchases = function() end,
    sign_in = function(_, payload, auth, callback)
      sign_in_payload = payload
      sign_in_auth = auth
      bridge_sign_in_callback = callback
    end,
  }
  if overrides.challenge ~= false then
    bridge.prepare_provider_challenge = function(_, auth, callback)
      challenge_auth = auth
      challenge_callback = callback
    end
  end
  local instance = load_module().new({
    bridge = bridge,
    credentials = credentials(),
    providers = providers,
    logger = function(event, fields) table.insert(callbacks, { event = event, fields = fields }) end,
  })
  return instance, {
    provider_calls = function() return provider_calls end,
    provider_callback = function() return provider_callback end,
    provider_options = function() return provider_options end,
    challenge_callback = function() return challenge_callback end,
    challenge_auth = function() return challenge_auth end,
    sign_in_callback = function() return bridge_sign_in_callback end,
    sign_in_payload = function() return sign_in_payload end,
    sign_in_auth = function() return sign_in_auth end,
    logs = callbacks,
  }
end

do
  local auth, state = new_instance()
  local completions, result, err = 0
  auth:sign_in("apple", "guest-token", function(value, value_err)
    completions, result, err = completions + 1, value, value_err
  end)
  equal("guest-token", state.challenge_auth(), "guest auth reaches challenge")
  equal(0, state.provider_calls(), "native provider waits for challenge")
  state.challenge_callback()({ nonce = "server-nonce" }, nil)
  equal(1, state.provider_calls(), "provider called after challenge")
  equal("server-nonce", state.provider_options().nonce, "nonce reaches provider")
  state.provider_callback()({ token = "apple-token", user_id = "apple-user" }, nil)
  equal("guest-token", state.sign_in_auth(), "guest auth reaches proof submission")
  equal("apple-token", state.sign_in_payload().token, "identity token reaches bridge")
  equal("server-nonce", state.sign_in_payload().nonce, "exact nonce reaches bridge")
  state.sign_in_callback()({ token = "backend-token", record = { id = "user-1" } }, nil)
  equal(1, completions, "successful completion once")
  equal(nil, err, "successful error")
  equal("backend-token", result.token, "successful backend token")
  equal("apple-user", result._provider_user_id, "provider user id retained")

  state.challenge_callback()({ nonce = "other" }, nil)
  state.provider_callback()({ token = "other" }, nil)
  state.sign_in_callback()({ token = "other" }, nil)
  equal(1, completions, "duplicate callbacks ignored")
  equal(1, state.provider_calls(), "duplicate challenge cannot reopen provider")
end

for _, case in ipairs({
  { label = "challenge error", challenge = nil, challenge_err = { code = "offline" }, expected = "offline" },
  { label = "missing nonce", challenge = {}, expected = "Provider challenge returned no nonce" },
  { label = "non-string nonce", challenge = { nonce = 42 }, expected = "Provider challenge returned no nonce" },
  { label = "empty nonce", challenge = { nonce = "" }, expected = "Provider challenge returned no nonce" },
}) do
  local auth, state = new_instance()
  local completions, err = 0
  auth:sign_in("apple", "guest-token", function(_, value_err)
    completions, err = completions + 1, value_err
  end)
  state.challenge_callback()(case.challenge, case.challenge_err)
  equal(1, completions, case.label .. " completes")
  equal(0, state.provider_calls(), case.label .. " blocks native provider")
  if type(case.expected) == "string" and type(err) == "table" then
    equal(case.expected, err.code, case.label .. " error code")
  else
    equal(case.expected, err, case.label .. " error")
  end
end

do
  local auth, state = new_instance()
  local completions, err = 0
  auth:sign_in("apple", nil, function(_, value_err) completions, err = completions + 1, value_err end)
  state.challenge_callback()({ nonce = "server-nonce" }, nil)
  state.provider_callback()(nil, "cancelled")
  equal(1, completions, "provider cancellation completes")
  equal("cancelled", err, "provider cancellation preserved")
  equal(nil, state.sign_in_payload(), "provider cancellation blocks backend sign-in")
end

do
  local auth, state = new_instance({ challenge = false })
  auth:sign_in("apple", "legacy-auth", function() end)
  equal(1, state.provider_calls(), "legacy bridge calls provider directly")
  equal(nil, state.provider_options(), "legacy bridge omits nonce options")
  state.provider_callback()({ token = "legacy-token" }, nil)
  equal("legacy-token", state.sign_in_payload().token, "legacy token reaches bridge")
  equal(nil, state.sign_in_payload().nonce, "legacy bridge does not invent nonce")
end

do
  local auth, state = new_instance()
  auth:sign_in("google", "registered-auth", function() end)
  equal(1, state.provider_calls(), "non-Apple provider bypasses Apple challenge")
  equal(nil, state.challenge_callback(), "non-Apple challenge not requested")
  equal(nil, state.provider_options(), "non-Apple provider options unchanged")
end

do
  local calls = {}
  _G.siwa = {
    is_supported = function() return true end,
    authenticate = function(first, second)
      table.insert(calls, { first = first, second = second })
      return true
    end,
  }
  local providers = dofile("providers.lua")
  providers.get_provider_token("apple", function() end, { nonce = "native-nonce" })
  equal("native-nonce", calls[1].first, "native SIWA receives nonce")
  truthy(type(calls[1].second) == "function", "native nonce callback")
  providers.get_provider_token("apple", function() end)
  truthy(type(calls[2].first) == "function", "legacy SIWA callback form")
  equal(nil, calls[2].second, "legacy SIWA has one argument")
  _G.siwa = nil
end

do
  _G.siwa = {
    is_supported = function() return true end,
    authenticate = function() return false end,
  }
  local providers = dofile("providers.lua")
  local completions, err = 0
  providers.get_provider_token("apple", function(_, value_err)
    completions, err = completions + 1, value_err
  end, { nonce = "native-nonce" })
  equal(1, completions, "native start refusal completes")
  equal("Apple Auth Failed: request did not start", err, "native start refusal error")
  _G.siwa = nil
end

print("apple_challenge_test: ok")
