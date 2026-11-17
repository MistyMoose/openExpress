"""The app's folders on macOS (paths._app_dir, in_flatpak, default_backup_dir): the matching
folder under ~/Library instead of an XDG one, with no Flatpak and no GLib; an XDG_*_HOME
variable, when one is set (as the test suite's own fixtures set them), still wins, so the
isolation the rest of the tests rely on keeps working on this platform too."""

import sys
import types

import pytest

from openexpress import paths


@pytest.fixture(autouse=True)
def darwin(monkeypatch):
    """Every test in this file runs as if on macOS, whatever the real platform is."""
    monkeypatch.setattr(sys, "platform", "darwin")


@pytest.fixture(autouse=True)
def backups():
    """Overrides conftest's (which stubs default_backup_dir() for every other test): the one
    test below that calls it wants the real darwin implementation."""
    return None


def test_config_and_data_live_under_application_support(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    assert paths.config_dir() == tmp_path / "Library" / "Application Support" / "openExpress"
    assert paths.data_dir() == tmp_path / "Library" / "Application Support" / "openExpress"


def test_cache_lives_under_caches(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("XDG_CACHE_HOME", raising=False)
    assert paths.cache_dir() == tmp_path / "Library" / "Caches" / "openExpress"


def test_state_lives_under_logs(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    assert paths.state_dir() == tmp_path / "Library" / "Logs" / "openExpress"


def test_an_explicit_xdg_variable_still_wins_on_macos(monkeypatch, tmp_path):
    """The test suite's own isolation (tests/conftest.py: private_dirs, log_file) sets these
    variables on every platform; _app_dir must keep honouring them on macOS too, or every other
    test would read and write the real ~/Library folders of whoever runs the suite."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "elsewhere"))
    assert paths.data_dir() == tmp_path / "elsewhere" / "openexpress"


def test_in_flatpak_is_always_false_on_macos(monkeypatch, tmp_path):
    """Even a /.flatpak-info that exists (there is no Flatpak on macOS, so this never happens
    for real) must not be read as one: in_flatpak gates every other Flatpak helper."""
    info = tmp_path / "flatpak-info"
    info.write_text("[Instance]\nbranch=master\n")
    monkeypatch.setattr(paths, "FLATPAK_INFO", info)
    assert not paths.in_flatpak()
    assert paths.flatpak_origin() is None


def test_default_backup_dir_is_under_documents_without_asking_glib(monkeypatch, tmp_path):
    """No GLib is needed on macOS to find Documents: it is always ~/Documents. If the darwin
    branch ever forgot to skip the GLib lookup, this would fail loudly instead of silently
    falling back to the same answer (gi is not installed in this environment either way)."""
    monkeypatch.setenv("HOME", str(tmp_path))
    fake_gi = types.SimpleNamespace(require_version=lambda *_a: pytest.fail(
        "default_backup_dir asked GLib on macOS"))
    monkeypatch.setitem(sys.modules, "gi", fake_gi)
    assert paths.default_backup_dir() == tmp_path / "Documents" / "Garmin" / "Backups"
