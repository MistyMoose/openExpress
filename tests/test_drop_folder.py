"""The FIT drop folder (macOS fork, sync.py): after a sync, FIT files of the chosen data types
(activities by default) are copied into a folder of the user's own, for another program
watching it to pick up, each under its name on the device, never overwriting one already
there — so a file an earlier sync already put there is simply left alone, and only the ones
new since then are copied. All devices and files are made up."""

import os

from openexpress import sync
from openexpress.device.storage import LocalStorage
from openexpress.device.xmldevice import parse

# device_root (conftest.py): 2 activities (FIT_TYPE_4), 1 monitor file (FIT_TYPE_32), 1
# settings file (FIT_TYPE_2); "notes.txt" has no FIT extension.
ACTIVITY_NAMES = {"2026-10-01-10-00-00.fit", "2026-10-02-10-00-00.fit"}


def _device(root):
    st = LocalStorage(root)
    return st, parse(st.read("GARMIN/GarminDevice.xml"))


# --- drop_folder_types: a comma list of names, defaulting to activities --------------------


def test_drop_folder_types_is_activities_only_when_nothing_is_chosen():
    assert sync.drop_folder_types("") == sync.DROP_FOLDER_DEFAULT_TYPES
    assert {sync.ACTIVITY_TYPE} == sync.DROP_FOLDER_DEFAULT_TYPES


def test_drop_folder_types_splits_and_trims_a_comma_list():
    assert sync.drop_folder_types("FIT_TYPE_4, FIT_TYPE_32 ,FIT_TYPE_2") == {
        "FIT_TYPE_4", "FIT_TYPE_32", "FIT_TYPE_2"}


def test_drop_folder_types_ignores_empty_items():
    assert sync.drop_folder_types(" , FIT_TYPE_4 , , ") == {"FIT_TYPE_4"}


# --- plan_drop_folder: read-only, by name alone ---------------------------------------------


def test_plan_lists_the_activities_not_yet_in_the_destination(device_root, tmp_path):
    st, dev = _device(device_root)
    dest = tmp_path / "drop"
    planned = sync.plan_drop_folder(dev, st, dest)
    assert {f.name for f in planned} == ACTIVITY_NAMES
    assert {f.datatype for f in planned} == {"FIT_TYPE_4"}
    assert not dest.exists()  # a plan reads nothing, writes nothing


def test_plan_leaves_out_a_name_already_in_the_destination(device_root, tmp_path):
    st, dev = _device(device_root)
    dest = tmp_path / "drop"
    dest.mkdir()
    (dest / "2026-10-01-10-00-00.fit").write_bytes(b"already here, from an earlier sync")
    planned = sync.plan_drop_folder(dev, st, dest)
    assert {f.name for f in planned} == {"2026-10-02-10-00-00.fit"}


def test_plan_with_other_types_looks_at_their_folders_instead(device_root, tmp_path):
    st, dev = _device(device_root)
    planned = sync.plan_drop_folder(dev, st, tmp_path / "drop", types=frozenset({"FIT_TYPE_32"}))
    assert {f.name for f in planned} == {"M1.FIT"}


# --- run_drop_folder: the copy itself --------------------------------------------------------


def test_run_copies_the_activities_and_creates_the_destination(device_root, tmp_path):
    st, dev = _device(device_root)
    dest = tmp_path / "drop"
    res = sync.run_drop_folder(dev, st, dest)
    assert set(res.copied) == ACTIVITY_NAMES
    assert res.incomplete == 0
    assert dest.is_dir()
    for name in ACTIVITY_NAMES:
        assert (dest / name).read_bytes() == (
            device_root / "GARMIN/Activity" / name).read_bytes()
    assert res.bytes == sum((dest / n).stat().st_size for n in ACTIVITY_NAMES)
    assert sorted(p.name for p in dest.iterdir()) == sorted(ACTIVITY_NAMES)  # no leftover .tmp


def test_a_second_run_copies_nothing_new_and_never_overwrites(device_root, tmp_path):
    st, dev = _device(device_root)
    dest = tmp_path / "drop"
    first = sync.run_drop_folder(dev, st, dest)
    assert len(first.copied) == 2
    second = sync.run_drop_folder(dev, st, dest)
    assert second.copied == [] and second.bytes == 0


def test_a_file_the_user_put_there_under_the_same_name_is_never_overwritten(
        device_root, tmp_path):
    st, dev = _device(device_root)
    dest = tmp_path / "drop"
    dest.mkdir()
    mine = dest / "2026-10-01-10-00-00.fit"
    mine.write_bytes(b"the user's own file of this name")
    res = sync.run_drop_folder(dev, st, dest)
    assert res.copied == ["2026-10-02-10-00-00.fit"]
    assert mine.read_bytes() == b"the user's own file of this name"


def test_a_fit_file_still_being_written_is_left_for_the_next_sync(device_root, tmp_path):
    truncated = device_root / "GARMIN/Activity/2026-10-01-10-00-00.fit"
    truncated.write_bytes(truncated.read_bytes()[:-5])  # cut short: the header overstates it
    st, dev = _device(device_root)
    res = sync.run_drop_folder(dev, st, tmp_path / "drop")
    assert res.copied == ["2026-10-02-10-00-00.fit"]
    assert res.incomplete == 1
    assert not (tmp_path / "drop" / "2026-10-01-10-00-00.fit").exists()


