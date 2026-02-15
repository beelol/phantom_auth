local M = {}
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
    return siwa ~= nil
  elseif provider == "google" then
    return gpgs ~= nil
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
  print("Providers: Attempting " .. provider .. " Login")

  if provider == "apple" then
    print("Apple spotted")

    if not siwa then
      print("SIWA extension missing")

      callback(nil, "SIWA extension missing")
      return
    end

    siwa.authenticate(function(self, data)
      print("siwa.authenticate callback")
      pprint(data)

      if not data then
        callback(nil, "Apple Auth Failed: no response data")
        return
      end

      if data.result == "OK" and data.identity_token then
        print("siwa.authenticate callback: Apple Auth Success")
        callback({ token = data.identity_token }, nil)
        return
      end

      callback(nil, "Apple Auth Failed: " .. tostring(data.message or data.result))
    end)
  elseif provider == "google" then
    if not gpgs then
      callback(nil, "GPGS extension missing")
      return
    end

    -- Ensure silent login or interactive based on state?
    -- For "Link", we usually want interactive if silent fails.
    -- But for simplicity here, we assume standard flow.

    if gpgs.is_logged_in() then
      local id_token = gpgs.get_id_token()
      if id_token then
        callback({ token = id_token }, nil)
      else
        callback(nil, "GPGS Logged in but no ID Token")
      end
      return
    end

    -- Start interactive login
    gpgs.login()
    gpgs.set_callback(function(self, message_id, message)
      if message_id == gpgs.MSG_SIGN_IN or message_id == gpgs.MSG_SILENT_SIGN_IN then
        if message.status == gpgs.STATUS_SUCCESS then
          local id_token = gpgs.get_id_token()
          if id_token then
            callback({ token = id_token }, nil)
          else
            callback(nil, "GPGS Login success but ID Token was nil")
          end
        else
          callback(nil, "GPGS Login failed: " .. tostring(message.error))
        end
      end
    end)
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
        print("gamekit.gc_signin callback")
        pprint(event)

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

return M
