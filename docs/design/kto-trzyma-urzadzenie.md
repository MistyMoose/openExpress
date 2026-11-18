# Design: what keeps a device from gvfs – its node first, KDE only where KDE is seen

Status: implemented as below (D1–D5).

## What happened before

When a Garmin device was on USB in its normal mode (`usb_state()` is `PRESENT`) and gvfs had not
offered it once `WAIT_FOR_DEVICE_S` (45 s) ran out, a sentence about KDE's MTP service was added to
what the user was told: on the command line (`gio_storage.open_device_storage(wait=True)`, also
after a mount error) and on the window's page "Device Not Ready" (`gui/detection.py`). It named
Dolphin and `kquitapp6 kiod6`. Nothing checked for KDE, so every device that gvfs never offered got
it.

One such case: openExpress run over SSH. logind gives the device's node in `/dev/bus/usb` to the
user of the active seat; a user without a seat may not open it, so gvfs's MTP backend fails
(libmtp: `libusb_open() failed!: Permission denied`), offers nothing, the state stays `PRESENT`,
and after 45 s the command line spoke of KDE on a computer without it. The same holds for a user
of another seat, or a device without a udev rule for this user.

## Decisions

- **D1. This user's access to the node first.** The places on USB (bus and device number) of the
  Garmin devices in their normal mode are read from /sys; their nodes are `USB_NODES/BBB/DDD`.
  When a node is there and `os.access(node, R_OK | W_OK)` says no, the user is told: "This user has
  no access to the device on USB. Run openExpress as the user logged in at this computer's screen,
  not over SSH, or give this user access to the device (a udev rule)." The two ways cover the two
  causes: another session than the one at the screen (SSH, another user's session), which
  logind does not give the device to, and a computer where no udev rule gives access to it (a
  server without a screen, a container, a system without logind). When the folder of nodes is
  missing (a Flatpak without `--device=usb`), nothing is said about access; with that permission
  the Flatpak sees the nodes with the same permissions as outside it.
- **D2. KDE only where it is seen.** The sentence about KDE's MTP service is said only where the
  environment names KDE as the desktop (`XDG_CURRENT_DESKTOP`, `XDG_SESSION_DESKTOP`,
  `DESKTOP_SESSION`, `KDE_FULL_SESSION`), which the Flatpak sees too, or a `kiod6` or `kiod5` of
  this user is in `/proc` (outside the Flatpak, which sees only its own processes). The window asks
  on each look at USB, so a look in `/proc` holds `KDE_LOOK_S` (5 s). Access (D1) comes first: on
  KDE too, a node this user may not open is what keeps gvfs from the device.
- **D3. Neither: no sentence about other programs.** The PIN and "plug it in again" stay; no
  general sentence about some other program. A mount error after the wait is said as it is.
- **D4. One function for both places.** `held_elsewhere(window)` returns the sentence for the case
  (access, KDE, or none: "") and whether it is the access; `not_offered_text(advice, window)` makes
  the whole text from it; the command line and the window use them. The log says what was found,
  once while it stays the same: "device: not offered by gvfs; USB nodes: … without access; KDE: not
  seen; told: access".
- **D5. Without access, nothing else to try.** The advice about the device's screen, its PIN and
  plugging the cable in again helps nothing when this user may not open the node: the text is
  only "The Garmin device is connected, but it does not offer its files." and the sentence about
  access. The node (bus and device number only, never a serial number) is named on the command
  line, in that sentence, and in the log, not in the window: a path there helps nobody.

## Texts

Three new texts, with their Polish in `po/pl.po`; the other languages through Weblate: the
sentence about access in the window (D1), the same with the node on the command line (D5), and
the first sentence of the device not offering its files alone (D5). The text about KDE is
unchanged. The window's texts fit the narrowest window (360 px), in English and in Polish.

## Tests

- `tests/conftest.py`: no test sees the desktop or the processes of the computer running it (the
  desktop variables are cleared, `PROC` is an empty folder); `kde_desktop` names KDE for a test
  that needs it. `tests/test_test_isolation.py` checks that.
- `tests/test_no_mtp.py`: no KDE sentence without KDE; without access only that the device is
  connected and the access, the node on the command line and not in the window, also on KDE;
  neither: nothing about other programs; KDE seen by a kiod or by the environment, and
  other desktops not taken for KDE; the look in `/proc` held a while; the log line once; the
  window's page in English and in Polish; the notices at 360 px.
- The tests that expect the KDE sentence (`tests/test_no_mtp.py`, `tests/test_detection.py`) use
  `kde_desktop`.

## Not in scope

Finding which process holds the node (its open files in `/proc`): not visible from the Flatpak, and
the cases above do not need it.
