"""Every folder a server's answer writes to has a route, decided by the program's own rules: the
ordinary write (a folder the ordinary listing shows, or one made for the write), openExpress's
own session (a folder the device hides at its top level, or one it names for its components in
GarminDevice.xml inside a folder that is seen), or a refusal where that session cannot be had.
None may reach the ordinary making of a folder the device has and hides: that write fails ("Cannot
create directory …").

The data: for each device, the folders it hides as a reading of its own session found them (with
what its GarminDevice.xml says of each) and the folders the saved answers of Garmin's servers
write to. A made-up device in tests/data/write_routes/ always; the real devices of
testdata/write-routes/ when they are there (made with the private tool of the readings)."""

import json
import types
from pathlib import Path

import pytest

from openexpress import hidden_folders, updates
from openexpress.device.storage import LocalStorage

ROOT = Path(__file__).resolve().parent.parent
MADE_UP = sorted((ROOT / "tests" / "data" / "write_routes").glob("*.json"))
REAL = sorted((ROOT / "testdata" / "write-routes").glob("*.json"))

ORDINARY, OWN_SESSION, OWN_SESSION_TOP = "ordinary", "own session", "own session (top level)"


def _hidden_at(folder: str, hidden: list[str]) -> str | None:
    """The folder the device hides that `folder` is or is in; None when it is seen."""
    key = folder.casefold()
    for h in sorted(hidden, key=len):
        if key == h.casefold() or key.startswith(h.casefold() + "/"):
            return h
    return None


def routes(data: dict, root: Path) -> dict[str, tuple[str, str | None]]:
    """Each target folder: (its route by the program's rules, the hidden folder it is in). A
    device without saved answers: the hidden folders its GarminDevice.xml names, where the
    server would write its components."""
    hidden = [h["folder"] for h in data["hidden"]]
    named = [h["folder"] for h in data["hidden"] if h["xml"] == "names the folder"]
    targets = data["targets"] or {folder: {"GarminDevice.xml": 1} for folder in named}
    # The device as the ordinary listing shows it: GARMIN and every target folder not hidden.
    (root / "GARMIN").mkdir(parents=True, exist_ok=True)
    for folder in targets:
        if _hidden_at(folder, hidden) is None:
            (root / folder).mkdir(parents=True, exist_ok=True)
    storage = LocalStorage(root)
    tops = hidden_folders.top_folders(storage)
    device = types.SimpleNamespace(update_files=[
        types.SimpleNamespace(path=f, filename="file") for f in named])
    inside = updates.hidden_inside(storage, device)
    out = {}
    for folder in targets:
        if hidden_folders.top_not_seen(folder, tops) is not None:
            route = OWN_SESSION_TOP
        elif folder.casefold() in inside:
            route = OWN_SESSION
        else:
            route = ORDINARY
        out[folder] = (route, _hidden_at(folder, hidden))
    return out


def _wrong(data: dict, root: Path) -> list[str]:
    return [f"{folder}: the ordinary write, into {at}, which the device hides"
            for folder, (route, at) in routes(data, root).items()
            if route == ORDINARY and at is not None]


@pytest.mark.parametrize("path", MADE_UP, ids=[p.stem for p in MADE_UP])
def test_the_made_up_devices_have_a_route_for_every_folder(path, tmp_path):
    data = json.loads(path.read_text(encoding="utf-8"))
    got = {folder: route for folder, (route, _at) in routes(data, tmp_path).items()}
    assert got == data["expected"]


def test_a_hidden_folder_the_device_does_not_name_is_caught(tmp_path):
    """The guard itself: a target in a hidden folder that GarminDevice.xml does not name would
    take the ordinary write, and the test says so."""
    data = {"hidden": [{"folder": "GARMIN/Secret", "xml": "names its folder"}],
            "targets": {"GARMIN/Secret": {"made-up answer": 1}, "GARMIN/SID": {"made-up": 2}}}
    assert _wrong(data, tmp_path) == [
        "GARMIN/Secret: the ordinary write, into GARMIN/Secret, which the device hides"]


@pytest.mark.skipif(not REAL, reason="no readings of real devices in testdata/write-routes/")
@pytest.mark.parametrize("path", REAL, ids=[p.stem for p in REAL])
def test_no_folder_of_a_real_device_takes_the_ordinary_write_into_a_hidden_one(path, tmp_path):
    data = json.loads(path.read_text(encoding="utf-8"))
    wrong = _wrong(data, tmp_path)
    assert wrong == [], f"{data['device']} {data['software']}: " + "; ".join(wrong)
