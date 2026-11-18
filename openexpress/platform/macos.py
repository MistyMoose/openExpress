"""What macOS has in place of what Linux gives the program: the folders under ~/Library. Used
through the functions of the package (platform), on macOS only.
"""

from __future__ import annotations

from pathlib import Path

APP_NAME = "openExpress"  # the name of the app's folder under ~/Library

# The folder under ~/Library in place of each XDG one: config and data are kept together.
LIBRARY_FOLDERS = {
    "XDG_CONFIG_HOME": "Application Support",
    "XDG_DATA_HOME": "Application Support",
    "XDG_CACHE_HOME": "Caches",
    "XDG_STATE_HOME": "Logs",  # the log, where Console and the user both look for it
}


def app_dir(var: str) -> Path:
    """The app's folder under ~/Library in place of the XDG folder `var`."""
    return Path.home() / "Library" / LIBRARY_FOLDERS[var] / APP_NAME
