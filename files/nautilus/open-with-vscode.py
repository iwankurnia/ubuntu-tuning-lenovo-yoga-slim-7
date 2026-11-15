# Files (Nautilus) extension: adds "Open with VS Code" to the right-click menu,
# for selected files and folders and for the empty part of a folder.
#
# Needs the python3-nautilus package. Lives in
# ~/.local/share/nautilus-python/extensions/ and is read when Files starts, so
# after changing it run:  nautilus -q
#
# The entry is shown only while the "code" command exists, so removing VS Code
# makes it disappear by itself.

import shutil
import subprocess

from gi.repository import GObject, Nautilus

LABEL = "Open with VS Code"


def _paths(files):
    """Local paths of the given files; network and virtual places are left out."""
    paths = []
    for f in files:
        location = f.get_location()
        path = location.get_path() if location else None
        if path:
            paths.append(path)
    return paths


class OpenWithVSCodeExtension(GObject.GObject, Nautilus.MenuProvider):
    def _launch(self, _menu, code, paths):
        subprocess.Popen([code, "--", *paths], start_new_session=True)

    def _items(self, name, tip, files):
        code = shutil.which("code")
        paths = _paths(files)
        if not code or not paths:
            return []
        item = Nautilus.MenuItem(name=name, label=LABEL, tip=tip)
        item.connect("activate", self._launch, code, paths)
        return [item]

    # Older Nautilus versions pass the window first; the files always come last.

    # Right-click on one or more selected files or folders.
    def get_file_items(self, *args):
        return self._items("OpenWithVSCode::Selection", "Open the selection in VS Code", args[-1])

    # Right-click on the empty part of the current folder.
    def get_background_items(self, *args):
        return self._items("OpenWithVSCode::Background", "Open this folder in VS Code", [args[-1]])
