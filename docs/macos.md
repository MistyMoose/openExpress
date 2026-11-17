# openExpress for Mac

openExpress-mac is the macOS edition of [openExpress](https://github.com/TomaszBojanowski/openExpress):
a native app for Apple Silicon Macs that replaces Garmin Express. It keeps openExpress's Python
code as its engine, adds a macOS device layer to it, and puts a SwiftUI app on top.

Not affiliated with Garmin. Free software under the GNU GPL v3.0 or later, like openExpress.

## Why

Garmin Express for Mac is an Intel-only app. It runs under Rosetta 2, which macOS 27 is the last
release to fully support. It also hangs when it installs maps or software: it switches the
device into a special USB mode, fails to reach it there, and only falls back after about two
minutes ("Reconnect the device to continue"). openExpress installs maps and software as plain
files over MTP, so that mode is never needed.

## Status

| | |
|---|---|
| Engine on macOS (no GTK, no PyGObject) | works; tested read-only on a fēnix 8 |
| Device info, backup, update and map checks | work on a real device |
| Installing maps and software, sync uploads | implemented upstream; not yet tried from the Mac app |
| Mac app | runs against the engine; under development |
| Installer (.pkg, no Homebrew needed) | not yet |

Devices tested on the Mac: fēnix 8 47 mm AMOLED. The upstream project lists the devices it was
tested with in [devices.md](devices.md).

## How it fits together

```
openExpress.app (SwiftUI)
   │  JSON Lines over stdin/stdout          docs/ENGINE.md
   ▼
openexpress engine (Python, upstream's code)
   │  device layer: openexpress/platform, openexpress/device/mac_storage.py
   ▼
MTP over libusb  ──►  the watch or bike computer
```

- **Device access** goes through openExpress's own MTP client (`device/ptp.py`) over libusb,
  not through GIO/gvfs as on Linux. A device another program holds (Garmin Express Service,
  Android File Transfer, …) is never taken from it: openExpress says which program to quit.
- **ptpcamerad**, the macOS service that grabs cameras and phones for Image Capture and Photos,
  is paused only while openExpress holds a device and resumed afterwards, even after a crash.
- **Secrets** (the Garmin sign-in, the app key, Strava tokens) live in the macOS Keychain.
- **Folders:** settings and data in `~/Library/Application Support/openExpress`, caches in
  `~/Library/Caches/openExpress`, the log in `~/Library/Logs/openExpress`.

## What this edition adds

- The Mac app: devices in a sidebar, pages for Overview, Activities (route map and charts),
  Updates, Maps, Apps and Backups, a menu bar item, notifications, and an automatic backup and
  sync when a device is connected. Updates are never installed without asking.
- [The engine protocol](ENGINE.md) (`openexpress engine`), which the app uses.
- Incremental backups: a file that has not changed since the previous backup is hard-linked to
  it instead of being read from the device again.
- A FIT drop folder: new activity files are copied to a folder of your choice after each sync,
  for other apps to pick up (`setup --copy-fit-to DIR`).
- Strava: upload new activities with your own Strava API app ([guide](guide.md#strava)).
- No battery level: Garmin devices answer MTP's battery question with a fixed 50 % at any
  charge, so none is shown.

## Setting up the engine (for now)

The app will bundle its engine. Until then, from a checkout:

```bash
brew install libusb p7zip
uv venv -p 3.13 ~/.venvs/openexpress-mac
uv pip install -p ~/.venvs/openexpress-mac requests mutagen
uv pip install -p ~/.venvs/openexpress-mac --no-deps -e .
openexpress=~/.venvs/openexpress-mac/bin/openexpress
$openexpress setup --from-installer GarminExpress.exe   # Garmin's Windows installer, once
$openexpress login --manual                             # in a Terminal window
$openexpress info                                       # with the device connected
```

Quit Garmin Express first (also its "Garmin Express Service" in the menu bar): it holds the
device while it runs.

## Building the app

```bash
brew install xcodegen
cd macos
xcodegen generate                      # writes openExpress.xcodeproj from project.yml
(cd OpenExpressKit && swift test)      # engine client, models and view models
xcodebuild -scheme openExpress -configuration Debug -derivedDataPath build/DerivedData build
OPENEXPRESS_ENGINE=mock build/DerivedData/Build/Products/Debug/openExpress.app/Contents/MacOS/openExpress
```

`OPENEXPRESS_ENGINE` chooses the engine:
- a path to `openexpress`;
- `mock`, an engine in memory with no device or network (`mock:busy`, `mock:firstRun`,
  `mock:signedOut` and `mock:empty` show other states);
- unset: the engine inside the app, then `~/.venvs/openexpress-mac/bin/openexpress`.

The Xcode scheme sets it to `mock`.

## Tests

```bash
OPENEXPRESS_TESTS_NO_DISPLAY=1 ~/.venvs/openexpress-mac/bin/python -m pytest -q
```

On macOS the tests get a home folder of their own (they never touch `~/Library`), never reach a
real USB device or the Keychain, and skip the ones that need PyGObject (the Linux window).

## Branches and upstream

- `main` is openExpress-mac: upstream's code with the macOS work on top.
- Upstream's changes come in by merging `upstream/main` into `main`.
- Changes that are useful on every platform (the device layer, portability fixes) are offered
  to upstream as pull requests from branches based on `upstream/main`.