def test_only_the_configured_types_are_looked_at(device_root, tmp_path):
    st, dev = _device(device_root)
    res = sync.run_drop_folder(dev, st, tmp_path / "drop", types=frozenset({"FIT_TYPE_2"}))
    assert res.copied == ["Settings.fit"]


def test_falls_back_to_an_ordinary_copy_when_the_filesystem_refuses_hard_links(
        device_root, tmp_path, monkeypatch):
    def no_links(_src, _dst):
        raise OSError("made up: this filesystem has no hard links")

    monkeypatch.setattr(os, "link", no_links)
    st, dev = _device(device_root)
    dest = tmp_path / "drop"
    res = sync.run_drop_folder(dev, st, dest)
    assert set(res.copied) == ACTIVITY_NAMES
    for name in ACTIVITY_NAMES:
        assert (dest / name).read_bytes() == (
            device_root / "GARMIN/Activity" / name).read_bytes()


def test_a_second_run_still_writes_nothing_new_after_the_fallback_path(
        device_root, tmp_path, monkeypatch):
    monkeypatch.setattr(os, "link", lambda *_a: (_ for _ in ()).throw(
        OSError("made up: no hard links")))
    st, dev = _device(device_root)
    dest = tmp_path / "drop"
    sync.run_drop_folder(dev, st, dest)
    second = sync.run_drop_folder(dev, st, dest)
    assert second.copied == []


# --- service.after_sync: the step after every sync (command line, engine, window, service) --


def _session(root, **settings):
    from openexpress import service
    from openexpress.settings import Settings

    st, dev = _device(root)
    return service.DeviceSession(st, dev, Settings(**settings), client=None)


def test_after_sync_does_nothing_when_both_settings_are_off(device_root):
    from openexpress import service

    after = service.after_sync(_session(device_root), apply=True)
    assert after == service.AfterSyncResult()
    assert after.problems() == []


def test_after_sync_plans_in_a_dry_run_and_copies_with_apply(device_root, tmp_path):
    from openexpress import service

    s = _session(device_root, copy_fit_to=str(tmp_path / "drop"))
    planned = service.after_sync(s, apply=False)
    assert (planned.drop_folder, planned.drop_planned, planned.dropped) == (
        tmp_path / "drop", 2, None)
    assert not (tmp_path / "drop").exists()  # a dry run writes nothing
    done = service.after_sync(s, apply=True)
    assert set(done.dropped.copied) == ACTIVITY_NAMES and done.drop_planned is None


def test_after_sync_keeps_an_error_of_the_drop_folder_in_its_result(device_root, tmp_path):
    from openexpress import service

    taken = tmp_path / "a file"
    taken.write_text("not a folder")
    after = service.after_sync(_session(device_root, copy_fit_to=str(taken)), apply=True)
    assert after.dropped is None and isinstance(after.drop_error, OSError)
    assert after.problems()[0].startswith("FIT drop folder: ")


class _CountingStorage(LocalStorage):
    """The device's files, each read counted by its name."""

    def __init__(self, root):
        super().__init__(root)
        self.reads: list[str] = []

    def read(self, path):
        self.reads.append(os.path.basename(path))
        return super().read(path)


def test_files_the_drop_folder_has_are_taken_from_it_and_not_read_from_the_device(
        device_root, tmp_path):
    st = _CountingStorage(device_root)
    dev = parse(st.read("GARMIN/GarminDevice.xml"))
    drop, staging = tmp_path / "drop", tmp_path / "staging"
    sync.run_drop_folder(dev, st, drop)
    (drop / "2026-10-02-10-00-00.fit").unlink()  # the program watching it took it away
    st.reads.clear()
    res = sync.run_drop_folder(dev, st, staging, copies=drop)
    assert set(res.copied) == ACTIVITY_NAMES
    assert st.reads == ["2026-10-02-10-00-00.fit"]  # only the one the drop folder lost
    for name in ACTIVITY_NAMES:
        assert (staging / name).read_bytes() == (
            device_root / "GARMIN/Activity" / name).read_bytes()
    assert res.bytes == sum((staging / n).stat().st_size for n in ACTIVITY_NAMES)


def test_a_copy_that_is_not_a_whole_fit_file_is_read_from_the_device_instead(
        device_root, tmp_path):
    st = _CountingStorage(device_root)
    dev = parse(st.read("GARMIN/GarminDevice.xml"))
    drop = tmp_path / "drop"
    drop.mkdir()
    (drop / "2026-10-01-10-00-00.fit").write_bytes(b"the user's own file of this name")
    st.reads.clear()
    res = sync.run_drop_folder(dev, st, tmp_path / "staging", copies=drop)
    assert set(res.copied) == ACTIVITY_NAMES
    assert sorted(st.reads) == sorted(ACTIVITY_NAMES)


def test_after_sync_stages_for_strava_from_the_drop_folder_without_reading_the_device_again(
        device_root, tmp_path, monkeypatch):
    from openexpress import service, strava

    monkeypatch.setattr(strava, "upload_files", lambda paths, apply, progress=None:
                        strava.UploadReport())
    s = _session(device_root, copy_fit_to=str(tmp_path / "drop"), strava_upload=True)
    s.storage = _CountingStorage(device_root)
    after = service.after_sync(s, apply=True)
    assert set(after.dropped.copied) == ACTIVITY_NAMES and after.strava_error is None
    assert sorted(s.storage.reads) == sorted(ACTIVITY_NAMES)  # each once, for the drop folder
    pending = strava.pending_dir(s.device.unit_id)
    assert {p.name for p in pending.glob("*.fit")} == ACTIVITY_NAMES
