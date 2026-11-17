# The engine protocol (macOS app ↔ openExpress)

The macOS app (`macos/`) runs `openexpress engine` as a child process and talks to it over
**JSON Lines**: one JSON object per line, UTF-8, on the engine's stdin (requests) and stdout
(responses and events). The engine's stderr is its log, never parsed. The engine reuses the code
of the command line; it adds no behaviour of its own.

## Messages

App → engine, a **request**:

```json
{"id": 7, "method": "maps.list", "params": {"device": "3491967800", "all": false}}
```

Engine → app, exactly one **response** per request, with the same `id`:

```json
{"id": 7, "result": { ... }}
{"id": 7, "error": {"code": "device_busy", "message": "Garmin Express Service is using the device. Quit it, then try again.", "data": {"program": "Garmin Express Service"}}}
```

Engine → app, any number of **events** (no `id`), at any time:

```json
{"event": "progress", "params": {"request": 9, "phase": "downloading", "done": 1048576, "total": 52428800, "item": "TopoActive Western Europe"}}
```

`message` texts are already translated (the engine's language follows `LANG`, which the app sets
from the user's preferred language). `code` is stable and meant for the app's logic.

Requests run one at a time per device; a request for a busy device waits. `cancel` stops a
running request at the next safe point (never in the middle of writing one file to a device).

## Methods

| Method | Params | Result |
|---|---|---|
| `hello` | `{"client": "openExpress-mac/0.1"}` | `{"engine": version, "platform": "darwin", "methods": [...]}` |
| `account.status` | — | `{"signed_in": bool, "account": masked or null, "setup_done": bool}` |
| `account.setup` | `{"installer": path}` | `{}` (reads the app key from GarminExpress.exe, as `setup --from-installer`) |
| `account.sign_in_url` | — | `{"url": str}` |
| `account.sign_in` | `{"ticket_url": str}` | `{"account": masked}` (as `login --manual`, without the prompt) |
| `account.sign_out` | — | `{}` |
| `devices.list` | — | `{"devices": [Device]}`: connected and remembered |
| `device.info` | `{"device"}` | `Device` with storage, free space, software |
| `device.backup` | `{"device", "dest"?, "keep"?, "apply": bool}` | `{"path", "copied", "copied_bytes", "linked", "linked_bytes", "removed": [...]}` |
| `device.sync` | `{"device", "apply": bool, "types"?: [...]}` | upload / download counts, drop-folder copies, Strava uploads |
| `updates.list` | `{"device"}` | `{"updates": [Update], "beta_offered": bool}` |
| `updates.install` | `{"device", "parts": [...] or "all", "apply": bool}` | what was copied; the device installs it after unplugging |
| `maps.list` | `{"device", "all": bool}` | `{"maps": [Map], "own_maps": [...], "free": bytes}` |
| `maps.install` / `maps.update` / `maps.remove` | `{"device", "maps": [names], "apply": bool}` | per map: done / refused with reason |
| `apps.list` / `apps.install` / `apps.remove` | as the CLI | as the CLI |
| `activities.list` | `{"device"?, "limit"?}` | `{"activities": [Activity]}` with start, sport, distance, duration, FIT path |
| `settings.get` / `settings.set` | `{"key", "value"?}` | the setting; keys as `setup` (drop folder, types, backup folder, keep, …) |
| `strava.status` / `strava.connect` / `strava.disconnect` | see strava.py | |
| `cancel` | `{"request": id}` | `{}` |
| `shutdown` | — | `{}`, then the engine exits |

`apply: false` is always a dry run that returns what would happen, as on the command line.

## Events

| Event | Params |
|---|---|
| `device.attached` / `device.detached` | `Device` (from USB polling on macOS) |
| `device.busy` | `{"device", "program"}`: another program holds it (e.g. Garmin Express Service) |
| `progress` | `{"request", "phase", "done", "total", "item"?}` |
| `log` | `{"level", "message"}`: what the CLI would print as it goes |

## Objects

- `Device`: `{"unit_id": str, "name", "part_number", "software", "connected": bool, "busy_by": str|null, "storage": {"free", "capacity"}|null, "last_sync": iso|null}`
- `Update`: `{"part", "name", "version", "installed", "size", "beta": bool, "waiting_on_device": bool}`
- `Map`: `{"name", "version", "size", "installed": bool, "status": "up to date"|"update"|"available", "region"?}`

Unit IDs travel as strings (they exceed 2^31). Sizes are bytes, times ISO 8601 with offset.
