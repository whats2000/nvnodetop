"""
Launcher module — locates the bundled ``nvnodetop.sh`` and exec's it,
passing through any command-line arguments.
"""

from __future__ import annotations

import importlib.resources
import os
import stat
import sys
import tempfile


def main() -> None:
    """Entry point for the ``nvnodetop`` console script."""
    try:
        # Python 3.9+: files() API
        ref = importlib.resources.files("nvnodetop").joinpath("nvnodetop.sh")
        with importlib.resources.as_file(ref) as script_path:
            _exec_script(script_path)
    except AttributeError:
        # Python 3.8 fallback
        here = os.path.dirname(__file__)
        script_path = os.path.join(here, "nvnodetop.sh")
        if not os.path.isfile(script_path):
            sys.exit(
                "nvnodetop: could not locate nvnodetop.sh inside the installed package. "
                "Please reinstall with: pip install --force-reinstall nvnodetop"
            )
        _exec_script(script_path)


def _exec_script(script_path: "os.PathLike[str]") -> None:
    """Ensure the script has LF line endings, is executable, then exec it."""
    import platform

    if platform.system() == "Windows":
        sys.exit(
            "nvnodetop is a Bash script and is not supported on Windows.\n"
            "Please use WSL2 or a Linux/macOS environment."
        )

    script = str(script_path)

    # ── CRLF safety net ───────────────────────────────────────────────────────
    # If the script was bundled from a Windows machine it may contain \r\n.
    # Bash on Linux will fail with "$'\r': command not found" in that case.
    # We write a clean LF-only copy to a temp file before exec'ing.
    with open(script, "rb") as fh:
        raw = fh.read()

    if b"\r\n" in raw:
        tmp = tempfile.NamedTemporaryFile(
            prefix="nvnodetop_", suffix=".sh", delete=False
        )
        tmp.write(raw.replace(b"\r\n", b"\n"))
        tmp.close()
        os.chmod(tmp.name, 0o755)
        script = tmp.name
    else:
        # Ensure executable bit is set (may be missing after pip install)
        current_mode = os.stat(script).st_mode
        if not (current_mode & stat.S_IXUSR):
            try:
                os.chmod(script, current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            except OSError:
                import shutil
                tmp = tempfile.NamedTemporaryFile(
                    prefix="nvnodetop_", suffix=".sh", delete=False
                )
                tmp.close()
                shutil.copy2(script, tmp.name)
                os.chmod(tmp.name, 0o755)
                script = tmp.name

    # Replace current process with bash — preserves TTY, signals, exit codes
    args = ["/bin/bash", script] + sys.argv[1:]
    os.execv("/bin/bash", args)


if __name__ == "__main__":
    main()
