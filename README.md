# Phantom Auth

Self-contained guest and provider-auth coordinator for Defold. The containing
app injects its backend bridge and logger; this module never imports parent
project code.

```lua
local phantom = require "main.phantom.module"

phantom.init({
  backend_url = "http://127.0.0.1:8090",
  bridge = bridge,
  logger = logger,
})

phantom.auto_sign_in_anon(callback)
phantom.sign_in("apple", current_backend_token, callback)
phantom.link_account("gamecenter", current_backend_token, callback)
```

The injected bridge implements `init`, `login_guest`, `sign_in`,
`link_account`, and `restore_purchases`. Provider identity tokens and guest
identifiers are never emitted through the logger.
