"""The app's folders on macOS (paths._app_dir, platform.app_dir): the matching folder under
~/Library instead of an XDG one; an XDG_*_HOME variable, when one is set (as the test suite's
own fixtures set them), still wins, so the isolation the rest of the tests rely on keeps working
on this platform too."""

import pytest

from openexpress import paths

pytestmark = pytest.mark.usefixtures("as_mac")


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
