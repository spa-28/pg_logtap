import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def test_archive_driver_finds_validator_after_chdir():
    with tempfile.TemporaryDirectory() as directory:
        repo = Path(directory) / "repo"
        packaging = repo / "tests/packaging"
        packaging.mkdir(parents=True)
        driver = packaging / "archive-smoke.sh"
        shutil.copy2(ROOT / "tests/packaging/archive-smoke.sh", driver)
        validator = packaging / "archive-smoke.py"
        validator.write_text("placeholder\n")
        (repo / "pg_logtap.control").write_text("default_version = '1.2.3'\n")
        (repo / "sql").mkdir()
        (repo / "sql/pg_logtap--1.2.3.sql").write_text("-- placeholder\n")
        lib = repo / "dist/pg18/lib"
        lib.mkdir(parents=True)
        (lib / "pg_logtap.so").write_bytes(b"runtime")
        (lib / "pg_logtap.so.debug").write_bytes(b"debug")
        output = repo / "private-output"
        output.mkdir()
        runtime = output / "pg_logtap-1.2.3-pg18-amd64.tar.gz"
        debug = output / "pg_logtap-1.2.3-pg18-amd64-debug.tar.gz"
        bindir = repo / "private-bin"
        bindir.mkdir()
        marker = repo / "docker-attempted"

        def write_exe(path, text):
            path.write_text(text)
            path.chmod(0o755)

        write_exe(bindir / "uname", "#!/bin/sh\n[ \"$#\" = 1 ] && [ \"$1\" = -m ] || exit 91\nprintf '%s\\n' x86_64\n")
        write_exe(bindir / "docker", "#!/bin/sh\n: > \"$ARCHIVE_DOCKER_MARKER\"\nexit 97\n")
        write_exe(bindir / "python3", f"""#!{sys.executable}
import sys
from pathlib import Path
args = sys.argv[1:]
if (len(args) != 5 or Path(args[0]).resolve() != Path({str(validator)!r}).resolve()
        or [Path(args[1]), Path(args[2])] != [Path({str(runtime)!r}), Path({str(debug)!r})]
        or args[3:] != ["amd64", "1.2.3"]
        or not Path(args[0]).is_file() or not Path(args[1]).is_file() or not Path(args[2]).is_file()):
    sys.exit(74)
sys.exit(73)
""")
        env = os.environ | {
            "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
            "ARCHIVE_DOCKER_MARKER": str(marker),
        }
        cases = (
            (repo, "tests/packaging/archive-smoke.sh"),
            (packaging, "./archive-smoke.sh"),
            (repo / "third-cwd", str(driver)),
        )
        (repo / "third-cwd").mkdir()
        for cwd, invocation in cases:
            result = subprocess.run(["bash", invocation, "18", str(output)], cwd=cwd, env=env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert result.returncode == 73, result.stderr
            assert not marker.exists()
