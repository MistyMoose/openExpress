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
| `hello` | `{"client": "openExpress-mac/0.1"}` | `{"engine": version, "protocol": 1, "platform": "darwin", "methods": [...]}` |
| `account.status` | — | `{"signed_in": bool, "account": masked or null, "environment": str or null, "setup_done": bool}` |
| `account.setup` | `{"installer": path}` | `{}` (reads the app key from GarminExpress.exe, as `setup --from-installer`) |
| `account.sign_in_url` | — | `{"url": str}` |
| `account.sign_in` | `{"ticket_url": str}` | `{"account": masked}` (as `login --manual`, without the prompt); `invalid_ticket` when the address has no `ticket=ST-…` |
| `account.sign_out` | — | `{"removed": bool}` |
| `devices.list` | — | `{"devices": [Device]}`: connected first, then remembered (`connected: false`) |
| `device.info` | `{"device"}` | `Device` with `storage`, plus `storage_name`, `mass_storage`, `datatypes`, `components` |
| `device.backup` | `{"device", "dest"?, "keep"?, "apply": bool}` | dry run: `{"dry_run": true, "dest", "files"}`; applied: `{"dry_run": false, "path", "files", "bytes", "copied", "copied_bytes", "linked", "linked_bytes", "removed": [...], "incomplete"}` |
| `device.sync` | `{"device", "apply": bool, "types"?: [...], "first_run"?: "baseline"\|"all", "uploads"?: bool, "downloads"?: bool}` | dry run: `{"dry_run": true, "signed_in", "first_sync", "uploads": {"files", "bytes", "already_done", "skipped_types"} or null, "upload_error", "uploads_allowed", "downloads", "drop_folder": {"path", "files"} or null, "strava": {"files"} or null}`; applied: `{"dry_run": false, "uploaded", "downloaded", "skipped_known", "rejected", "errors", "not_confirmed", "steps": [text], "sentence", "drop_folder": {"path", "copied", "bytes", "incomplete"} or null, "strava": upload report or {"error"} or null}`; a first sync without `first_run` is the error `first_sync_choice` |
| `updates.list` | `{"device"}` | `{"updates": [Update], "beta_offered": bool, "state": "current"\|"available"\|"ready"\|"not-installed", "add_ons": [Update]}` |
| `updates.install` | `{"device", "parts": [...] or "all", "apply": bool}` | as the command line (`updates --install`): `{"exit_code", "lines"}` |
| `maps.list` | `{"device", "all": bool}` | `{"maps": [Map], "own_maps": [{"file", "size", "title", "path"}], "free": bytes, "more_available": n}`; no maps service for the device: `"maps": []` and `"message"` |
| `maps.install` / `maps.remove` | `{"device", "maps": [names], "apply": bool}` | `{"dry_run", "maps": [{"name", "done": bool, "exit_code", "lines"} or {"name", "done": false, "code", "reason"}]}`, one map after the other |
| `maps.update` | `{"device", "apply": bool}` | as `maps update`: every installed map with an update; `{"exit_code", "lines"}` |
| `apps.list` | `{"device", "builtin"?: bool}` | as `apps`: `{"exit_code", "lines"}` |
| `apps.install` | `{"device", "name", "allow_permissions"?: bool, "apply": bool}` | as `apps install`: `{"exit_code", "lines"}` |
| `apps.remove` | `{"device", "name", "forget"?: bool, "apply": bool}` | as `apps remove`: `{"exit_code", "lines"}` |
| `activities.list` | `{"device"?, "limit"?: 20}` | `{"activities": [Activity], "total", "only_in_backups"}`: the newest `limit`, each file read for its summary (about 0.1 s a file over USB). While it reads, `progress` events of phase `reading_activities` (`done` and `total` in files, `item` the file's name, at most 5 a second, then one with `done` = `total`). What was read is kept by device and file (its path, size and time), in memory and on disk (`activities/<unit id>.json` in the cache folder, as `openexpress activities` keeps it too): a later call, also of a later engine, reads only the files that are new or changed, and tells no progress when there are none; a cancelled call keeps the files it read before it stopped (it stops before the next file), so the next call resumes rather than starts again. The file is written atomically after each call that read files, holds only files still listed, and is not read when another version of openExpress wrote it; a cache that cannot be read or written only costs time, never the request |
| `activities.track` | `{"fit": path, "device"?}` | `{"points": [{"lat", "lon", "time", "hr"?, "alt"?, "speed"?}]}`: the records with a position, at most 2000 (every n-th then, the last kept); `hr` in beats a minute, `alt` in m, `speed` in m/s, each left out where the record has none. `fit`: an absolute path on this computer (a copy in a backup), else a path on the device as `activities.list` gives it (`not_found`, `not_fit` when it cannot be read as FIT) |
| `backups.list` | `{"device"?}` | `{"backups": [{"path", "date", "files", "bytes"}]}`, newest first: the backups of that unit ID (connected or not) in the backup folder (`<folder>/<unit id>/YYYY-MM-DD (HH.MM.SS)`) |
| `settings.get` / `settings.set` | `{"key"?, "value"?}` | `{"key", "value"}`; `settings.get` without a key: `{"settings": {...}}`. Keys as `setup` names its options: `environment`, `locale`, `ui_language`, `diagnostics_copy`, `copy_fit_to` (the FIT drop folder), `copy_fit_types`, `strava_upload` (upload new activities to Strava after a sync; false unless turned on); and `backup_dir`, `backup_keep` (the defaults of `device.backup`) |
| `strava.status` | — | `{"configured", "connected", "athlete_id", "athlete_name", "scope", "expires_at"}` (strava.status) |
| `strava.connect` | `{"client_id"?, "client_secret"?, "redirect_uri", "code"?}` | the app runs the browser: without `code`, the status and `"authorize_url"` to open (the client ID and secret saved first when given); with the `code` Strava's redirect brought, the token is saved and the status returned |
| `strava.disconnect` | — | `{"removed": bool}` |
| `strava.upload` | `{"files": [paths], "apply": bool}` | as `strava upload`: `{"uploaded", "duplicates", "failed", "skipped", "rate_limited"}` |
| `cancel` | `{"request": id}` | `{"cancelling": bool}` (false: no such request running or waiting); the cancelled request then answers with the error code `cancelled`, whether it was running or still waiting for its turn |
| `shutdown` | — | `{}`, the last line; requests still running are cancelled first; the engine then exits (also at the end of stdin) |

`apply: false` is always a dry run that returns what would happen, as on the command line.

`device` is the unit ID as a string; it may be left out when exactly one device is connected.
A method marked "as the command line" runs that command: `lines` is what it printed (also sent
as `log` events), `exit_code` its exit code (0 done; 1 a refusal it explains). A request
holds the device only while it runs: between requests the engine lets it go (on macOS it closes
its USB session), so another program may take it.

Error codes: `parse_error`, `invalid_request`, `unknown_method`, `invalid_params`,
`unknown_setting`, `cancelled`, `no_device`, `several_devices`, `device_busy`
(`data.program`), `device_unsupported`, `device_not_responding`, `device_error`,
`not_signed_in`, `setup_needed`, `not_found`, `not_fit`, `invalid_ticket`, `unauthorized`, `clock_skew`,
`server_error`, `network`, `first_sync_choice`, `stopped` (e.g. another sync is running),
`failed` (any other refusal), `internal`.
A line that is not JSON, or has no `id`, is answered with `"id": null`.

## Events

| Event | Params |
|---|---|
| `device.attached` / `device.detached` | `Device` (from USB polling on macOS) |
| `device.busy` | `{"device", "program", "name"}`: another program holds it (e.g. Garmin Express Service); `device` is null unless its USB serial names a remembered device; `device.attached` follows once it is let go |
| `progress` | `{"request", "phase", "done", "total", "item"?}`; `phase`: `downloading`, `copying`, `writing`, `checking` (then `item` names the update, map or app), `waiting` (a wait on Garmin Connect, in percent), `reading_activities` (`activities.list`), else the method's own (`backup`, `sync`, `working`) with the step's words as `item` |
| `log` | `{"level", "message", "request"}`: what the CLI would print as it goes (`info`: its output; `warning`: what it writes to stderr) |

## Objects

- `Device`: `{"unit_id": str, "name", "part_number", "software", "connected": bool, "busy_by": str|null, "storage": {"free", "capacity"}|null, "last_sync": iso|null, "battery": percent|null, "last_backup": iso|null}`. `battery`: as the device told it when it was last opened (MTP's BatteryLevel), else null — always null for Garmin devices, which answer it with a fixed placeholder (50) at any charge; `last_backup`: the newest backup in the backup folder.
- `Update`: `{"part", "name", "version", "installed", "size", "beta": bool, "waiting_on_device": bool}`
- `Update` also has `not_installed`, `system`, `critical`, `metadata`, `changes`, `eula`, `unreadable_folder`, `older` (a text, or null).
- `Map`: `{"name", "version", "size", "installed": bool, "status": "up to date"|"update"|"available", "region"?}`, also `installed_version` (the version on the device: `version` when "up to date", null when "available"; for "update", Garmin's answer names only the new version, so it is read from the name in the header of the map's files on the device, and is null when that name ends in no version as the server writes one, e.g. CourseView), `status_text` (translated, finer), `type`, `waiting`, `incomplete`, `restricted`, `can_install`, `can_remove`.
- `Activity`: `{"name", "source": "device"|"backup", "path" (on the device, or of the copy), "size", "backup", "start" (the activity's, else the file's time of change: never null), "sport", "sport_id", "distance" (m), "duration" (s, pauses left out), "ascent", "state": "complete"|"still_being_written"|"damaged"|"unreadable"}`

Unit IDs travel as strings (they exceed 2^31). Sizes are bytes, times ISO 8601 with offset.
