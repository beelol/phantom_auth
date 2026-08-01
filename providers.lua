local M = {}
local logger = function() end
local gc = {
  initialized = false,
  status = "idle", -- idle | pending | needs_ui | authenticated | error
  player_id = nil,
  player_alias = nil,
  player_is_underage = nil,
  last_error = nil,
  pending_callback = nil,
  request_id = 0
}

local function emit(event, fields)
  logger(event, fields or {})
end

function M.set_logger(value)
  logger = value or function() end
end

local function gc_complete_with_error(err)
  gc.status = "error"
  gc.last_error = err
  if gc.pending_callback then
    local cb = gc.pending_callback
    gc.pending_callback = nil
    cb(nil, err)
  end
end

local function gc_complete_with_success()
  gc.status = "authenticated"
  gc.last_error = nil
  if gc.pending_callback then
    local cb = gc.pending_callback
    gc.pending_callback = nil
    cb({
      token = gc.player_id,
      payload = {
        local_player_id = gc.player_id,
        local_player_alias = gc.player_alias,
        local_player_is_underage = gc.player_is_underage,
        auth_source = "gamecenter"
      }
    }, nil)
  end
end

function M.is_provider_available(provider)
  if provider == "apple" then
    return siwa ~= nil and siwa.is_supported ~= nil and siwa.is_supported()
  elseif provider == "google" then
    return false
  elseif provider == "gamecenter" then
    return gamekit ~= nil
  end
  return false
end

function M.get_gamecenter_debug_state()
  return {
    initialized = gc.initialized,
    status = gc.status,
    last_error = gc.last_error,
    player_id = gc.player_id
  }
end

function M.get_provider_token(provider, callback)
  if provider == "apple" then
    if not M.is_provider_available("apple") then
      callback(nil, "SIWA extension missing")
      return
    end

    siwa.authenticate(function(self, data)
      if not data then
        callback(nil, "Apple Auth Failed: no response data")
        return
      end

      if data.result == "SUCCESS" and data.identity_token then
        callback({ token = data.identity_token, user_id = data.user_id }, nil)
        return
      end

      callback(nil, "Apple Auth Failed: " .. tostring(data.message or data.result))
    end)
  elseif provider == "google" then
    callback(nil, "Google account sign-in is disabled until server token verification is configured")
  elseif provider == "gamecenter" then
    if not gamekit then
      callback(nil, "GameKit extension missing")
      return
    end

    -- If we already have an authenticated local player, return it immediately.
    if gc.status == "authenticated" and gc.player_id then
      gc.pending_callback = callback
      gc_complete_with_success()
      return
    end

    -- First attempt should be silent only (register auth handler once).
    if not gc.initialized then
      gc.pending_callback = callback
      gc.initialized = true
      gc.status = "pending"
      gc.request_id = gc.request_id + 1
      local request_id = gc.request_id

      -- extension-gamekit docs: callback receives (self, event)
      gamekit.gc_signin(function(self, event)
        if not event or not event.type then
          gc_complete_with_error("Game Center sign-in failed: invalid callback event")
          return
        end

        if event.type == "authenticated" and event.localPlayerID then
          gc.player_id = event.localPlayerID
          gc.player_alias = event.localPlayerAlias
          gc.player_is_underage = event.localPlayerIsUnderage
          gc_complete_with_success()
        elseif event.type == "showSignInUI" then
          gc.status = "needs_ui"
          gc.last_error = "Game Center requires user sign-in UI"
          -- Do not auto-show UI. The next button press should explicitly prompt.
          if gc.pending_callback then
            local cb = gc.pending_callback
            gc.pending_callback = nil
            cb(nil, gc.last_error)
          end
        elseif event.type == "error" then
          gc_complete_with_error("Game Center error: " .. tostring(event.errorCode) .. " " .. tostring(event.description))
        else
          gc_complete_with_error("Game Center unsupported event: " .. tostring(event.type))
        end
      end)

      -- Some iOS states never deliver a callback (misconfigured capability/account state).
      -- Avoid indefinite pending state so UI can recover.
      timer.delay(3, false, function()
        if gc.status == "pending" and gc.request_id == request_id then
          gc_complete_with_error("Game Center sign-in timed out waiting for callback")
        end
      end)
      return
    end

    if gc.status == "pending" then
      callback(nil, "Game Center sign-in pending; wait for callback")
      return
    end

    -- If silent told us UI is needed, explicitly present it on user action.
    if gc.status == "needs_ui" then
      gc.pending_callback = callback
      gc.status = "pending"
      gamekit.gc_show_signin("UI")
      return
    end

    callback(nil, gc.last_error or "Game Center unavailable in current state")
  else
    callback(nil, "Unknown provider: " .. tostring(provider))
  end
end

function M.get_credential_state(provider, user_id, callback)
  if provider ~= "apple" then
    callback(nil, "Credential-state checks unsupported for provider: " .. tostring(provider))
    return
  end
  if not M.is_provider_available("apple") then
    callback(nil, "SIWA extension missing")
    return
  end

  local started = siwa.get_credential_state(user_id, function(self, data)
    if not data or data.result ~= "SUCCESS" then
      callback(nil, data and data.message or "Apple credential-state check failed")
      return
    end
    local state = "unknown"
    if data.credential_state == siwa.STATE_AUTHORIZED then
      state = "authorized"
    elseif data.credential_state == siwa.STATE_REVOKED then
      state = "revoked"
    elseif data.credential_state == siwa.STATE_NOT_FOUND then
      state = "not_found"
    end
    emit("auth.provider.credential_state", {
      provider = "apple",
      credential_state = state
    })
    callback(state, nil)
  end)
  if not started then
    callback(nil, "Apple credential-state check did not start")
  end
end

return M
