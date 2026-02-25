"""
Launcher module — locates the bundled ``nvnodetop.sh`` and exec's it,
passing through any command-line arguments.
"""

from __future__ import annotations

import os
import importlib.resources
import sys
import stat
import tempfile


def main() -> None:
    """Entry point for the ``nvnodetop`` console script."""
    # Locate the bundled shell script
    try:
        # Python 3.9+: files() API
        ref = importlib.resources.files("nvnodetop").joinpath("nvnodetop.sh")
        with importlib.resources.as_file(ref) as script_path:
            _exec_script(script_path)
    except AttributeError:
        # Python 3.8 fallback: pkg_resources / __file__-relative lookup
        here = os.path.dirname(__file__)
        script_path = os.path.join(here, "nvnodetop.sh")
        if not os.path.isfile(script_path):
            sys.exit(
                "nvnodetop: could not locate nvnodetop.sh inside the installed package. "
                "Please reinstall with: pip install --force-reinstall nvnodetop"
            )
        _exec_script(script_path)


def _exec_script(script_path: "os.PathLike[str]") -> None:
    """Make *script_path* executable if needed, then exec it (Unix only)."""
    import platform

    if platform.system() == "Windows":
        sys.exit(
            "nvnodetop is a Bash script and is not supported on Windows.\n"
            "Please use WSL2 or a Linux/macOS environment."
        )

    script = str(script_path)

    # Ensure the script is executable; if the file is inside a zip/wheel it
    # will have been extracted to a real path by as_file() / the fallback.
    current_mode = os.stat(script).st_mode
    if not (current_mode & stat.S_IXUSR):
        try:
            os.chmod(script, current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        except OSError:
            # Read-only install (e.g. system site-packages) — copy to a temp file
            import shutil

            tmp = tempfile.NamedTemporaryFile(
                prefix="nvnodetop_", suffix=".sh", delete=False
            )
            tmp.close()
            shutil.copy2(script, tmp.name)
            os.chmod(tmp.name, 0o755)
            script = tmp.name

    # Replace the current process with bash running the script
    args = ["/bin/bash", script] + sys.argv[1:]
    os.execv("/bin/bash", args)


if __name__ == "__main__":
    main()
