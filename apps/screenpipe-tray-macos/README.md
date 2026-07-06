# screenpipe-tray (macOS)

Tiny menu-bar companion for the **headless** engine (`screenpipe record` under
launchd) — see issue #4. It is just another API client of `127.0.0.1:3030`,
deliberately a separate process so it can show the one state the engine can
never report about itself: **engine down**.

## What it shows

Polls `GET /health` every 2 s (1.5 s timeout) and drives a template
SF-Symbol icon:

| icon | state | meaning |
|---|---|---|
| ⏺ `record.circle` | recording | engine healthy, capture running |
| ⏸ `pause.circle` | paused | manual pause, media auto-detect, DRM content, or schedule |
| ⚠ `exclamationmark.circle` | stalled | `audio_db_write_stalled \|\| vision_db_write_stalled` |
| ⃠ `slash.circle` | down | `/health` unreachable (crash, memwatch kill) |

The first menu line spells out the state, including the resume countdown for a
timed manual pause (from `media_manual_pause_until_ms`).

## What it controls

- **Pause 15m / 1h / 2h / 4h / Until Resumed** → `POST /recording/pause
  {"duration_secs": N}` (no duration = until resumed). This is the engine's
  manual media pause: it stops screen capture, audio transcription, **and**
  UI-event/clipboard indexing, forward-only, with wall-clock auto-expiry.
- **Resume Recording** → `POST /recording/resume`. Only enabled while a manual
  pause is active — it does not (and cannot) override the DRM/schedule/media
  auto-pauses.
- **Restart Engine** → `launchctl kickstart -k gui/$UID/<label>`.

## Build & install

```sh
make                # swiftc -O + ad-hoc codesign → ./screenpipe-tray
make install        # → ~/.local/bin/screenpipe-tray (PREFIX=... to override)
make install-agent  # render + bootstrap the launchd agent (RunAtLoad, KeepAlive)
```

`make install-agent` writes `~/Library/LaunchAgents/com.bogdan.screenpipe-tray.plist`
from the template in this directory, substituting the binary path, then
`launchctl bootstrap`s it into the Aqua session. Remove with
`make uninstall-agent`.

`make install-agent ENGINE_BIN=/path/to/screenpipe` overrides where the tray
finds the engine CLI (see auth below).

Run ad hoc instead:

```sh
./screenpipe-tray --port 3030 --launchd-label com.bogdan.screenpipe \
    --engine-bin ~/projects/Personal/screenpipe/target/release/screenpipe
```

`--launchd-label` is the *engine's* agent label (what Restart Engine
kickstarts), not this app's.

## Auth

The engine ships with `api_auth: true` — `/health` is exempt (status always
works) but `/recording/*` requires a Bearer token. The tray resolves the key
the same way the engine's own CLI does, in priority order:

1. `SCREENPIPE_API_KEY` env var, if set;
2. shelling out to `<engine-bin> auth token`, which reads the secret store
   the running server persists its key to.

The key is fetched lazily on the first pause/resume click and cached; a
401/403 (key rotation) drops the cache, re-resolves, and retries once.
`--engine-bin` matters under launchd, where PATH won't contain a
built-from-source binary — the plist template carries an absolute path.

## Notes

- No TCC permissions needed: localhost HTTP + `launchctl` only.
- curl equivalents:

  ```sh
  TOKEN=$(screenpipe auth token)
  curl -X POST -H "authorization: Bearer $TOKEN" localhost:3030/recording/pause  # until resumed
  curl -X POST -H "authorization: Bearer $TOKEN" \
       -H 'content-type: application/json' -d '{"duration_secs":900}' \
       localhost:3030/recording/pause                                            # 15 min
  curl -X POST -H "authorization: Bearer $TOKEN" localhost:3030/recording/resume
  ```
