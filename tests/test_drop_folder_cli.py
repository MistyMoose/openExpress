"""The command-line side of the FIT drop folder: `setup --copy-fit-to`/`--copy-fit-types`
persist the setting (settings.Settings.copy_fit_to/copy_fit_types), and `sync --copy-fit-to`
overrides it for one run without saving anything (service.drop_folder_dest), the same pattern as
every other `setup`/one-run-option pair in this program (e.g. --diagnostics-copy). No device
is opened by any of this."""

from pathlib import Path

from openexpress import service
from openexpress.cli import main
from openexpress.settings import Settings


def test_setup_without_options_does_not_mention_the_drop_folder(capsys):
    assert main(["setup"]) == 0
    assert "drop folder" not in capsys.readouterr().out.lower()


def test_setup_copy_fit_to_persists_the_destination_and_prints_it(capsys, tmp_path):
    dest = tmp_path / "drop"
    assert main(["setup", "--copy-fit-to", str(dest)]) == 0
    out = capsys.readouterr().out
    assert "FIT drop folder" in out and str(dest) in out
    assert Settings.load().copy_fit_to == str(dest)


def test_setup_copy_fit_to_off_clears_a_destination_saved_before(tmp_path):
    main(["setup", "--copy-fit-to", str(tmp_path / "drop")])
    assert Settings.load().copy_fit_to
    assert main(["setup", "--copy-fit-to", "off"]) == 0
    assert Settings.load().copy_fit_to == ""


def test_setup_copy_fit_types_persists_a_comma_list_and_off_clears_it():
    assert main(["setup", "--copy-fit-types", "FIT_TYPE_32,FIT_TYPE_2"]) == 0
    assert Settings.load().copy_fit_types == "FIT_TYPE_32,FIT_TYPE_2"
    assert main(["setup", "--copy-fit-types", "off"]) == 0
    assert Settings.load().copy_fit_types == ""


def test_setup_without_copy_fit_options_leaves_a_saved_destination_untouched(tmp_path):
    dest = tmp_path / "drop"
    main(["setup", "--copy-fit-to", str(dest)])
    assert main(["setup", "--locale", "fr_FR"]) == 0
    assert Settings.load().copy_fit_to == str(dest)


# --- service.drop_folder_dest: --copy-fit-to for one run, else the setting, else off -------


def test_drop_folder_dest_prefers_the_run_s_own_option_over_the_setting(tmp_path):
    settings = Settings(copy_fit_to=str(tmp_path / "setting"))
    assert service.drop_folder_dest(settings, str(tmp_path / "run-only")) == tmp_path / "run-only"


def test_drop_folder_dest_falls_back_to_the_setting_when_nothing_is_given_for_this_run(
        tmp_path):
    settings = Settings(copy_fit_to=str(tmp_path / "setting"))
    assert service.drop_folder_dest(settings, None) == tmp_path / "setting"


def test_drop_folder_dest_is_none_when_neither_is_given():
    assert service.drop_folder_dest(Settings(), None) is None


def test_drop_folder_dest_expands_a_leading_tilde(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert service.drop_folder_dest(Settings(), "~/drop") == Path.home() / "drop"
