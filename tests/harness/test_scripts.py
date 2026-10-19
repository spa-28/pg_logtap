#!/usr/bin/env python3
"""Host-only behavioral checks for e2e harness gates and embedded fixtures.

The shell checks source the real functions under the same ``function ||``
context used by the matrix.  Docker and time are the only modeled boundaries;
the Docker stub refuses every command not needed by a case.
"""
import ast
import base64
import errno
import gzip
import io
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import types
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def fail(message):
    raise AssertionError(message)


def run(command, *, env, cwd=ROOT):
    return subprocess.run(command, cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def write_exe(path, text):
    path.write_text(text)
    path.chmod(0o755)


def fixture_bin(tmp):
    bindir = tmp / "bin"
    bindir.mkdir()
    write_exe(bindir / "docker", r'''#!/usr/bin/env python3
import fcntl, json, os, re, signal, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
log = Path(os.environ["HARNESS_LOG"])
with log.open("a") as f: f.write(json.dumps(args) + "\n")
mode = os.environ.get("HARNESS_MODE", "")
state, hits = Path(os.environ["HARNESS_STATE"]), Path(os.environ["HARNESS_HITS"])
config_mode = mode.startswith(("hook_config", "wide_"))
gucs = Path(os.environ["HARNESS_GUCS"])
def config_state():
    if not gucs.exists():
        initial = json.loads(os.environ["HARNESS_INITIAL_GUCS"])
        gucs.write_text(json.dumps({"configured": initial, "effective": initial, "restarts": 0, "signaled": False}))
    return json.loads(gucs.read_text())
def save_config(value): gucs.write_text(json.dumps(value))
def die(code=97): sys.exit(code)
def hit(name, code):
    if not hits.exists():
        with hits.open("a") as f: f.write(name + "\n")
    sys.exit(code)
def exec_parts():
    rest = args[1:]
    if rest[:1] == ["-i"]: rest = rest[1:]
    if not rest or rest[0].startswith("-"): die()
    ct = rest.pop(0)
    if ct not in ("model", "pglogtap-mx15", "immutable-id", "pgzx-build"): die()
    return ct, rest
if not args: die()
if args[0] == "inspect":
    if args == ["inspect", "-f", "{{.State.Status}}/{{.State.ExitCode}}", "pglogtap-ready"]:
        print("running/0" if mode in ("compose_up", "compose_ready") else "exited/0")
    elif args == ["inspect", "-f", "{{.Id}}", "model"]:
        print("immutable-id")
    elif args == ["inspect", "-f", "{{.State.Status}}", "pglogtap-e2e"]:
        print("running")
    elif args == ["inspect", "-f", "pg: {{.State.Status}} oom={{.State.OOMKilled}}", "model"]:
        print("running")
    elif args == ["inspect", "-f", "receiver: {{.State.Status}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}", "pglogtap-vector"]:
        print("running")
    else: die()
elif args[:2] == ["network", "connect"]:
    if args[2:] != ["pglogtap-e2e_default", "model"]: die()
    sys.exit(91 if mode == "optional_network" else 0)
elif args[0] == "start":
    if args[1:] not in (["pglogtap-vector"], ["receiver"]): die()
    if mode == "receiver_start": hit("receiver_start", 78)
elif args[0] == "compose":
    if args[1:] == ["-f", "tests/e2e/compose.yaml", "up", "-d"]:
        if mode == "compose_up": hit("compose_up", 79)
    elif args[1:] != ["-f", "tests/e2e/compose.yaml", "down"]: die()
elif args[0] == "run":
    if len(args) < 4 or args[1:3] != ["-d", "--name"]: die()
    name = args[3]
    if name == "receiver":
        if len(args) != 13 or args[4:7] != ["--network", "pglogtap-e2e_default", "-v"]: die()
        if not re.fullmatch(r".*/tests/e2e/vector\.yaml:/etc/vector/vector\.yaml:ro", args[7]): die()
        if args[8] != "-v" or not args[9].endswith(":/var/log"): die()
        if args[10:] != ["timberio/vector:0.57.0-alpine", "--config", "/etc/vector/vector.yaml"]: die()
        if mode == "receiver_create": hit("receiver_create", 80)
    elif name == "pglogtap-mx15":
        if args != ["run", "-d", "--name", "pglogtap-mx15", "-e", "POSTGRES_PASSWORD=dev", "--network", "pglogtap-e2e_default", "postgres:15"]: die()
        if mode == "pg_create": hit("pg_create", 81)
    else: die()
elif args[0] == "cp":
    if len(args) != 3: die()
    src, dst = args[1:]
    if re.fullmatch(r"dist/pg15/lib/pg_logtap\.so", src):
        if dst != "pglogtap-mx15:/lib/": die()
        if mode == "copy_so": hit("copy_so", 82)
    elif src == "pg_logtap.control":
        if dst != "pglogtap-mx15:/share/extension/": die()
        if mode == "copy_control": hit("copy_control", 83)
    elif re.fullmatch(r"sql/pg_logtap--[0-9.]+(?:--[0-9.]+)?\.sql", src):
        if dst != "pglogtap-mx15:/share/extension/": die()
        if mode == "copy_sql": hit("copy_sql", 84)
    elif re.fullmatch(r"/tmp/.+/out/hookchain/hookchain\.so", src) and dst == "model:/lib/": pass
    elif src == "tests/e2e/hookchain.c" and dst == "pgzx-build:/tmp/hookchain-model.c": pass
    elif src == "pgzx-build:/tmp/hookchain-model.so" and re.fullmatch(r"/tmp/.+/out/hookchain/hookchain\.so", dst): pass
    else: die()
elif args[0] == "restart":
    if args[1:] not in (["model"], ["pglogtap-mx15"]): die()
    if config_mode:
        config = config_state()
        config["restarts"] += 1
        save_config(config)
        if os.environ.get("HARNESS_FAIL_FIRST_RESTART") == "1" and config["restarts"] == 1:
            hit("first_restart", 86)
        if config["restarts"] > 1 and os.environ.get("HARNESS_ASSERT_LOCK") == "1":
            lock = Path(os.environ["E2E_LOCK_DIR"]) / "lock.model"
            with lock.open("a") as fd:
                try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    with hits.open("a") as out: out.write("restoring_lock_held\n")
                else: die()
        config["effective"] = dict(config["configured"])
        save_config(config)
    elif mode == "hook_restart" and not state.exists():
        state.write_text("failed"); hit("hook_restart", 86)
    if args[1] == "pglogtap-mx15":
        if not state.exists():
            state.write_text("preload")
            if mode == "restart_preload": hit("restart_preload", 87)
        else:
            state.write_text("guc")
            if mode == "restart_guc": hit("restart_guc", 87)
elif args[0] == "rm":
    if args[1:] not in (["-f", "receiver"], ["-f", "pglogtap-mx15"], ["-f", "-v", "pglogtap-mx15"], ["-f", "-v"]): die()
elif args[0] == "ps":
    if args[1:] != ["-aq", "--filter", "label=com.docker.compose.project=pglogtap-e2e", "--filter", "label=com.docker.compose.service=pg"]: die()
elif args[0] == "logs":
    if args[1:] not in (["model"], ["pglogtap-mx15"], ["--tail", "40", "pglogtap-mx15"]): die()
    count = int(state.read_text() or "0") if state.exists() else 0
    state.write_text(str(count + 1))
    if (mode == "hook_zero" or mode.startswith("hook_config")) and count:
        print("hookchain nested call")
elif args[0] == "exec":
    ct, cmd = exec_parts()
    if not cmd: die()
    if ct == "pgzx-build" and cmd == ["/usr/lib/postgresql/15/bin/pg_config", "--includedir-server"]:
        print("/headers")
    elif ct == "pgzx-build" and cmd == ["/opt/zig016/files/zig", "cc", "-shared", "-fPIC", "-Wno-ignored-attributes", "-I/headers", "/tmp/hookchain-model.c", "-o", "/tmp/hookchain-model.so"]:
        pass
    elif cmd[0] == "pg_isready":
        if cmd[1:] != ["-U", "postgres", "-h", "127.0.0.1"]: die()
        if mode in ("ready_create", "ready_preload", "ready_guc"):
            wanted = "ready_create" if not state.exists() else ("ready_preload" if state.read_text() == "preload" else "ready_guc")
            if mode == wanted:
                if not hits.exists():
                    with hits.open("a") as f: f.write(wanted + "\n")
                sys.exit(88)
    elif cmd[0] == "pg_config":
        if cmd[1:] == ["--pkglibdir"]:
            if mode == "pg_config_lib": hit("pg_config_lib", 89)
            print("/lib")
        elif cmd[1:] == ["--sharedir"]:
            if mode == "pg_config_share": hit("pg_config_share", 90)
            print("/share")
        else: die()
    elif cmd[0] == "bash":
        if len(cmd) != 3 or cmd[1] != "-c": die()
        body = cmd[2]
        if body in ("exec 3<>/dev/tcp/pglogtap-vector/8686", "exec 3<>/dev/tcp/receiver/8686"):
            wanted = "receiver_shared" if "pglogtap-vector" in body else "receiver_major"
            if mode == wanted: hit(wanted, 91)
        else:
            normalized = " ".join(body.split())
            pgbench_body = "pgbench -i -q -U postgres postgres >/dev/null 2>&1; pgbench -U postgres -c 8 -j 2 -T 1 postgres 2>&1 | grep tps"
            cluster_body = "set -euo pipefail timeout 30 createdb -U postgres probe timeout 30 createdb -U postgres -T template0 probe2 timeout 30 dropdb -U postgres probe timeout 30 dropdb -U postgres probe2 timeout 30 psql -X -U postgres -v ON_ERROR_STOP=1 -qc 'CREATE ROLE probe_r; DROP ROLE probe_r' timeout 30 psql -X -U postgres -v ON_ERROR_STOP=1 -qc 'CHECKPOINT'"
            if normalized == cluster_body:
                with hits.open("a") as f: f.write("cluster_ops\n")
                sys.exit(77 if mode == "cluster_ops" else 0)
            if normalized not in ("set -euo pipefail; " + pgbench_body, pgbench_body): die()
            child_env = os.environ.copy()
            child_env.pop("SHELLOPTS", None); child_env.pop("BASHOPTS", None)
            sys.exit(subprocess.run(["bash", "-c", body], env=child_env).returncode)
    elif cmd[0] == "psql":
        rest = cmd[1:]
        if (rest[:5] == ["-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1"] and len(rest) == 9
                and rest[5] == "-v" and rest[6].startswith("guc=")
                and rest[7] == "-v" and rest[8].startswith("value=")):
            name, value = rest[6][4:], rest[8][6:]
            if name not in ("pg_logtap.export_url", "pg_logtap.export_fallback_file", "pg_logtap.message_max"):
                die()
            if sys.stdin.read() != "SELECT format('ALTER SYSTEM SET %s = %L', :'guc', :'value')\n\\gexec\n":
                die()
            if not config_mode:
                if name != "pg_logtap.export_url": die()
                sys.exit(0)
            config = config_state()
            if name == os.environ.get("HARNESS_FAIL_SETGUC"):
                sys.exit(86)
            config["configured"][name] = value; save_config(config)
            requested = os.environ.get("HARNESS_SIGNAL")
            if requested and not config.get("signaled"):
                config["signaled"] = True; save_config(config)
                os.kill(os.getppid(), getattr(signal, "SIG" + requested))
            sys.exit(0)
        if rest[:3] == ["-U", "postgres", "-Atc"] and len(rest) == 4:
            statements = [rest[3]]
        elif rest[:5] == ["-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1"]:
            rest = rest[5:]
            if rest[:1] == ["-Atc"] and len(rest) == 2:
                statements = [rest[1]]
            elif len(rest) >= 2 and len(rest) % 2 == 0 and all(rest[i] == "-qc" for i in range(0, len(rest), 2)):
                statements = rest[1::2]
            elif len(rest) >= 3 and len(rest) % 2 == 1 and rest[0] == "-qAt" and all(rest[i] == "-c" for i in range(1, len(rest), 2)):
                statements = rest[2::2]
            else: die()
        else: die()
        normalized = [" ".join(statement.split()) for statement in statements]
        allowed = {
            "SELECT 1", "SELECT pg_logtap_version()", "SELECT pg_logtap_stats()",
            "SELECT pid || ' ' || backend_type FROM pg_stat_activity WHERE backend_type LIKE '%logtap%'",
            "SHOW server_version", "SHOW shared_preload_libraries", "SHOW pg_logtap.export_url",
            "SHOW pg_logtap.export_fallback_file", "SHOW pg_logtap.message_max",
            "SELECT hookchain_shmem_ready()", "SELECT hookchain_count()", "SELECT hookchain_arm(true)", "SELECT hookchain_arm(false)",
            "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]",
            "ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'", "ALTER SYSTEM SET cluster_name = 'matrix-pg15'",
            "ALTER SYSTEM SET pg_logtap.ring_capacity = 8192", "ALTER SYSTEM SET pg_logtap.flush_interval = 100",
            "CREATE EXTENSION pg_logtap", "ALTER SYSTEM SET pg_logtap.export_url = 'http://pglogtap-vector:8686'",
            "ALTER SYSTEM SET log_min_duration_statement = 0", "ALTER SYSTEM SET log_min_messages = 'debug1'",
            "ALTER SYSTEM SET pg_logtap.level_min = 10", "ALTER SYSTEM SET log_min_duration_statement = -1",
            "ALTER SYSTEM SET log_min_messages = 'warning'", "ALTER SYSTEM SET pg_logtap.level_min = 15",
            "SELECT pg_reload_conf()", "ALTER SYSTEM SET shared_preload_libraries = 'hookchain', 'pg_logtap'",
            "ALTER SYSTEM SET shared_preload_libraries = 'oldpreload'", "ALTER SYSTEM RESET shared_preload_libraries",
            "ALTER SYSTEM SET pg_logtap.export_url = 'oldurl'", "ALTER SYSTEM SET pg_logtap.export_url = ''",
            "CREATE OR REPLACE FUNCTION public.hookchain_count() RETURNS integer AS '$libdir/hookchain', 'hookchain_count' LANGUAGE C STRICT",
            "CREATE OR REPLACE FUNCTION public.hookchain_shmem_ready() RETURNS boolean AS '$libdir/hookchain', 'hookchain_shmem_ready' LANGUAGE C STRICT",
            "CREATE OR REPLACE FUNCTION public.hookchain_arm(boolean) RETURNS integer AS '$libdir/hookchain', 'hookchain_arm' LANGUAGE C STRICT",
            "DO $$ DECLARE i int := 0; BEGIN WHILE i < 5 LOOP RAISE WARNING 'logtap hook %', i; i := i + 1; END LOOP; END $$",
            "DO $$ BEGIN RAISE WARNING 'logtap hookchain-armed'; END $$",
            "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%\"message\":\"logtap hook %'",
            "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%\"message\":\"logtap hookchain-armed%'",
            "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%hookchain nested%'",
        }
        if any(statement not in allowed for statement in normalized): die()
        if config_mode:
            config = config_state()
            if normalized == [
                "SELECT hookchain_count()",
                "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]",
                "DO $$ DECLARE i int := 0; BEGIN WHILE i < 5 LOOP RAISE WARNING 'logtap hook %', i; i := i + 1; END LOOP; END $$",
                "SELECT hookchain_count()",
                "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]",
            ]:
                print("0\n0\n5\n5")
            elif normalized == [
                "SELECT hookchain_count()", "SELECT hookchain_arm(true)",
                "DO $$ BEGIN RAISE WARNING 'logtap hookchain-armed'; END $$",
                "SELECT hookchain_count()", "SELECT hookchain_arm(false)",
            ]:
                print("0\n1\n2\n3")
            else:
                for statement in normalized:
                    if statement == "SHOW server_version":
                        print("15.0")
                    elif statement in ("SHOW shared_preload_libraries", "SHOW pg_logtap.export_url",
                                       "SHOW pg_logtap.export_fallback_file", "SHOW pg_logtap.message_max"):
                        print(config["effective"][statement[5:]])
                    elif statement == "ALTER SYSTEM SET shared_preload_libraries = 'hookchain', 'pg_logtap'":
                        config["configured"]["shared_preload_libraries"] = "hookchain, pg_logtap"
                    elif statement == "ALTER SYSTEM SET shared_preload_libraries = 'oldpreload'":
                        if os.environ.get("HARNESS_FAIL_PRELOAD_RESTORE") == "1": sys.exit(86)
                        config["configured"]["shared_preload_libraries"] = "oldpreload"
                    elif statement == "ALTER SYSTEM RESET shared_preload_libraries":
                        if os.environ.get("HARNESS_FAIL_PRELOAD_RESTORE") == "1": sys.exit(86)
                        config["configured"]["shared_preload_libraries"] = ""
                    elif statement == "ALTER SYSTEM SET pg_logtap.export_url = ''":
                        config["configured"]["pg_logtap.export_url"] = ""
                    elif statement == "SELECT 1": print("1")
                    elif statement == "SELECT pg_logtap_version()": print(os.environ["HARNESS_VERSION"])
                    elif statement == "SELECT pg_logtap_stats()": print("events_captured=0 events_dropped=0 events_sent=0 send_cycles_failed=0")
                    elif statement == "SELECT hookchain_shmem_ready()": print("t")
                    elif statement == "SELECT hookchain_count()": print("0")
                    elif statement == "SELECT hookchain_arm(true)": print("1")
                    elif statement == "SELECT hookchain_arm(false)": print("3")
                    elif statement == "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]": print("0")
                    elif statement == "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%\"message\":\"logtap hook %'": print("5")
                    elif statement == "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%\"message\":\"logtap hookchain-armed%'": print("1")
                    elif statement == "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%hookchain nested%'": print("0")
                    elif statement in allowed:
                        pass
                    else: die()
            save_config(config)
            sys.exit(0)
        if normalized == ["SELECT 1"]: print("1")
        elif normalized == ["SELECT pg_logtap_version()"]: print(os.environ["HARNESS_VERSION"])
        elif normalized == ["SHOW server_version"]: print("15.0")
        elif normalized == ["SHOW shared_preload_libraries"]: print("oldpreload")
        elif normalized == ["SHOW pg_logtap.export_url"]: print("oldurl" if not state.exists() else "mutated-url")
        elif normalized == ["SELECT hookchain_shmem_ready()"]: print("t")
        elif normalized == [
            "SELECT hookchain_count()",
            "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]",
            "DO $$ DECLARE i int := 0; BEGIN WHILE i < 5 LOOP RAISE WARNING 'logtap hook %', i; i := i + 1; END LOOP; END $$",
            "SELECT hookchain_count()",
            "SELECT (regexp_match(pg_logtap_stats(), 'events_captured=([0-9]+)'))[1]",
        ]: print("0\n0\n5\n5")
        elif normalized == [
            "SELECT hookchain_count()", "SELECT hookchain_arm(true)",
            "DO $$ BEGIN RAISE WARNING 'logtap hookchain-armed'; END $$",
            "SELECT hookchain_count()", "SELECT hookchain_arm(false)",
        ]: print("0\n1\n2\n3")
        elif normalized == ["SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%\"message\":\"logtap hook %'"]: print("5")
        elif normalized == ["SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%\"message\":\"logtap hookchain-armed%'"]: print("1")
        elif normalized == ["SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE line LIKE '%hookchain nested%'"]: print("0")
        elif normalized == ["SELECT pg_logtap_stats()"]: print("events_captured=0 events_dropped=0 events_sent=0 send_cycles_failed=0")
        elif "ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'" in normalized:
            if mode == "sql_preload": hit("sql_preload", 92)
        elif "ALTER SYSTEM SET pg_logtap.ring_capacity = 8192" in normalized:
            if mode == "sql_guc": hit("sql_guc", 93)
        elif normalized == ["CREATE EXTENSION pg_logtap"]:
            if mode == "sql_ext": hit("sql_ext", 94)
    elif cmd[0] == "sh":
        if cmd != ["sh", "-c", "rm -f '/lib/hookchain.so'"]: die()
    elif cmd[0] == "test":
        if cmd[1:] != ["-x", "/fixture/python"]: die()
    elif cmd[0] == "kill":
        if len(cmd) != 3 or cmd[1] != "-TERM" or not re.fullmatch(r"[0-9]+", cmd[2]): die()
    elif cmd[0] == "cat":
        if len(cmd) != 2 or not re.fullmatch(r"/proc/[0-9]+/status", cmd[1]): die()
    else: die()
else: die()
''')
    write_exe(bindir / "sleep", "#!/bin/sh\nexit 0\n")
    write_exe(bindir / "zig", """#!/bin/sh
printf '["zig", "%s"]\\n' "$*" >> "$HARNESS_LOG"
case "$1:$#" in
  build:5)
    [ "$2" = -Dtarget=x86_64-linux-gnu.2.28 ] && [ "$3" = -Doptimize=ReleaseSafe ] && [ "$4" = -p ] && [ "$5" = dist/pg15 ] || exit 97 ;;
  build:3)
    [ "$2" = -p ] && [ "$3" = dist/pg15 ] || exit 97
    if [ "${HARNESS_MODE:-}" = build ]; then printf 'build\n' >> "$HARNESS_HITS"; exit 86; fi ;;
  cc:8)
    [ "$2" = -shared ] && [ "$3" = -fPIC ] && [ "$4" = -Wno-ignored-attributes ] && [ "$5" = -I/headers ] && [ "$6" = tests/e2e/hookchain.c ] && [ "$7" = -o ] || exit 97
    case "$8" in /tmp/*/out/hookchain/hookchain.so) : ;; *) exit 97 ;; esac ;;
  *) exit 97 ;;
esac
exit 0
""")
    write_exe(bindir / "pgbench", """#!/bin/sh
case " ${*} " in
  *' -i '*) [ "${HARNESS_MODE:-}" = pgbench_init ] && exit 95 ;;
  *) case "${HARNESS_MODE:-}" in pgbench_init) echo 'tps = 1' ;; pgbench_run) echo 'tps = 1'; exit 96 ;; esac ;;
esac
exit 0
""")
    write_exe(bindir / "pg_config", """#!/bin/sh
case "$1" in
  --version) echo 'PostgreSQL 15.0' ;;
  --includedir-server) echo /headers ;;
  *) exit 97 ;;
esac
""")
    write_exe(bindir / "objcopy", """#!/bin/sh
case "$1" in
  --version) echo GNU ;;
  --only-keep-debug|--strip-debug|--add-gnu-debuglink=*) ;;
  *) exit 97 ;;
esac
""")
    write_exe(bindir / "readelf", "#!/bin/sh\ncase \"$*\" in *.debug*) echo ' .debug_info' ;; *'-S -W '*) echo ' .gnu_debuglink' ;; *) exit 97 ;; esac\n")
    return bindir


def env_for(tmp, mode=""):
    (tmp / "locks").mkdir()
    version = re.search(r'^pub const version = "([^"]+)";',
                        (ROOT / "src/version.zig").read_text(), re.M).group(1)
    return {
        **os.environ,
        "PATH": str(fixture_bin(tmp)) + ":/usr/bin:/bin",
        "HARNESS_LOG": str(tmp / "calls.jsonl"),
        "HARNESS_STATE": str(tmp / "state"),
        "HARNESS_HITS": str(tmp / "hits"),
        "HARNESS_GUCS": str(tmp / "gucs.json"),
        "HARNESS_INITIAL_GUCS": json.dumps({
            "shared_preload_libraries": "oldpreload",
            "pg_logtap.export_url": "oldurl",
            "pg_logtap.export_fallback_file": "",
            "pg_logtap.message_max": "1024",
        }),
        "HARNESS_VERSION": version,
        "HARNESS_MODE": mode,
        "E2E_LOCK_DIR": str(tmp / "locks"),
        "PG_CONFIG": str(tmp / "bin/pg_config"),
    }


def calls(env):
    path = Path(env["HARNESS_LOG"])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def joined(env):
    return [" ".join(parts) for parts in calls(env)]


def hits(env):
    path = Path(env["HARNESS_HITS"])
    return path.read_text().splitlines() if path.exists() else []


def require_failed(result, label):
    if result.returncode == 0 or "AFTER" in result.stdout:
        fail(f"{label}: mandatory failure reached a following phase: rc={result.returncode}, out={result.stdout!r}")


def test_common_gates():
    for mode, body, required, forbidden in [
        ("freshness", "e2e_gate", "e2e-require-ext.sh", "docker start"),
        ("receiver_start", "e2e_gate", "", "AFTER"),
        ("gen", "gen probe 1", "psql FAILED", "AFTER"),
    ]:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            env = env_for(tmp)
            driver = tmp / "driver.sh"
            (tmp / "e2e-require-ext.sh").write_text("#!/bin/sh\nprintf '[\"freshness\"]\\n' >> \"$HARNESS_LOG\"\nexit 73\n" if mode == "freshness" else "#!/bin/sh\nexit 0\n")
            (tmp / "e2e-require-ext.sh").chmod(0o755)
            if mode in ("gen", "receiver_start"):
                env["HARNESS_MODE"] = mode
            driver.write_text(f'''#!/bin/sh
set -eu
E2E_TAG=gate E2E_CT=model NET=net VEC=receiver E2E_SUF=-test
. "{ROOT / 'tests/e2e/e2e-common.sh'}"
{body} || exit $?
printf AFTER
''')
            # The same fake below recognizes the actual psql boundary; force it
            # only for this probe, rather than replacing the shell helper.
            docker = Path(env["PATH"].split(":", 1)[0]) / "docker"
            text = docker.read_text()
            docker.write_text(text.replace('elif cmd[0] == "psql":',
                'elif cmd[0] == "psql":\n        if mode == "gen" and "DO $$" in " ".join(cmd): sys.exit(74)'))
            result = run(["/bin/sh", str(driver)], env=env)
            require_failed(result, "common " + mode)
            if mode == "freshness" and ["freshness"] not in calls(env):
                fail("common freshness: did not reach the actual freshness boundary")
            if mode == "gen" and required not in (result.stderr + result.stdout):
                fail("common gen: did not reach the actual psql boundary")
            if forbidden != "AFTER" and any(forbidden in item for item in joined(env)):
                fail(f"common {mode}: ran forbidden later command {forbidden}")

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = env_for(tmp, "optional_network")
        helper = tmp / "e2e-require-ext.sh"
        helper.write_text("#!/bin/sh\nexit 0\n")
        helper.chmod(0o755)
        driver = tmp / "driver.sh"
        driver.write_text(f'''#!/bin/sh
set -eu
E2E_TAG=gate E2E_CT=model NET=net VEC=receiver
. "{ROOT / 'tests/e2e/e2e-common.sh'}"
e2e_gate || exit $?
printf AFTER
''')
        result = run(["/bin/sh", str(driver)], env=env)
        if result.returncode or "AFTER" not in result.stdout:
            fail("common optional network connect stopped an otherwise valid gate")


def test_source_guards():
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = env_for(tmp)
        for source, script, symbol in ((ROOT / "tests/e2e/test-matrix.sh", "test-matrix.sh", "phase_stand"),
                                       (ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_job"),
                                       (ROOT / "tests/e2e/storm.sh", "storm.sh", "run_mode"),
                                       (ROOT / "scripts/dev-deploy.sh", "dev-deploy.sh", "main")):
            check = f'''before_pwd= before_opts= before_vars= before_traps=
before_pwd=$PWD
before_opts=$(set +o)
before_vars=$(compgen -v | sort)
before_traps=$(trap -p)
source "{source}"
[ "$PWD" = "$before_pwd" ] || exit 41
[ "$(set +o)" = "$before_opts" ] || exit 42
[ "$(compgen -v | sort)" = "$before_vars" ] || exit 43
[ "$(trap -p)" = "$before_traps" ] || exit 44
declare -F {symbol}
printf IMPORTED'''
            result = run(["/usr/bin/env", "bash", "-c", check], env=env, cwd=tmp)
            if result.returncode or "IMPORTED" not in result.stdout:
                fail(f"{script}: source/import changed shell state or dispatched: {result.stderr}")
        if calls(env):
            fail("source/import touched an external command")


def test_container_locks():
    # Real flock, actual sourced e2e_lock, no Docker or shared container names.
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = {**os.environ}
        env.pop("E2E_LOCK_DIR", None)
        key = f"task8-selftest-{os.getpid()}"
        driver = tmp / "lock.sh"
        driver.write_text(f'''#!/bin/sh
set -eu
. "{ROOT / 'tests/e2e/e2e-common.sh'}"
OUT=$1 E2E_CT=$2 E2E_TAG=selftest
mkdir -p "$OUT"
e2e_lock
printf 'ACQUIRED\\n'
[ "${{3:-}}" != hold ] || read -r release
''')
        holder = subprocess.Popen(["sh", str(driver), str(tmp / "a"), key, "hold"],
                                  env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert holder.stdout.readline() == "ACQUIRED\n", "real lock holder failed"
            same = run(["sh", str(driver), str(tmp / "a"), key], env=env)
            other = run(["sh", str(driver), str(tmp / "a"), key + "-other"], env=env)
            different_out = run(["sh", str(driver), str(tmp / "b"), key], env=env)
            assert same.returncode == 1 and "another e2e holds" in same.stderr, same
            assert other.returncode == 0 and "ACQUIRED" in other.stdout, other
            assert different_out.returncode == 1 and "another e2e holds" in different_out.stderr, (
                "same container acquired through different output roots", different_out)
        finally:
            holder.communicate("release\n", timeout=5)
            # Only this test's fictional keys, never anybody else's lock files.
            for name in (key, key + "-other"):
                Path(f"/tmp/logtap-e2e-locks/lock.{name}").unlink(missing_ok=True)


def test_lock_cooperation():
    errors = []
    for source, script, key, body in (
        (ROOT / "tests/e2e/test-matrix.sh", "test-matrix.sh", "pglogtap-mx15", 'OUT="$HARNESS_OUT"; COMPOSE="docker compose -f tests/e2e/compose.yaml"; FLAGS=(); phase_stand 15'),
        (ROOT / "tests/e2e/test-matrix.sh", "test-matrix.sh", "pglogtap-mx15", 'OUT="$HARNESS_OUT"; phase_storm 15 1'),
        (ROOT / "tests/e2e/test-matrix.sh", "test-matrix.sh", "pglogtap-mx15", 'phase_cluster_ops 15'),
        (ROOT / "tests/e2e/test-matrix.sh", "test-matrix.sh", "pglogtap-mx15", 'PHASES=none; STATUS=0; run_version 15'),
        (ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "model", 'main 1 model'),
        (ROOT / "scripts/dev-deploy.sh", "dev-deploy.sh", "model", None),
        (ROOT / "tests/e2e/storm.sh", "storm.sh", "pglogtap-mx15", 'main 1 15 loud'),
    ):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            env = env_for(tmp)
            env["HARNESS_OUT"] = str(tmp / "out")
            Path(env["HARNESS_OUT"]).mkdir()
            holder_body = f'. "{ROOT / "tests/e2e/e2e-common.sh"}"; E2E_CT={key}; E2E_TAG=selftest; e2e_lock; printf "ACQUIRED\\n"; read -r release'
            holder = subprocess.Popen(["sh", "-c", holder_body], env=env, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert holder.stdout.readline() == "ACQUIRED\n", "cooperation holder failed"
                command = (["bash", str(source), key] if body is None else
                           ["bash", "-c", f'source "{source}"; {body}'])
                result = run(command, env=env)
                if result.returncode == 0 or "another e2e holds" not in result.stderr or calls(env):
                    errors.append(f"{script} bypassed suite lock: rc={result.returncode}, external calls={calls(env)}, stderr={result.stderr!r}")
            finally:
                holder.communicate("release\n", timeout=5)
    if errors:
        fail("; ".join(errors))


def test_matrix_native_lock_lifecycle():
    for phase, fault in (("storm", ""), ("storm", "pgbench_run"), ("cluster-ops", ""),
                         ("cluster-ops", "cluster_ops"), ("none", "")):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp, fault)
            write_exe(tmp / "bin/pgbench", '''#!/bin/sh
case "$*" in
  '-i -q -U postgres postgres') exit 0 ;;
  '-U postgres -c 8 -j 2 -T 1 postgres') printf 'tps = 1\\n'; [ "$HARNESS_MODE" != pgbench_run ] ;;
  *) exit 97 ;;
esac
''')
            driver = f'''set -euo pipefail
source "{ROOT / 'tests/e2e/test-matrix.sh'}"
OUT="{tmp}"; E2E_OUT="$OUT"; E2E_VECTOR=''; STATUS=0; SECS=1; PHASES={phase}
run_version 15 || exit $?
timeout 3 sh -c '. "{ROOT / 'tests/e2e/e2e-common.sh'}"; E2E_CT=pglogtap-mx15; E2E_TAG=child; e2e_lock; e2e_stand_lock; printf CHILD'
'''
            result = run(["bash", "-c", driver], env=env)
            entries = calls(env)
            if phase == "cluster-ops": assert hits(env) == ["cluster_ops"], (phase, fault, result, entries)
            if phase == "storm": assert any(x[:3] == ["exec", "pglogtap-mx15", "bash"] for x in entries), entries
            removed = ["rm", "-f", "pglogtap-mx15"] in entries
            assert (result.returncode != 0 and not removed and "CHILD" not in result.stdout) if fault else (
                result.returncode == 0 and removed and "CHILD" in result.stdout), (phase, fault, result, entries)

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw); env = env_for(tmp)
        holder_body = f'. "{ROOT / "tests/e2e/e2e-common.sh"}"; e2e_stand_lock; printf "HELD\\n"; read -r release'
        holder = subprocess.Popen(["sh", "-c", holder_body], env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        contender = None
        try:
            assert holder.stdout.readline() == b"HELD\n"
            retained = run(["bash", "-c", f'source "{ROOT / "tests/e2e/test-matrix.sh"}"; STATUS=1; COMPOSE="docker compose -f tests/e2e/compose.yaml"; cleanup'], env=env)
            assert retained.returncode == 0 and not calls(env), ("failed stand cleanup", retained, calls(env))
            body = f'source "{ROOT / "tests/e2e/test-matrix.sh"}"; STATUS=0; COMPOSE="docker compose -f tests/e2e/compose.yaml"; printf "BEGIN\\n"; cleanup; printf "AFTER\\n"'
            contender = subprocess.Popen(["bash", "-c", body], env=env, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            assert contender.stdout.readline() == b"BEGIN\n"
            assert not select.select([contender.stdout], [], [], .15)[0] and not calls(env), (
                "compose cleanup bypassed the shared stand lock", calls(env))
            holder.communicate(b"release\n", timeout=5)
            out, err = contender.communicate(timeout=5)
            assert contender.returncode == 0 and out == b"AFTER\n" and calls(env) == [
                ["compose", "-f", "tests/e2e/compose.yaml", "down"]], (out, err, calls(env))
        finally:
            if holder.poll() is None: holder.communicate(b"release\n", timeout=5)
            if contender is not None and contender.poll() is None: contender.communicate(timeout=5)


def test_major_selection():
    # A matching PATH pg_config must not hide a conflicting effective override.
    errors = []
    for source, script, body in ((ROOT / "tests/e2e/test-matrix.sh", "test-matrix.sh", 'FLAGS=(); COMPOSE="docker compose -f tests/e2e/compose.yaml"; phase_stand 15'),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", 'V=15; ZIG_TARGET=x86_64-linux-gnu.2.28; build_extension')):
        for mode, override, wanted in (("matching", "", "host"), ("mismatch", "", "container"),
                                       ("absent", "", "container"), ("missing_override", "/missing/pg_config", "container"),
                                       ("conflict", "override", "container"), ("override_match", "override", "host")):
            with tempfile.TemporaryDirectory() as raw:
                tmp = Path(raw); env = env_for(tmp)
                scripts = tmp / "scripts"; scripts.mkdir()
                (tmp / "sql").mkdir(); (tmp / "sql/pg_logtap--0.6.1.sql").touch()
                write_exe(scripts / "build.sh", '''#!/bin/sh
[ "$1" = 15 ] || exit 97
shift
case "$*" in ''|'-Dtarget=x86_64-linux-gnu.2.28 -Doptimize=ReleaseSafe') ;; *) exit 97 ;; esac
printf '["container-build", "15"]\\n' >> "$HARNESS_LOG"
mkdir -p zig-out/lib
printf fixture > zig-out/lib/pg_logtap.so
''')
                bindir = Path(env["PATH"].split(":", 1)[0])
                host_major = 18 if mode in ("mismatch", "override_match") else 15
                (bindir / "pg_config").write_text(f'#!/bin/sh\n[ "$1" = --version ] || exit 97\necho "PostgreSQL {host_major}.0"\n')
                env.pop("PG_CONFIG", None)
                if mode == "absent":
                    (bindir / "pg_config").unlink()
                    # A genuinely absent PATH toolchain, not the host's /usr/bin fallback.
                    for name in ("bash", "sh", "dirname", "mkdir", "cp", "rm", "sed", "grep", "xargs", "seq"):
                        (bindir / name).symlink_to(Path("/usr/bin") / name)
                    (bindir / "python3").symlink_to(sys.executable)
                    (bindir / "flock").symlink_to("/usr/bin/flock")
                    env["PATH"] = str(bindir)
                if override == "override":
                    write_exe(bindir / "override", f'#!/bin/sh\n[ "$1" = --version ] || exit 97\necho "PostgreSQL {15 if mode == "override_match" else 18}.0"\n')
                    env["PG_CONFIG"] = str(bindir / "override")
                elif override:
                    env["PG_CONFIG"] = override
                driver = f'set -euo pipefail; source "{source}"; OUT="{tmp / "out"}"; mkdir -p "$OUT"; {body}'
                result = run(["bash", "-c", driver], env=env, cwd=tmp)
                chosen = [c[0] for c in calls(env) if c[0] in ("zig", "container-build")]
                expected = ["zig" if wanted == "host" else "container-build"]
                if result.returncode or chosen != expected:
                    errors.append(f"{script}/{mode}: chosen={chosen}, expected={expected}, rc={result.returncode}, stderr={result.stderr!r}")
    if errors:
        fail("; ".join(errors))


def test_hook_major_selection():
    errors = []
    for mode in ("matching", "mismatch", "missing_override", "conflict", "matching_override"):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp, "hook_zero")
            env["E2E_OUT"] = str(tmp / "out")
            env.pop("PG_CONFIG", None)
            bindir = Path(env["PATH"].split(":", 1)[0])
            if mode in ("mismatch", "matching_override"):
                pgc = bindir / "pg_config"
                pgc.write_text(pgc.read_text().replace("PostgreSQL 15.0", "PostgreSQL 18.0"))
            if mode == "missing_override":
                env["PG_CONFIG"] = "/missing/pg_config"
            elif mode in ("conflict", "matching_override"):
                write_exe(bindir / "override", f'#!/bin/sh\ncase "$1" in --version) echo "PostgreSQL {15 if mode == "matching_override" else 18}.0" ;; --includedir-server) echo /headers ;; *) exit 97 ;; esac\n')
                env["PG_CONFIG"] = str(bindir / "override")
            result = run(["sh", str(ROOT / "tests/e2e/e2e-hook-chain.sh"), "model"], env=env)
            host = any(c[0] == "zig" and c[1].startswith("cc ") for c in calls(env))
            container = any(c[:3] == ["exec", "pgzx-build", "/opt/zig016/files/zig"] for c in calls(env))
            want_host = mode in ("matching", "matching_override")
            if result.returncode or host != want_host or container == want_host:
                errors.append(f"hook/{mode}: rc={result.returncode}, host={host}, container={container}, stderr={result.stderr!r}")
    if errors:
        fail("; ".join(errors))


def test_deploy_major_selection():
    errors = []
    for state, override in (("running", False), ("running", True), ("stopped", True), ("unknown", True), ("build_failure", True)):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp)
            env["HARNESS_DEPLOY_STATE"] = state
            env.pop("PG_CONFIG", None)
            if override:
                env["PG_CONFIG"] = "/missing/pg_config"
            scripts = tmp / "scripts"; scripts.mkdir()
            checks = tmp / "tests/e2e"; checks.mkdir(parents=True)
            (tmp / "sql").mkdir(); (tmp / "sql/pg_logtap--0.6.1.sql").touch()
            write_exe(scripts / "build.sh", '''#!/bin/sh
[ "$#" = 2 ] && [ "$2" = -Doptimize=ReleaseSafe ] || exit 97
case "$1" in 15|18) ;; *) exit 97 ;; esac
printf '["container-build", "%s"]\\n' "$1" >> "$HARNESS_LOG"
[ "$HARNESS_DEPLOY_STATE" != build_failure ] || exit 76
''')
            write_exe(checks / "e2e-require-ext.sh", '#!/bin/sh\n[ "$#" = 1 ] && [ "$1" = model ] || exit 97\n')
            bindir = Path(env["PATH"].split(":", 1)[0])
            write_exe(bindir / "zig", '#!/bin/sh\n[ "$*" = "build -Doptimize=ReleaseSafe" ] || exit 97\nprintf \'["host-build", "15"]\\n\' >> "$HARNESS_LOG"\n')
            write_exe(bindir / "docker", r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
a=sys.argv[1:]
with open(os.environ["HARNESS_LOG"], "a") as f: f.write(json.dumps(a)+"\n")
def die(): sys.exit(97)
state=os.environ["HARNESS_DEPLOY_STATE"]
if a == ["exec", "model", "true"]: sys.exit(0 if state == "running" else 1)
if a == ["exec", "model", "pg_config", "--version"]: print("PostgreSQL 15.14 (Debian)")
elif a == ["exec", "model", "pg_config", "--pkglibdir"]: print("/lib")
elif a == ["exec", "model", "pg_config", "--sharedir"]: print("/share")
elif a == ["inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", "model"]:
    print("PATH=/usr/lib/postgresql/15/bin:/usr/bin\nPOSTGRES_DB=postgres\n" + ("PG_MAJOR=15\nPG_VERSION=15.14" if state != "unknown" else "PG_VERSION=unknown"))
elif a == ["restart", "model"]: pass
elif len(a) == 3 and a[0] == "cp":
    src,dst=a[1:]
    if src == "zig-out/lib/pg_logtap.so":
        if dst not in ("model:/lib/", "model:/usr/lib/postgresql/15/lib/", "model:/usr/lib/postgresql/18/lib/"): die()
    elif src == "pg_logtap.control" or re.fullmatch(r"sql/pg_logtap--[0-9.]+\.sql",src):
        if dst not in ("model:/share/extension/", "model:/usr/share/postgresql/15/extension/", "model:/usr/share/postgresql/18/extension/"): die()
    else: die()
else: die()
''')
            # argv[0] points into this private stand, so main's existing cd stays private.
            command = ["bash", "-c", f'source "{ROOT / "scripts/dev-deploy.sh"}"; main model || exit $?', str(scripts / "driver.sh")]
            result = run(command, env=env, cwd=tmp)
            builds = [c for c in calls(env) if c[0] in ("container-build", "host-build")]
            copies = [c for c in calls(env) if c[:2] == ["cp", "zig-out/lib/pg_logtap.so"]]
            if state == "unknown":
                valid = result.returncode != 0 and not builds and not copies and "major" in result.stderr
            elif state == "build_failure":
                valid = result.returncode != 0 and builds == [["container-build", "15"]] and not copies
            else:
                valid = result.returncode == 0 and builds == [["container-build" if override else "host-build", "15"]] and len(copies) == 1
                if state == "stopped": valid = valid and copies[0][2] == "model:/usr/lib/postgresql/15/lib/"
            if not valid:
                errors.append(f"deploy/{state}/override={override}: rc={result.returncode}, builds={builds}, copies={copies}, stderr={result.stderr!r}")
    if errors:
        fail("; ".join(errors))


def test_current_run_duplicates():
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw); sink = tmp / "vector-out.jsonl"
        old = [{"seq": 1, "message": "logtap robust panic3-old 0"}] * 2
        current = [{"seq": 2, "message": "logtap robust panic3-run 0"},
                   {"seq": 3, "message": "logtap robust huge-run 0"}]
        driver = f'. "{ROOT / "tests/e2e/e2e-common.sh"}"; OUT="{tmp}"; E2E_TAG=robust; E2E_SUF=-run; duplicate_seqs'
        for extra, expected in (([], 0), ([current[0]], 1)):
            sink.write_text("".join(json.dumps(event, separators=(",", ":")) + "\n" for event in old + current + extra))
            result = run(["sh", "-c", driver], env=os.environ.copy())
            assert result.returncode == 0 and int(result.stdout) == expected, (
                f"historical duplicates contaminated current run: expected {expected}", result)


EXPORT_SNAPSHOT_SQL = """SELECT extract(epoch FROM pg_postmaster_start_time())::text || ' ' ||
encode(convert_to(current_setting('pg_logtap.export_fallback_file'), 'UTF8'), 'hex') || ' ' ||
CASE WHEN current_setting('pg_logtap.export_fallback_file') = '' THEN '0'
ELSE coalesce((pg_stat_file(current_setting('pg_logtap.export_fallback_file'), true)).size, 0)::text END
|| ' ' || coalesce((SELECT CASE WHEN count(*) = 1 THEN min(pid)::text || ' ' ||
extract(epoch FROM min(backend_start))::text END
FROM pg_stat_activity WHERE backend_type = 'pg_logtap exporter'), '0 0')
|| ' ' || pg_logtap_stats()"""


def export_epoch_env(tmp, rows):
    env = env_for(tmp)
    env["HARNESS_EXPORT_SQL"] = EXPORT_SNAPSHOT_SQL
    Path(env["HARNESS_STATE"]).write_text(json.dumps(rows))
    bindir = Path(env["PATH"].split(":", 1)[0])
    write_exe(bindir / "sleep", '#!/usr/bin/env python3\nimport sys\nassert sys.argv[1:]==["1"]\n')
    write_exe(bindir / "docker", r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
with open(os.environ["HARNESS_LOG"],"a") as f: f.write(json.dumps(a)+"\n")
assert a[:1]==["exec"] and a[1] in ("model","other")
assert a[2:]==["psql","-X","-U","postgres","-v","ON_ERROR_STOP=1","-Atc",os.environ["HARNESS_EXPORT_SQL"]]
p=Path(os.environ["HARNESS_STATE"]); rows=json.loads(p.read_text())
h=Path(os.environ["HARNESS_HITS"]); n=len(h.read_text().splitlines()) if h.exists() else 0
with h.open("a") as f: f.write("snapshot\n")
s=rows[min(n,len(rows)-1)]
if s.get("error"): sys.exit(79)
workers=s.get("workers",[dict(pid=700,start="101.000000")])
identity="0 0"
if len(workers)==1 and workers[0]["pid"] is not None and workers[0]["start"] is not None:
    identity=str(workers[0]["pid"])+" "+str(workers[0]["start"])
print(str(s.get("epoch","100.000000"))+" "+s.get("path","2f7175657565")+" "+str(s.get("bytes",0))+" "+identity+" "+
      " ".join(name+"="+str(s.get(key,0)) for name,key in
      (("events_captured","cap"),("events_sent","sent"),("events_queued","queued"),
       ("events_replayed","replayed"),("events_compacted","compacted"),("events_lost","lost"),
       ("ring_events","ring"),("fallback_broken","broken"))))
''')
    return env


def test_export_epoch_accounting():
    # Removing replay from the actual conservation equation must fail the replay
    # control; accepting a boolean/history tuple must fail the unknown control.
    replay = dict(cap=10, queued=10, replayed=10)
    cases = [
        ("live", [{}, dict(cap=10,sent=10)], "e2e_export_begin || exit $?", True, 2),
        ("replay", [{}, replay], "e2e_export_begin || exit $?", True, 2),
        ("compacted", [{}, dict(cap=10,queued=10,compacted=10,lost=10)], "e2e_export_begin || exit $?", True, 2),
        ("discarded", [{}, dict(cap=10,queued=10,lost=10)], "e2e_export_begin || exit $?", True, 2),
        ("queue_pending", [{}, dict(cap=10,queued=10,bytes=512)], "e2e_export_begin || exit $?", False, 61),
        ("ram_inflight", [{}, dict(cap=10)], "e2e_export_begin || exit $?", False, 61),
        ("ring_pending", [{}, dict(cap=10,ring=10)], "e2e_export_begin || exit $?", False, 61),
        ("not_greater_equal", [{}, dict(cap=10,queued=20,replayed=20)], "e2e_export_begin || exit $?", False, 2),
        ("unknown_identical_replay", [replay], "E2E_EXPORT_EPOCH=1", False, 1),
        ("old_credited", [dict(queued=10,replayed=10)], "e2e_export_begin || exit $?", False, 1),
        ("old_compacted", [dict(queued=10,compacted=10,lost=10)], "e2e_export_begin || exit $?", False, 1),
        ("old_uncredited_disk", [dict(path="2f7175657565",bytes=512)], "e2e_export_begin || exit $?", False, 1),
        ("old_header_only", [dict(bytes=8)], "e2e_export_begin || exit $?", False, 1),
        ("initial_ram_pending", [dict(cap=10)], "e2e_export_begin || exit $?", False, 1),
        ("initial_ring_pending", [dict(cap=10,ring=10)], "e2e_export_begin || exit $?", False, 1),
        ("disabled_fallback", [dict(path=""),dict(path="",cap=10,sent=10)], "e2e_export_begin || exit $?", True, 2),
        ("empty_file", [dict(path="2f7175657565"), dict(path="2f7175657565",**replay)], "e2e_export_begin || exit $?", True, 2),
        ("broken_queue", [dict(broken=1)], "e2e_export_begin || exit $?", False, 1),
        ("changed_epoch", [{}, dict(epoch="101.000000",cap=10,sent=10)], "e2e_export_begin || exit $?", False, 2),
        ("changed_path", [{}, dict(path="2f6f74686572",cap=10,sent=10)], "e2e_export_begin || exit $?", False, 2),
        ("changed_container", [{}, dict(cap=10,sent=10)], "e2e_export_begin || exit $?; E2E_CT=other", False, 2),
        ("explicit_rearm", [{}, dict(epoch="101.000000"), dict(epoch="101.000000",**replay)],
         "e2e_export_begin || exit $?; e2e_export_begin || exit $?", True, 3),
        ("failed_rearm_invalidates", [{}, dict(queued=10,replayed=10), replay],
         "e2e_export_begin || exit $?; if e2e_export_begin; then exit 98; fi", False, 2),
        ("malformed_counter", [{}, dict(cap="bad")], "e2e_export_begin || exit $?", False, 2),
        ("query_failure", [{}, dict(error=True)], "e2e_export_begin || exit $?", False, 2),
    ]
    errors = []
    for name, rows, setup, success, snapshots in cases:
        with tempfile.TemporaryDirectory() as raw:
            tmp=Path(raw); env=export_epoch_env(tmp,rows)
            driver=f'''set -eu
. "{ROOT / 'tests/e2e/e2e-common.sh'}"
E2E_CT=model
unset E2E_EXPORT_EPOCH
{setup}
e2e_drain_export || exit $?
printf AFTER
'''
            result=run(["sh","-c",driver],env=env)
            assert hits(env)==["snapshot"]*snapshots, (name,"wrong actual snapshot boundaries",hits(env),result)
            if (result.returncode==0) != success or ("AFTER" in result.stdout) != success:
                errors.append((name,success,result))
            if not success and name not in ("query_failure",) and "export drain" not in result.stderr:
                errors.append((name,"missing clear drain/provenance diagnostic",result))
            if name.startswith("old_") and "zero-history" not in result.stderr:
                errors.append((name,"historical queue not explicitly rejected",result))
    if errors: fail(str(errors))


def test_export_worker_generation():
    # A same-postmaster SHMEM reset can make old queue deliveries mask new RAM.
    # Omitting either worker PID or backend_start from the proof must fail here.
    good = dict(cap=20, sent=20)
    replaced = [dict(pid=701, start="102.000000")]
    cases = [
        ("same_live", good, dict(cap=30,sent=30), True, 2, True),
        ("same_replay", good, dict(cap=30,sent=20,queued=10,replayed=10), True, 2, True),
        ("same_pending_queue", good, dict(cap=30,sent=20,queued=10,bytes=512), False, 61, True),
        ("same_pending_ram", good, dict(cap=30,sent=20), False, 61, True),
        ("same_postmaster_replayed_reset", good, dict(cap=10,queued=10,replayed=10,workers=replaced), False, 2, True),
        ("same_postmaster_uncredited_reset", good, dict(bytes=512,workers=replaced), False, 2, True),
        ("same_postmaster_empty_reset", good, dict(workers=replaced), False, 2, True),
        ("pid_only_change", good, dict(cap=30,sent=30,workers=[dict(pid=701,start="101.000000")]), False, 2, True),
        ("start_only_change", good, dict(cap=30,sent=30,workers=[dict(pid=700,start="102.000000")]), False, 2, True),
        ("soft_replacement", good, dict(cap=30,sent=30,workers=replaced), False, 2, True),
        ("absent_at_arm", dict(**good,workers=[]), {}, False, 1, False),
        ("multiple_at_arm", dict(**good,workers=[dict(pid=700,start="101.000000"),*replaced]), {}, False, 1, False),
        ("absent_at_drain", good, dict(cap=30,sent=30,workers=[]), False, 2, True),
        ("multiple_at_drain", good, dict(cap=30,sent=30,workers=[dict(pid=700,start="101.000000"),*replaced]), False, 2, True),
        ("null_pid", dict(**good,workers=[dict(pid=None,start="101.000000")]), {}, False, 1, False),
        ("null_start", dict(**good,workers=[dict(pid=700,start=None)]), {}, False, 1, False),
        ("postmaster_change_control", good, dict(epoch="101.000000",cap=30,sent=30), False, 2, True),
    ]
    errors=[]
    for name, initial, later, success, reads, armed in cases:
        with tempfile.TemporaryDirectory() as raw:
            tmp=Path(raw); env=export_epoch_env(tmp,[initial,later])
            driver=f'''set -eu
. "{ROOT / 'tests/e2e/e2e-common.sh'}"
E2E_CT=model; E2E_EXPORT_EPOCH=1
e2e_export_begin || exit $?
printf 'ARMED\n'
e2e_drain_export || exit $?
printf AFTER
'''
            result=run(["sh","-c",driver],env=env)
            assert hits(env), (name,"actual snapshot boundary was not reached",result)
            if (result.returncode==0)!=success or ("AFTER" in result.stdout)!=success or ("ARMED" in result.stdout)!=armed:
                errors.append((name,"worker generation was not enforced",result))
            elif len(hits(env))!=reads or (not success and "export drain" not in result.stderr):
                errors.append((name,"unexpected recovery/re-arm or missing diagnostic",hits(env),result))
    if errors: fail(str(errors))


def measurement_env(tmp, fault=""):
    env = env_for(tmp)
    env["HARNESS_MEASURE_FAULT"] = fault
    env["HARNESS_EXPORT_SQL"] = EXPORT_SNAPSHOT_SQL
    env["HARNESS_DUMP"] = str(tmp / "sink")
    workers=[dict(pid=700,start="101.000000")]
    if fault=="no_worker": workers=[]
    if fault=="multiple_workers": workers.append(dict(pid=701,start="102.000000"))
    Path(env["HARNESS_STATE"]).write_text(json.dumps(dict(cap=0,sent=0,ready=0,workers=workers)))
    Path(env["HARNESS_DUMP"]).touch()
    bindir = Path(env["PATH"].split(":", 1)[0])
    write_exe(bindir / "sleep", '#!/usr/bin/env python3\nimport sys,time\nassert sys.argv[1:] in (["1"],["2"],["3"],["5"])\ntime.sleep(.02)\n')
    write_exe(bindir / "wc", r'''#!/usr/bin/env python3
import os,subprocess,sys
from pathlib import Path
assert sys.argv[1:]==["-l"]
sink=Path(os.environ["HARNESS_DUMP"])
assert os.fstat(0).st_ino==sink.stat().st_ino
pending=sink.with_suffix(".pending"); polls=sink.with_suffix(".polls")
if pending.exists():
    n=int(polls.read_text())+1 if polls.exists() else 1
    polls.write_text(str(n))
    fault=os.environ["HARNESS_MEASURE_FAULT"]
    if fault=="delayed_replay_file" and n==3:
        with sink.open("a") as f: f.write("event\n"*600)
        pending.write_text("event\n"*600)
    elif (fault=="delayed_file" and n==3) or (fault=="delayed_replay_file" and n==5):
        with sink.open("a") as f: f.write(pending.read_text())
        pending.unlink()
sys.exit(subprocess.run(["/usr/bin/wc","-l"],stdin=sys.stdin).returncode)
''')
    write_exe(bindir / "docker", r'''#!/usr/bin/env python3
import hashlib,json,os,sys,time
from datetime import datetime
from pathlib import Path
a=sys.argv[1:]
with open(os.environ["HARNESS_LOG"],"a") as f: f.write(json.dumps(a)+"\n")
p=Path(os.environ["HARNESS_STATE"]); active=p.with_suffix(".active")
lat=p.with_suffix(".lat"); pids=p.with_suffix(".pids")
fault=os.environ["HARNESS_MEASURE_FAULT"]
def die(): sys.exit(97)
def state(): return json.loads(p.read_text()) if p.exists() else dict(cap=0,sent=0,ready=0)
def save(s): p.write_text(json.dumps(s))
if a[:2] == ["exec","model"]:
    c=a[2:]
    if c == ["pgbench","-i","-q","-s","8","-U","postgres","postgres"]:
        pass
    elif c and c[0] == "pgbench":
        if c[:7] != ["pgbench","-U","postgres","-c","8","-j","2"]: die()
        if c[7:9] not in (["-T","3"],["-T","6"]): die()
        warm=c[8]=="3"
        if c[9:] not in (["--random-seed=1","postgres"],["-s","8","--random-seed=1","postgres"]): die()
        with open(os.environ["HARNESS_HITS"],"a") as f: f.write("warmup\n" if warm else "measured\n")
        if warm and fault=="warmup": sys.exit(41)
        # Receipt itself is forbidden after the modeled recovery; stop at boundary.
        if not warm and fault in ("warmup_shmem_replay","warmup_shmem_uncredited"): sys.exit(44)
        if not warm:
            if fault=="warmup_pending" and state()["cap"]!=state()["sent"]: sys.exit(43)
            active.touch(); time.sleep(.25)
        s=state(); n=300 if warm else 600; s["cap"]+=n
        s["ready"]=time.time()+(.10 if warm else 0)
        if not warm: s["sent"]=s["cap"]-s.get("replayed",0)
        if warm and fault=="warmup_queue_pending": s["queued"]=300
        if warm and fault in ("warmup_shmem_replay","warmup_shmem_uncredited"): s["recover_after_warmup"]=True
        if not warm and fault=="delayed_replay_file":
            # 600 additional SAME-EPOCH captures queued and replayed, not history.
            s["cap"]+=600; s["queued"]=600; s["replayed"]=600
        save(s)
        with lat.open("a") as f: f.write(json.dumps([time.time(),n,999 if warm else 10])+"\n")
        sink=Path(os.environ["HARNESS_DUMP"])
        if not warm and fault in ("delayed_file","delayed_replay_file","missing_file"):
            sink.with_suffix(".pending").write_text("event\n"*(1200 if fault=="delayed_replay_file" else n))
        else:
            with sink.open("a") as f: f.write("event\n"*n)
        if not warm:
            active.unlink(); print("tps = 100\nlatency average = 1.0 ms")
            if fault=="measured": sys.exit(42)
    elif c in (["psql","-U","postgres","-Atc","SELECT pg_logtap_stats()"],
                ["psql","-X","-U","postgres","-v","ON_ERROR_STOP=1","-Atc",os.environ["HARNESS_EXPORT_SQL"]]):
        s=state()
        if s.pop("recover_after_warmup",False):
            # Crash/recovery AFTER the successful warmup client, before its drain.
            s.update(cap=10 if fault=="warmup_shmem_replay" else 0,sent=0,ready=0,
                     queued=10 if fault=="warmup_shmem_replay" else 0,
                     replayed=10 if fault=="warmup_shmem_replay" else 0,
                     workers=[dict(pid=701,start="102.000000")],recovered=True)
            save(s)
        if time.time() >= s["ready"] and not s.get("recovered") and fault not in ("warmup_queue_pending","warmup_ram_pending","warmup_ring_pending"):
            if fault=="warmup_replay" and s["cap"]: s["queued"]=300; s["replayed"]=300
            s["sent"]=s["cap"]-(s.get("replayed",0) if fault in ("warmup_replay","delayed_replay_file") else 0); save(s)
        pending=0 if s.get("recovered") or fault in ("warmup_queue_pending","warmup_ram_pending") else s["cap"]-s["sent"]-(s.get("replayed",0) if fault in ("warmup_replay","delayed_replay_file") else 0)
        queue_bytes=512 if (fault=="warmup_queue_pending" and s["cap"]) or (fault=="warmup_shmem_uncredited" and s.get("recovered")) else 0
        workers=s.get("workers",[dict(pid=700,start="101.000000")])
        identity="0 0" if len(workers)!=1 else str(workers[0]["pid"])+" "+workers[0]["start"]
        prefix=f"100.000000 2f7175657565 {queue_bytes} {identity} " if c[1]=="-X" else ""
        print(prefix+f'events_captured={s["cap"]} events_dropped=0 events_sent={s["sent"]} events_queued={s.get("queued",0)} events_replayed={s.get("replayed",0)} events_compacted=0 send_cycles_failed=0 events_lost=0 ring_events={pending} ring_capacity=8192 dns_fail_streak=0 fallback_broken=0 fb_sync_failures=0 redact_pattern_failed=0 warn_tls_no_verify=0 warn_fallback_open=0 warn_fallback_skipped=0 warn_fallback_unbounded=0')
    elif c == ["ps","-eo","rss=,args="]: print("1024 pg_logtap exporter")
    elif c[:4] == ["psql","-U","postgres","-qc"]:
        if len(c[3:])%2 or any(c[i]!="-qc" for i in range(3,len(c),2)): die()
        allowed={"ALTER SYSTEM SET log_min_messages = 'debug1'","ALTER SYSTEM SET log_min_duration_statement = 0",
                 "ALTER SYSTEM SET log_statement = 'none'","ALTER SYSTEM SET pg_logtap.level_min = 10",
                 "ALTER SYSTEM SET log_destination = 'stderr'","SELECT pg_reload_conf()",
                 "ALTER SYSTEM SET pg_logtap.export_url = 'http://pglogtap-vector:8686'",
                 "ALTER SYSTEM SET pg_logtap.export_url = 'http://rx:8687'",
                 "ALTER SYSTEM SET log_min_messages = 'warning'", "ALTER SYSTEM SET log_min_duration_statement = -1",
                 "ALTER SYSTEM SET pg_logtap.level_min = 15", "ALTER SYSTEM SET pg_logtap.export_url = ''"}
        if any(x not in allowed for x in c[4::2]): die()
    else: die()
elif a == ["stats","--no-stream","--format","{{.CPUPerc}}","model"]:
    with pids.open("a") as f: f.write(str(os.getpid())+"\n")
    for _ in range(20):
        if active.exists() or (p.exists() and state()["cap"]>=900): break
        time.sleep(.005)
    busy=active.exists(); time.sleep(.08)
    print("70.00%" if busy and active.exists() else "0.00%")
elif a[:1] == ["logs"]:
    if a == ["logs","rx"]: since=0
    elif len(a)==4 and a[1]=="--since" and a[3]=="rx":
        since=datetime.fromisoformat(a[2].replace("Z","+00:00")).timestamp()
    else: die()
    if lat.exists():
        for stamp,n,value in map(json.loads,lat.read_text().splitlines()):
            if stamp>=since: print((str(value)+"\n")*n,end="")
elif a == ["rm","-f","rx"]: pass
elif len(a)==12 and a[:11] == ["run","-d","--rm","--name","rx","--network","net","python:3-alpine","python","-u","-c"]:
    if hashlib.sha256(a[11].encode()).hexdigest() != "62412368b6ddff023922356969ab1150451aa95738e38ced56563effe35b70cc": die()
elif a == ["run","--rm","--network","net","curlimages/curl:8.8.0","-G","-s","http://pglogtap-vlogs-e2e:9428/select/logsql/query","--data-urlencode","query=* | count()","--data-urlencode","time_range=6s"]: print("600")
else: die()
''')
    return env


def test_measurement_windows():
    errors = []
    for source, script, body in ((ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_loud"),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", "run_mode loud"),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", "run_mode chain")):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = measurement_env(tmp)
            driver = f'''set -euo pipefail
source "{source}"
C=model; E2E_CT=model; E2E_TAG=measurement; OUT="{tmp}"; DUMP="$HARNESS_DUMP"; NET=net; RX=rx; SECS=6; WARMUP=3; SEED=1
e2e_export_begin || exit $?
{body} || exit $?
printf AFTER
'''
            result = run(["bash", "-c", driver], env=env, cwd=tmp)
            problems = []
            if result.returncode or "AFTER" not in result.stdout: problems.append(f"rc={result.returncode}: {result.stderr}")
            if "events/s=100 captured=600" not in result.stdout or "sent=600" not in result.stdout:
                problems.append("counters included warmup or undrained warmup delivery")
            if body.endswith("chain"):
                if "vector_file_lines=600" not in result.stdout: problems.append("chain file delta included warmup")
            elif not re.search(r"\bn=600 p50=10.0ms p95=10.0ms p99=10.0ms",result.stdout):
                problems.append("latency capture included warmup")
            cpu = tmp / ("cpu" if script=="bench-overhead.sh" else "cpu."+body.split()[-1])
            samples = cpu.read_text().splitlines() if cpu.exists() else []
            if not samples or any(float(x.rstrip("%"))!=70 for x in samples):
                problems.append(f"CPU included post-workload samples: {samples}")
            pids=tmp/"state.pids"
            if pids.exists():
                for pid in pids.read_text().splitlines():
                    try: os.kill(int(pid),0)
                    except ProcessLookupError: pass
                    else: problems.append(f"unreaped sample process {pid}")
            if hits(env) != ["warmup","measured"]: problems.append(f"wrong workload boundaries {hits(env)}")
            if problems: errors.append(f"{script}/{body}: {problems}; stdout={result.stdout!r}")
    if errors: fail("; ".join(errors))


def test_export_parent_arming():
    # Execute the actual setup-to-warmup caller slices, not copied helper logic.
    patterns = (
        (ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", r"^set_logging quiet\n.*?^run_job on-quiet$"),
        (ROOT / "tests/e2e/storm.sh", "storm.sh", r'^docker exec "\$C" pgbench -i -q -s 8 -U postgres postgres.*?^for mode in .*?done$'),
    )
    errors = []
    for source, script, pattern in patterns:
        caller = re.search(pattern, source.read_text(), re.S | re.M)
        assert caller is not None, ("actual setup-to-workload caller not found", source)
        for history, worker_fault in ((False,""),(True,""),(False,"no_worker"),(False,"multiple_workers")):
            with tempfile.TemporaryDirectory() as raw:
                tmp=Path(raw); env=measurement_env(tmp,worker_fault)
                if history:
                    Path(env["HARNESS_STATE"]).write_text(json.dumps(dict(cap=0,sent=0,queued=10,replayed=10,ready=0)))
                driver=f'''set -euo pipefail
source "{source}"
C=model; E2E_CT=model; OUT="{tmp}"; DUMP="$HARNESS_DUMP"; NET=net; RX=rx; SECS=6; WARMUP=3; SEED=1; MODES=chain
E2E_EXPORT_EPOCH=1
parent_phase() {{
{caller.group(0)}
}}
parent_phase || exit $?
e2e_drain_export || exit $?
printf PARENTPROOF
'''
                result=run(["bash","-c",driver],env=env,cwd=tmp)
                assert calls(env), ("caller reached no native boundary",script,history,result)
                if history or worker_fault:
                    diagnostic="zero-history" if history else "exporter"
                    if result.returncode==0 or "PARENTPROOF" in result.stdout or hits(env) or diagnostic not in result.stderr:
                        errors.append((script,worker_fault,"unsupported parent epoch reached workload",hits(env),result))
                elif result.returncode or "PARENTPROOF" not in result.stdout or hits(env)!=["warmup","measured"]:
                    errors.append((script,"parent did not retain proved fresh epoch",hits(env),result))
    for preload in ("", "pg_logtap"):
        with tempfile.TemporaryDirectory() as raw:
            tmp=Path(raw); env=env_for(tmp)
            bindir=Path(env["PATH"].split(":",1)[0])
            write_exe(bindir/"docker", r'''#!/usr/bin/env python3
import json,os,sys
a=sys.argv[1:]
with open(os.environ["HARNESS_LOG"],"a") as f: f.write(json.dumps(a)+"\n")
assert a in (["exec","model","psql","-U","postgres","-qc","ALTER SYSTEM RESET shared_preload_libraries"],
             ["exec","model","psql","-U","postgres","-qc","ALTER SYSTEM SET shared_preload_libraries = 'pg_logtap'"],
             ["restart","model"],["exec","model","pg_isready","-U","postgres","-h","127.0.0.1"])
''')
            driver=f'''set -euo pipefail
source "{ROOT / 'benchmarks/bench-overhead.sh'}"
C=model; E2E_CT=model; E2E_EXPORT_EPOCH=1
set_preload '{preload}'
if [ "${{E2E_EXPORT_EPOCH+x}}" ]; then exit 98; fi
printf RESTARTED
'''
            result=run(["bash","-c",driver],env=env,cwd=tmp)
            assert len(calls(env))==3 and calls(env)[1]==["restart","model"], (preload,result,calls(env))
            if result.returncode or "RESTARTED" not in result.stdout:
                errors.append((preload,"existing restart retained stale provenance",result))
    if errors: fail(str(errors))


def test_export_measurement_replay_and_pending():
    for source, script, body in ((ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_loud"),
                                 (ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_job on-mute"),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", "run_mode chain")):
        for fault in ("warmup_replay","warmup_queue_pending","warmup_ram_pending","warmup_ring_pending"):
            with tempfile.TemporaryDirectory() as raw:
                tmp=Path(raw); env=measurement_env(tmp,fault)
                driver=f'''set -euo pipefail
source "{source}"
C=model; E2E_CT=model; OUT="{tmp}"; DUMP="$HARNESS_DUMP"; NET=net; RX=rx; SECS=6; WARMUP=3; SEED=1
e2e_export_begin || exit $?
{body} || exit $?
printf AFTER
'''
                result=run(["bash","-c",driver],env=env,cwd=tmp)
                native=calls(env)
                assert native[0]==["exec","model","psql","-X","-U","postgres","-v","ON_ERROR_STOP=1","-Atc",EXPORT_SNAPSHOT_SQL], (fault,native)
                if fault=="warmup_replay":
                    assert result.returncode==0 and "AFTER" in result.stdout and hits(env)==["warmup","measured"], (script,body,fault,result,hits(env))
                    s=json.loads(Path(env["HARNESS_STATE"]).read_text())
                    assert (s["cap"],s["sent"],s["queued"],s["replayed"])==(900,600,300,300), (script,body,s)
                    if body.endswith("chain"): assert "vector_file_lines=600 " in result.stdout, result
                else:
                    assert result.returncode!=0 and "AFTER" not in result.stdout and hits(env)==["warmup"] and "export drain did not settle" in result.stderr, (script,body,fault,result,hits(env))
                    assert not (tmp/"jobs").exists() and not list(tmp.glob("cpu*")), (fault,"pending warmup started measurement")
                if (tmp/"state.pids").exists():
                    for pid in (tmp/"state.pids").read_text().splitlines():
                        try: os.kill(int(pid),0)
                        except ProcessLookupError: pass
                        else: fail(f"export measurement left sampler child {pid}")


def test_export_recovery_before_measurement():
    errors=[]
    for source, script, body in ((ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_loud"),
                                 (ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_job on-mute"),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", "run_mode chain")):
        for fault in ("warmup_shmem_replay","warmup_shmem_uncredited"):
            with tempfile.TemporaryDirectory() as raw:
                tmp=Path(raw); env=measurement_env(tmp,fault)
                driver=f'''set -euo pipefail
source "{source}"
C=model; E2E_CT=model; OUT="{tmp}"; DUMP="$HARNESS_DUMP"; NET=net; RX=rx; SECS=6; WARMUP=3; SEED=1
e2e_export_begin || exit $?
{body} || exit $?
printf AFTER
'''
                result=run(["bash","-c",driver],env=env,cwd=tmp)
                state=json.loads(Path(env["HARNESS_STATE"]).read_text())
                assert state.get("recovered") and state["workers"]==[dict(pid=701,start="102.000000")], (script,fault,"recovery boundary not hit",result)
                if result.returncode!=1 or "AFTER" in result.stdout or hits(env)!=["warmup"] or "export drain" not in result.stderr:
                    errors.append((script,body,fault,"reset proof reached measurement",hits(env),result))
                elif (tmp/"jobs").exists() or list(tmp.glob("cpu*")):
                    errors.append((script,fault,"reset warmup started measurement artifacts"))
                if (tmp/"state.pids").exists():
                    for pid in (tmp/"state.pids").read_text().splitlines():
                        try: os.kill(int(pid),0)
                        except ProcessLookupError: pass
                        else: errors.append((script,fault,"unreaped sampler child",pid))
    if errors: fail(str(errors))


def test_export_history_before_warmup():
    errors = []
    for source, script, body in ((ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_loud"),
                                 (ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_job on-mute"),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", "run_mode chain")):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = measurement_env(tmp)
            # Old queue delivery is not part of this epoch's captured count.
            Path(env["HARNESS_STATE"]).write_text(json.dumps(dict(cap=0, sent=0, ready=0, queued=10, replayed=10)))
            driver = f'''set -euo pipefail
source "{source}"
C=model; E2E_CT=model; OUT="{tmp}"; DUMP="$HARNESS_DUMP"; NET=net; RX=rx; SECS=6; WARMUP=3; SEED=1
E2E_EXPORT_EPOCH=1
{body} || exit $?
printf AFTER
'''
            result = run(["bash", "-c", driver], env=env, cwd=tmp)
            assert calls(env), ("actual caller never reached its modeled external boundary", script, result)
            if result.returncode == 0 or "AFTER" in result.stdout or hits(env) or "export drain" not in result.stderr:
                errors.append((script, body, "unknown history reached workload", hits(env), result))
    if errors: fail(str(errors))


def test_chain_file_completion():
    errors = []
    for fault in ("", "delayed_file", "delayed_replay_file", "missing_file"):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = measurement_env(tmp, fault)
            driver = f'''set -euo pipefail
source "{ROOT / 'tests/e2e/storm.sh'}"
C=model; E2E_CT=model; OUT="{tmp}"; DUMP="$HARNESS_DUMP"; NET=net; RX=rx; SECS=6; WARMUP=3; SEED=1
e2e_export_begin || exit $?
run_mode chain || exit $?
printf AFTER
'''
            result = run(["bash", "-c", driver], env=env, cwd=tmp)
            assert hits(env) == ["warmup", "measured"], (fault, result, hits(env))
            expected_counters = "captured=1200 sent=600" if fault == "delayed_replay_file" else "captured=600 sent=600"
            assert expected_counters in result.stdout, (fault, result)
            pending = (tmp / "sink.pending").exists()
            polls = int((tmp / "sink.polls").read_text()) if (tmp / "sink.polls").exists() else 0
            if fault == "missing_file":
                if result.returncode == 0 or "AFTER" in result.stdout or "vector_file_lines=" in result.stdout or not pending or polls != 60:
                    errors.append((fault, "unflushed measured sink reported success", polls, result))
            elif result.returncode or "AFTER" not in result.stdout or ("vector_file_lines=1200 " if fault == "delayed_replay_file" else "vector_file_lines=600 ") not in result.stdout or pending or (fault and polls != (5 if fault == "delayed_replay_file" else 3)):
                errors.append((fault, "returned before measured file completion", polls, result))
            samples = (tmp / "cpu.chain").read_text().splitlines()
            assert samples and all(float(x.rstrip("%")) == 70 for x in samples), (fault, samples)
            for pid in (tmp / "state.pids").read_text().splitlines():
                try: os.kill(int(pid), 0)
                except ProcessLookupError: pass
                else: errors.append((fault, "live sampler child", pid))
    if errors: fail(str(errors))


def test_mute_warmup_drain():
    for body in ("run_loud", "run_job on-mute"):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = measurement_env(tmp, "warmup_pending")
            driver = f'''set -euo pipefail
source "{ROOT / 'benchmarks/bench-overhead.sh'}"
C=model; E2E_CT=model; OUT="{tmp}"; RX=rx; SECS=6; WARMUP=3; SEED=1
e2e_export_begin || exit $?
{body} || exit $?
printf AFTER
'''
            result = run(["bash", "-c", driver], env=env, cwd=tmp)
            assert hits(env) == ["warmup", "measured"], (body, result, hits(env))
            assert result.returncode == 0 and "AFTER" in result.stdout, (
                f"{body}: measured workload started with pending warmup exports", result)


def test_measurement_failures():
    errors = []
    for source, script, body in ((ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh", "run_job off-loud"),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", "run_mode loud")):
        for fault, code in (("warmup",41),("measured",42)):
            with tempfile.TemporaryDirectory() as raw:
                tmp=Path(raw); env=measurement_env(tmp,fault)
                driver=f'''set -euo pipefail
source "{source}"
C=model; E2E_CT=model; E2E_TAG=measurement; OUT="{tmp}"; NET=net; RX=rx; SECS=6; WARMUP=3; SEED=1
{'e2e_export_begin || exit $?' if script == 'storm.sh' else ''}
{body} || exit $?
printf AFTER
'''
                result=run(["bash","-c",driver],env=env,cwd=tmp)
                expected=["warmup"] if fault=="warmup" else ["warmup","measured"]
                if result.returncode != code or "AFTER" in result.stdout or hits(env)!=expected or (tmp/"jobs").exists():
                    errors.append(f"{script}/{fault}: rc={result.returncode}, hits={hits(env)}, out={result.stdout!r}, err={result.stderr!r}")
                pids=tmp/"state.pids"
                if pids.exists():
                    for pid in pids.read_text().splitlines():
                        try: os.kill(int(pid),0)
                        except ProcessLookupError: pass
                        else: errors.append(f"{script}/{fault}: live/unreaped sampler child {pid}")
    if errors: fail("; ".join(errors))


def test_standby_lock_cooperation():
    errors=[]
    for key in ("pglogtap-standby-primary-15", "pglogtap-standby-replica-15"):
        with tempfile.TemporaryDirectory() as raw:
            tmp=Path(raw); env=env_for(tmp)
            env["E2E_OUT"]=str(tmp/"out"); (tmp/"out").mkdir()
            so=tmp/"dist/pg15/lib/pg_logtap.so"; so.parent.mkdir(parents=True); so.write_text("fixture")
            holder=subprocess.Popen(["sh","-c", f'. "{ROOT / "tests/e2e/e2e-common.sh"}"; E2E_CT={key}; E2E_TAG=selftest; e2e_lock; printf "ACQUIRED\\n"; read -r release'],
                                    env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                assert holder.stdout.readline()=="ACQUIRED\n"
                result=run(["sh",str(ROOT/"tests/e2e/e2e-standby.sh"),"15"],env=env,cwd=tmp)
                if result.returncode==0 or "another e2e holds" not in result.stderr or calls(env):
                    errors.append(f"standby bypassed {key} suite lock: calls={calls(env)}; stderr={result.stderr!r}")
            finally:
                holder.communicate("release\n",timeout=5)
    if errors: fail("; ".join(errors))


def test_disjoint_lock_namespaces():
    for key in ("model", "stand"):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp)
            body = f'''set -eu
. "{ROOT / 'tests/e2e/e2e-common.sh'}"
E2E_TAG=selftest; E2E_CT={key}
e2e_lock
printf 'CONTAINER\\n'
e2e_stand_lock
printf 'BOTH\\n'
'''
            result = run(["timeout", "3", "sh", "-c", body], env=env)
            assert "CONTAINER" in result.stdout, ("container lock was not acquired", key, result)
            assert result.returncode == 0 and "BOTH" in result.stdout, (
                "container key aliases the shared namespace and self-deadlocks", key, result)
            assert not calls(env), ("namespace check reached an external native boundary", calls(env))


def test_shared_lock_and_phase_release():
    with tempfile.TemporaryDirectory() as raw:
        tmp=Path(raw); env=env_for(tmp)
        body=f'. "{ROOT / "tests/e2e/e2e-common.sh"}"; OUT=$1; E2E_CT=$2; E2E_TAG=selftest; e2e_lock; printf "CONTAINER\\n"; e2e_stand_lock; printf "BUILD\\n"; read -r release'
        for name in ("a","b"): (tmp/name).mkdir()
        holder=subprocess.Popen(["sh","-c",body,"sh",str(tmp/"a"),"one"],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
        contender=None
        try:
            assert holder.stdout.readline()==b"CONTAINER\n" and holder.stdout.readline()==b"BUILD\n"
            contender=subprocess.Popen(["sh","-c",body,"sh",str(tmp/"b"),"two"],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
            assert contender.stdout.readline()==b"CONTAINER\n", "distinct container was serialized"
            assert not select.select([contender.stdout],[],[],.10)[0], "different OUT bypassed the shared builder lock"
            holder.communicate(b"release\n",timeout=5)
            assert contender.stdout.readline()==b"BUILD\n", "shared lock did not release"
        finally:
            if holder.poll() is None: holder.communicate(b"release\n",timeout=5)
            if contender is not None: contender.communicate(b"release\n",timeout=5)

    for mode in ("", "build"):
        with tempfile.TemporaryDirectory() as raw:
            tmp=Path(raw); env=env_for(tmp,mode)
            body=f'''set -euo pipefail
source "{ROOT / 'tests/e2e/test-matrix.sh'}"
OUT="{tmp / 'out'}"; mkdir -p "$OUT"; FLAGS=(); COMPOSE='docker compose -f tests/e2e/compose.yaml'
phase_stand 15 || :
timeout 3 sh -c '. "{ROOT / 'tests/e2e/e2e-common.sh'}"; E2E_TAG=child; E2E_CT=pglogtap-mx15; e2e_lock; e2e_stand_lock; printf CHILD'
'''
            result=run(["bash","-c",body],env=env)
            assert result.returncode==0 and "CHILD" in result.stdout, ("parent phase leaked a container/build lock into child",mode,result)


def test_failed_fallback_keeps_stale_library():
    for source, script, body in ((ROOT / "tests/e2e/test-matrix.sh", "test-matrix.sh", 'FLAGS=(); COMPOSE="docker compose -f tests/e2e/compose.yaml"; phase_stand 15'),
                                 (ROOT / "tests/e2e/storm.sh", "storm.sh", 'V=15; ZIG_TARGET=x86_64-linux-gnu.2.28; build_extension')):
        with tempfile.TemporaryDirectory() as raw:
            tmp=Path(raw); env=env_for(tmp); env["PG_CONFIG"]="/missing/pg_config"
            scripts=tmp/"scripts"; scripts.mkdir()
            write_exe(scripts/"build.sh", '''#!/bin/sh
[ "$1" = 15 ] || exit 97
shift
case "$*" in ''|'-Dtarget=x86_64-linux-gnu.2.28 -Doptimize=ReleaseSafe') ;; *) exit 97 ;; esac
printf 'fallback-failed\\n' >> "$HARNESS_HITS"
exit 76
''')
            stale=tmp/"zig-out/lib/pg_logtap.so"; stale.parent.mkdir(parents=True); stale.write_text("stale pg18 library")
            driver=f'set -euo pipefail; source "{source}"; OUT="{tmp / "out"}"; mkdir -p "$OUT"; {body} || exit $?; printf AFTER'
            result=run(["bash","-c",driver],env=env,cwd=tmp)
            assert hits(env)==["fallback-failed"], "did not reach the failed target-major builder"
            assert result.returncode!=0 and "AFTER" not in result.stdout and not (tmp/"dist/pg15/lib/pg_logtap.so").exists() and not any(c[:1]==["cp"] for c in calls(env)), (
                f"{script}: failed target build copied a stale library",result,calls(env))


def test_benchmark_readiness():
    # A ready server need not have Docker Health (docker-run matrix majors do not).
    for mode, expected in (("bench_ready", 0), ("bench_not_ready", 1)):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            env = env_for(tmp, mode)
            docker = Path(env["PATH"].split(":", 1)[0]) / "docker"
            text = docker.read_text().replace('if args[0] == "inspect":', '''if args == ["inspect", "-f", "{{.State.Health.Status}}", "model"]:
    sys.exit(1)  # real docker inspect fails when Health is absent
if args[0] == "inspect":''').replace('elif cmd[0] == "pg_isready":', '''elif cmd[0] == "pg_isready":
        if mode == "bench_not_ready": hit("not_ready", 1)''')
            docker.write_text(text)
            errors = []
            for source, script in ((ROOT / "benchmarks/bench-overhead.sh", "bench-overhead.sh"),
                                   (ROOT / "tests/e2e/storm.sh", "storm.sh")):
                Path(env["HARNESS_LOG"]).unlink(missing_ok=True)
                result = run(["bash", "-c", f'source "{source}"; C=model; wait_ready'], env=env)
                probes = [c for c in calls(env) if c[:3] == ["exec", "model", "pg_isready"]]
                if result.returncode != expected or len(probes) != (1 if expected == 0 else 60):
                    errors.append(f"{script} {mode}: rc={result.returncode}, TCP probes={len(probes)}, expected rc={expected}")
                if any(c[:1] == ["inspect"] for c in calls(env)):
                    errors.append(f"{script} readiness still depends on Docker Health")
            if errors:
                fail("; ".join(errors))


def test_mock_rejection():
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = env_for(tmp)
        bindir = env["PATH"].split(":", 1)[0]
        commands = [
            [bindir + "/docker", "run", "UNEXPECTED_TASK7_REVIEW_COMMAND"],
            [bindir + "/docker", "run", "-d", "--name", "pglogtap-mx15", "postgres:15", "UNEXPECTED_TASK7_REVIEW_COMMAND"],
            [bindir + "/docker", "exec", "model", "bash", "-c", "UNEXPECTED_TASK7_REVIEW_COMMAND"],
            [bindir + "/docker", "exec", "model", "bash", "-c", "pgbench -i -q; UNEXPECTED_TASK7_REVIEW_COMMAND | grep tps"],
            [bindir + "/docker", "exec", "model", "sh", "-c", "UNEXPECTED_TASK7_REVIEW_COMMAND"],
            [bindir + "/docker", "exec", "model", "psql", "UNEXPECTED_TASK7_REVIEW_COMMAND"],
            [bindir + "/docker", "exec", "-e", "UNEXPECTED_TASK7_REVIEW_ENV=1", "model", "psql", "-Atc", "SELECT 1"],
            [bindir + "/docker", "exec", "-i", "model", "psql", "-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-v", "guc=unexpected", "-v", "value=x"],
            [bindir + "/docker", "exec", "-i", "model", "psql", "-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-v", "guc=pg_logtap.export_url", "-v", "value=x"],
            [bindir + "/docker", "exec", "model", "psql", "-Atc", "SELECT 1; UNEXPECTED_TASK7_REVIEW_COMMAND"],
            [bindir + "/docker", "inspect", "-f", "{{.State.Status}}", "model", "UNEXPECTED_TASK7_REVIEW_ARGUMENT"],
            [bindir + "/docker", "rm", "-f", "UNEXPECTED_TASK7_REVIEW_CONTAINER"],
            [bindir + "/docker", "exec", "model", "cat", "/UNEXPECTED_TASK7_REVIEW_PATH"],
            [bindir + "/zig", "UNEXPECTED_TASK7_REVIEW_COMMAND"],
            [bindir + "/zig", "build", "UNEXPECTED_TASK7_REVIEW_ARGUMENT"],
        ]
        if any(subprocess.run(command, env=env).returncode == 0 for command in commands):
            fail("fixture command stub accepted an unexpected command")

    for mode in ("", "hook_config_normal", "wide_early"):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp, mode)
            docker = env["PATH"].split(":", 1)[0] + "/docker"
            psql = [docker, "exec", "model", "psql", "-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1"]
            commands = [
                [*psql, "-qAt", "-c", "SELECT hookchain_count()", "-c", "SELECT hookchain_arm(true)",
                 "-c", "UNEXPECTED_REVIEW_COMMAND"],
                [*psql, "-qc", "SELECT count(*) FROM unnest(pg_logtap_dump(100)) AS t(line) WHERE UNEXPECTED_REVIEW_COMMAND"],
                [*psql, "-qc", "CREATE OR REPLACE FUNCTION public.hookchain_evil() RETURNS integer LANGUAGE C"],
                [*psql, "-qc", "DO $$ UNEXPECTED_REVIEW_COMMAND $$"],
            ]
            if any(subprocess.run(command, env=env).returncode == 0 for command in commands):
                fail(f"fixture {mode or 'default'} mode accepted a mixed or prefix-compatible SQL command")


def test_matrix_fail_closed():
    stages = [
        "build", "compose_up", "receiver_start", "receiver_create", "pg_create",
        "ready_create", "receiver_shared", "receiver_major", "pg_config_lib",
        "pg_config_share", "copy_so", "copy_control", "copy_sql", "sql_preload",
        "restart_preload", "ready_preload", "sql_guc", "restart_guc", "ready_guc", "sql_ext",
    ]
    for mode in stages:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            env = env_for(tmp, mode)
            driver = tmp / "driver.sh"
            driver.write_text(f'''#!/usr/bin/env bash
set -euo pipefail
source "{ROOT / 'tests/e2e/test-matrix.sh'}"
OUT="{tmp / 'out'}"; mkdir -p "$OUT"
COMPOSE='docker compose -f tests/e2e/compose.yaml'; FLAGS=(); E2E_VECTOR=receiver; E2E_OUT="$OUT"
phase_stand 15 || exit $?
printf AFTER
''')
            result = run(["/usr/bin/env", "bash", str(driver)], env=env)
            require_failed(result, "matrix " + mode)
            if hits(env) != [mode]:
                fail(f"matrix {mode}: did not hit only its injected boundary: {hits(env)}")

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = env_for(tmp, "compose_ready")
        driver = tmp / "driver.sh"
        driver.write_text(f'''#!/usr/bin/env bash
set -euo pipefail
source "{ROOT / 'tests/e2e/test-matrix.sh'}"
OUT="{tmp / 'out'}"; mkdir -p "$OUT"
COMPOSE='docker compose -f tests/e2e/compose.yaml'; FLAGS=(); E2E_VECTOR=receiver; E2E_OUT="$OUT"
phase_stand 15 || exit $?
printf AFTER
''')
        result = run(["/usr/bin/env", "bash", str(driver)], env=env)
        require_failed(result, "matrix compose ready exhaustion")
        polls = sum(item.startswith("inspect ") and "pglogtap-ready" in item for item in joined(env))
        if polls != 121:
            fail(f"matrix compose ready exhaustion stopped after {polls} readiness probes, not 120")

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = env_for(tmp)
        driver = tmp / "driver.sh"
        driver.write_text(f'''#!/usr/bin/env bash
set -euo pipefail
source "{ROOT / 'tests/e2e/test-matrix.sh'}"
OUT="{tmp / 'out'}"; mkdir -p "$OUT"
COMPOSE='docker compose -f tests/e2e/compose.yaml'; FLAGS=(); E2E_VECTOR=receiver; E2E_OUT="$OUT"
phase_stand 15 || exit $?
printf AFTER
''')
        result = run(["/usr/bin/env", "bash", str(driver)], env=env)
        if result.returncode or "AFTER" not in result.stdout or not any("CREATE EXTENSION pg_logtap" in item for item in joined(env)):
            fail(f"matrix phase_stand success control did not reach deployment: {result.stderr}")

    for mode in ("pgbench_init", "pgbench_run"):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            env = env_for(tmp, mode)
            driver = tmp / "driver.sh"
            driver.write_text(f'''#!/usr/bin/env bash
set -euo pipefail
source "{ROOT / 'tests/e2e/test-matrix.sh'}"
C=model; OUT="{tmp}"; E2E_OUT="$OUT"; VEC=receiver
phase_storm 15 1 || exit $?
printf AFTER
''')
            result = run(["/usr/bin/env", "bash", str(driver)], env=env)
            require_failed(result, "matrix " + mode)
            if not any("pgbench" in item for item in joined(env)):
                fail(f"matrix {mode}: did not execute the inner pgbench command")
            if any("ALTER SYSTEM SET log_min_duration_statement = -1" in item for item in joined(env)):
                fail(f"matrix {mode}: pgbench failure ran the later restore pipeline")

            mutated = tmp / "test-matrix-no-pipefail.sh"
            (tmp / "e2e-common.sh").symlink_to(ROOT / "tests/e2e/e2e-common.sh")
            original = (ROOT / "tests/e2e/test-matrix.sh").read_text()
            needle = 'bash -c "set -euo pipefail; pgbench -i -q -U postgres postgres >/dev/null 2>&1; \\\n    pgbench'
            if needle not in original:
                fail("matrix pipefail mutation anchor not found")
            mutated.write_text(original.replace(needle, 'bash -c "pgbench -i -q -U postgres postgres >/dev/null 2>&1; \\\n    pgbench', 1))
            driver.write_text(f'''#!/usr/bin/env bash
set -euo pipefail
source "{mutated}"
C=model; OUT="{tmp}"; E2E_OUT="$OUT"; VEC=receiver
phase_storm 15 1 || exit $?
printf AFTER
''')
            regressed = run(["/usr/bin/env", "bash", str(driver)], env=env)
            if regressed.returncode or "AFTER" not in regressed.stdout:
                fail(f"matrix {mode}: removing inner pipefail did not expose the false-green regression")


def test_failed_stand_is_retained():
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = env_for(tmp, "pg_create")
        env["HARNESS_LATER"] = str(tmp / "later-phase")
        driver = tmp / "driver.sh"
        driver.write_text(f'''#!/usr/bin/env bash
set -euo pipefail
source "{ROOT / 'tests/e2e/test-matrix.sh'}"
phase_upgrade() {{ printf upgrade > "$HARNESS_LATER"; }}
PHASES=stand,upgrade
main 1 15 || exit $?
printf AFTER
''')
        result = run(["/usr/bin/env", "bash", str(driver)], env=env)
        require_failed(result, "failed stand retention")
        if Path(env["HARNESS_LATER"]).exists():
            fail("failed stand reached a configured later phase")
        if ["rm", "-f", "pglogtap-mx15"] in calls(env):
            fail("failed stand ran success cleanup instead of retaining its container")
        if ["compose", "-f", "tests/e2e/compose.yaml", "down"] in calls(env):
            fail("matrix main EXIT cleanup tore down a failed stand")


def test_configuration_restoration():
    def initial(preload="oldpreload"):
        return {
            "shared_preload_libraries": preload,
            "pg_logtap.export_url": r"https://saved.example/a'b\\segment",
            "pg_logtap.export_fallback_file": r"/tmp/queue'a\\segment",
            "pg_logtap.message_max": "4096",
        }

    def saved(env):
        return json.loads(Path(env["HARNESS_GUCS"]).read_text())

    def restored(env, want, label):
        value = saved(env)
        if value["configured"] != want or value["effective"] != want:
            fail(f"{label}: configured/effective GUC restoration lost quoted or nondefault values: {value}")

    for preload, mode in (("oldpreload", "hook_config_normal"), ("", "hook_config_empty")):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp, mode); want = initial(preload)
            env["HARNESS_INITIAL_GUCS"] = json.dumps(want); env["E2E_OUT"] = str(tmp / "out")
            result = run(["/bin/sh", str(ROOT / "tests/e2e/e2e-hook-chain.sh"), "model"], env=env)
            if result.returncode:
                fail(f"hook {preload or 'empty'} restore did not complete: {result.stderr}; trace={joined(env)}")
            restored(env, want, f"hook {preload or 'empty'}")
            trace = "\n".join(joined(env))
            if preload and "ALTER SYSTEM SET shared_preload_libraries = 'oldpreload'" not in trace:
                fail("hook nonempty preload did not preserve its existing list restoration path")
            if not preload and "ALTER SYSTEM RESET shared_preload_libraries" not in trace:
                fail("hook empty preload did not use ALTER SYSTEM RESET")

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw); env = env_for(tmp, "hook_config_normal"); want = initial()
        env["HARNESS_INITIAL_GUCS"] = json.dumps(want); env["E2E_OUT"] = str(tmp / "out")
        env["HARNESS_FAIL_PRELOAD_RESTORE"] = "1"
        result = run(["/bin/sh", str(ROOT / "tests/e2e/e2e-hook-chain.sh"), "model"], env=env)
        value, trace = saved(env), "\n".join(joined(env))
        if result.returncode == 0:
            fail("hook preload restore failure returned success")
        if value["configured"]["pg_logtap.export_url"] != want["pg_logtap.export_url"] or value["effective"]["pg_logtap.export_url"] != want["pg_logtap.export_url"]:
            fail("hook preload restore failure skipped independent URL restore")
        if value["effective"]["shared_preload_libraries"] != "hookchain, pg_logtap":
            fail("hook preload restore failure did not retain the still-configured hookchain library")
        if "sh -c rm -f '/lib/hookchain.so'" in trace or trace.count("restart model") < 2 or trace.count("pg_isready") < 2:
            fail("hook preload restore failure deleted its needed library or skipped restart/readiness")

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw); env = env_for(tmp, "wide_early"); want = initial()
        env["HARNESS_INITIAL_GUCS"] = json.dumps(want); env["HARNESS_FAIL_FIRST_RESTART"] = "1"
        env["HARNESS_ASSERT_LOCK"] = "1"
        result = run(["/bin/sh", str(ROOT / "tests/e2e/e2e-wide.sh"), "model"], env=env)
        if result.returncode == 0 or any("DO $$" in item for item in joined(env)):
            fail("wide early restart failure reached probes or returned success")
        restored(env, want, "wide early failure")
        if "restoring_lock_held" not in hits(env):
            fail("wide released its container lock before the restoring restart")

    for name, code in (("HUP", 129), ("INT", 130), ("TERM", 143)):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp, "wide_signal"); want = initial()
            env["HARNESS_INITIAL_GUCS"] = json.dumps(want); env["HARNESS_SIGNAL"] = name
            result = run(["/bin/sh", str(ROOT / "tests/e2e/e2e-wide.sh"), "model"], env=env)
            if result.returncode != code or any("DO $$" in item for item in joined(env)):
                fail(f"wide {name}: rc={result.returncode}, later probes={joined(env)}")
            restored(env, want, f"wide {name}")

    source = (ROOT / "tests/e2e/e2e-wide.sh").read_text()
    cleanup = re.search(r"cleanup\(\) \{\n.*?^\}", source, re.S | re.M)
    if cleanup is None:
        fail("wide actual cleanup function not found")
    for original, cleanup_failure, expected in ((0, "", 0), (42, "", 42), (0, "pg_logtap.export_url", 1), (42, "pg_logtap.export_url", 42)):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw); env = env_for(tmp, "wide_cleanup"); want = initial()
            env["HARNESS_INITIAL_GUCS"] = json.dumps(want)
            if cleanup_failure: env["HARNESS_FAIL_SETGUC"] = cleanup_failure
            driver = tmp / "cleanup.sh"
            driver.write_text(f'''#!/bin/sh
set -u
. "{ROOT / 'tests/e2e/e2e-common.sh'}"
E2E_CT=model E2E_TAG=wide PG_CT=model
SAVED_EXPORT_URL=$(printf %s {want["pg_logtap.export_url"]!r})
SAVED_EXPORT_FALLBACK_FILE=$(printf %s {want["pg_logtap.export_fallback_file"]!r})
SAVED_MESSAGE_MAX={want["pg_logtap.message_max"]!r}
{cleanup.group(0)}
{'(exit 42); ' if original else ''}cleanup
''')
            result = run(["/bin/sh", str(driver)], env=env)
            if result.returncode != expected:
                fail(f"wide cleanup original={original} cleanup_failure={cleanup_failure}: rc={result.returncode}, stderr={result.stderr}")
            if not cleanup_failure:
                restored(env, want, f"wide cleanup original={original}")


def test_hook_restore():
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env = env_for(tmp, "hook_restart")
        env["E2E_OUT"] = str(tmp / "out")
        result = run(["/bin/sh", str(ROOT / "tests/e2e/e2e-hook-chain.sh"), "model"], env=env)
        if result.returncode == 0:
            fail("hook early restart failure returned success")
        trace = "\n".join(joined(env))
        if "CREATE OR REPLACE FUNCTION" in trace:
            fail("hook early restart failure reached SQL probes")
        if "ALTER SYSTEM SET shared_preload_libraries = 'oldpreload'" not in trace:
            fail("hook early failure did not restore saved preload")
        if "guc=pg_logtap.export_url -v value=oldurl" not in trace:
            fail("hook early failure did not restore pre-mutation URL through setguc")

    for mode, want_success in (("hook_zero", True), ("hook_missing", False)):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            env = env_for(tmp, mode)
            env["E2E_OUT"] = str(tmp / "out")
            result = run(["/bin/sh", str(ROOT / "tests/e2e/e2e-hook-chain.sh"), "model"], env=env)
            trace = "\n".join(joined(env))
            armed = "hookchain_arm(true)" in trace
            if not armed:
                fail(f"hook {mode}: clean zero baseline did not reach the armed probe")
            if want_success:
                if result.returncode:
                    fail(f"hook zero baseline unexpectedly failed: {result.stderr}")
            elif result.returncode == 0 or "nested WARNING missing or unbounded" not in result.stderr:
                fail("hook missing-warning path did not reach its diagnostic assertion")


def tls_module():
    source = (ROOT / "tests/e2e/e2e-tls.sh").read_text()
    match = re.search(r"cat > \"\$DIR/receiver\.py\" <<'PYEOF'\n(.*?)\nPYEOF", source, re.S)
    assert match, "TLS receiver heredoc not found"
    embedded = match.group(1)
    tree = ast.parse(embedded, filename="e2e-tls receiver")
    keep = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.ClassDef, ast.FunctionDef))]
    env = {}
    exec(compile(ast.fix_missing_locations(ast.Module(body=keep, type_ignores=[])), "e2e-tls receiver", "exec"), env)
    return env


class _Conn:
    def __init__(self, values):
        self.values = iter(values)
        self.closed = 0
    def recv(self, _):
        return next(self.values)
    def close(self):
        self.closed += 1


class _Server:
    def __init__(self, conns):
        self.conns = iter(conns)
        self.accepted = 0
    def setsockopt(self, *_): pass
    def bind(self, *_): pass
    def listen(self, *_): pass
    def accept(self):
        self.accepted += 1
        return next(self.conns), ("fixture", 1)


class _Sockets:
    AF_INET = SOCK_STREAM = SOL_SOCKET = SO_REUSEADDR = SO_RCVBUF = 1
    def __init__(self, server): self.server = server
    def socket(self): return self.server


def test_tls_fixture_semantics():
    env = tls_module()
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        env["d"] = str(tmp)
        # Execute the actual embedded plain dribbler with two accepted fixture
        # peers.  The first returns a byte then EOF; the second is EOF-only.
        plain = [_Conn([b"x", b""]), _Conn([b""])]
        server = _Server(plain)
        func = types.FunctionType(env["dribble_write"].__code__,
                                  {**env, "socket": _Sockets(server), "d": str(tmp),
                                   "time": types.SimpleNamespace(sleep=lambda _: None)})
        try:
            func(1)
        except StopIteration:
            pass
        if server.accepted != 3 or any(not conn.closed for conn in plain):
            fail("plain write dribbler did not stop at EOF and close two accepted peers")
        if "connected" not in (tmp / "wdrib-evidence").read_text() or "bytes" not in (tmp / "wdrib-evidence").read_text():
            fail("plain write dribbler lacks connection/byte stage evidence")

        class QueuedThread:
            pending = []
            def __init__(self, *, target, args=(), daemon=None):
                self.target, self.args, self.daemon = target, args, daemon
            def start(self):
                self.pending.append(self)
            def run(self):
                self.target(*self.args)

        raw_conns = [_Conn([]), _Conn([])]
        tls_conns = [_Conn([b"P", b""]), _Conn([b"{", b""])]
        server = _Server(raw_conns)
        class Context:
            def __init__(self): self.items = iter(tls_conns)
            def wrap_socket(self, _raw, server_side): return next(self.items)
        func = types.FunctionType(env["dribble_write_tls"].__code__,
                                  {**env, "socket": _Sockets(server), "d": str(tmp),
                                   "threading": types.SimpleNamespace(Thread=QueuedThread),
                                   "time": types.SimpleNamespace(sleep=lambda _: None)})
        try:
            func(1, Context())
        except StopIteration:
            pass
        if server.accepted != 3 or len(QueuedThread.pending) != 2 or not all(item.daemon for item in QueuedThread.pending):
            fail("TLS write dribbler did not dispatch two accepted peers before either handler ran")
        for handler in QueuedThread.pending:
            handler.run()
        if any(not conn.closed for conn in raw_conns + tls_conns):
            fail("TLS write dribbler did not stop at EOF and close wrapper plus accepted socket")
        evidence = (tmp / "tdrib-evidence").read_text()
        https_stage = {"https-connected", "https-handshake", "https-bytes"}
        tcps_stage = {"tcps-connected", "tcps-handshake", "tcps-bytes"}
        if not https_stage <= set(evidence.splitlines()) or not tcps_stage <= set(evidence.splitlines()):
            fail("TLS write dribbler did not retain HTTPS and tcps stage evidence")

        # A late HTTPS session cannot satisfy the tcps assertion: only a fresh
        # raw-NDJSON byte through the actual fixture creates tcps stage lines.
        QueuedThread.pending.clear()
        (tmp / "tdrib-evidence").unlink()
        raw_conns = [_Conn([])]
        tls_conns = [_Conn([b"{", b""])]
        server = _Server(raw_conns)
        class TcpsContext:
            def wrap_socket(self, _raw, server_side): return tls_conns.pop(0)
        func = types.FunctionType(env["dribble_write_tls"].__code__,
                                  {**env, "socket": _Sockets(server), "d": str(tmp),
                                   "threading": types.SimpleNamespace(Thread=QueuedThread),
                                   "time": types.SimpleNamespace(sleep=lambda _: None)})
        try:
            func(1, TcpsContext())
        except (IndexError, StopIteration):
            pass
        if len(QueuedThread.pending) != 1 or not QueuedThread.pending[0].daemon:
            fail("TLS write dribbler did not dispatch the fresh tcps peer")
        QueuedThread.pending[0].run()
        if not tcps_stage <= set((tmp / "tdrib-evidence").read_text().splitlines()):
            fail("TLS write dribbler lacks fresh tcps connection/handshake/byte evidence")

        evil = env.get("HEvil")
        if evil is None:
            fail("impostor receiver does not use the HTTP body/gzip handler")
        payload = b'{"detector":"live"}\n'
        encoded = gzip.compress(payload)
        request = object.__new__(evil)
        request.rfile = io.BytesIO(encoded)
        request.headers = {"Content-Length": str(len(encoded)), "Content-Encoding": "gzip"}
        request.wfile = io.BytesIO()
        status = []
        request.send_response = status.append
        request.send_header = lambda *_: None
        request.end_headers = lambda: None
        request.do_POST()
        if status != [200] or (tmp / "evil-out.jsonl").read_bytes() != payload:
            fail("impostor handler did not record decoded body before a successful status")

        # Shell-parse the actual assignment; this catches shell/Python escaping
        # regressions rather than exercising a separately reconstructed probe.
        source = (ROOT / "tests/e2e/e2e-tls.sh").read_text()
        assignment = re.search(r"^EVIL_PROBE=.*$", source, re.M)
        if assignment is None:
            fail("TLS impostor probe assignment not found")
        parsed = subprocess.run(["/bin/sh", "-c", assignment.group(0) + '\nprintf %s "$EVIL_PROBE"'],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if parsed.returncode:
            fail(f"TLS impostor probe shell parse failed: {parsed.stderr}")
        sent, addresses = [], []
        raw = object()
        class ProbeTLS:
            closed = 0
            def sendall(self, data): sent.append(data)
            def recv(self, _): return b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            def close(self): self.closed += 1
        tls = ProbeTLS()
        context = types.SimpleNamespace(wrap_socket=lambda value, server_hostname: (
            tls if value is raw and server_hostname == "localhost" else None))
        fake_socket = types.SimpleNamespace(create_connection=lambda address: (addresses.append(address) or raw))
        fake_ssl = types.SimpleNamespace(_create_unverified_context=lambda: context)
        old_argv = sys.argv
        try:
            with patch.dict(sys.modules, {"socket": fake_socket, "ssl": fake_ssl}):
                sys.argv = ["probe", "9443"]
                exec(compile(parsed.stdout, "actual shell-parsed EVIL_PROBE", "exec"), {})
        finally:
            sys.argv = old_argv
        if addresses != [("127.0.0.1", 9443)] or tls.closed != 1 or len(sent) != 1:
            fail("TLS impostor probe did not use its mocked endpoint and close after ACK")
        headers, body = sent[0].split(b"\r\n\r\n", 1)
        if b"\\r\\n" in sent[0] or headers.split(b"\r\n")[0] != b"POST /insert/jsonline HTTP/1.1":
            fail("TLS impostor probe did not emit real CRLF HTTP framing")
        fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
        if fields.get(b"Content-Length") != str(len(body)).encode() or gzip.decompress(body) != b'{"detector":"evil-live"}\n':
            fail("TLS impostor probe did not frame the gzip detector payload")

        source = (ROOT / "tests/e2e/e2e-tls.sh").read_text()
        helper = re.search(r"sync_receiver_file\(\) \{\n.*?\n\}", source, re.S)
        if helper is None:
            fail("TLS receiver evidence helper not found")
        for mode, stale, expected_rc in (("missing", False, 0), ("copy_fail", False, 99),
                                         ("missing", True, 99), ("inspect_fail", False, 99)):
            bindir = tmp / f"sync-{mode}-{stale}"; bindir.mkdir()
            write_exe(bindir / "docker", '''#!/bin/sh
case "$1" in
  exec)
    [ "$#" = 5 ] && [ "$2" = model ] && [ "$3" = test ] && [ "$4" = -e ] || exit 97
    case "$5" in /private/*.jsonl) ;; *) exit 97 ;; esac
    case "$HARNESS_MODE" in missing) exit 1 ;; inspect_fail) exit 78 ;; *) exit 0 ;; esac ;;
  cp)
    [ "$#" = 3 ] || exit 97
    case "$2" in model:/private/*.jsonl) ;; *) exit 97 ;; esac
    case "$3" in /*) ;; *) exit 97 ;; esac
    [ "$HARNESS_MODE" = copy_fail ] && exit 77; exit 0 ;;
  *) exit 97 ;;
esac
''')
            local = tmp / f"{mode}-{stale}.jsonl"
            if stale: local.write_text("stale\n")
            driver = tmp / f"sync-{mode}-{stale}.sh"
            driver.write_text(f'''#!/bin/sh
fail() {{ printf 'FAIL:%s\\n' "$*" >&2; exit 99; }}
TLS_PYTHON=python TLS_CT_ID=model TLS_DIR_IN_CT=/private
{helper.group(0)}
sync_receiver_file "{local}"
printf AFTER
''')
            result = subprocess.run(["/bin/sh", str(driver)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env={**os.environ, "PATH": str(bindir) + ":/usr/bin:/bin", "HARNESS_MODE": mode})
            if result.returncode != expected_rc or (expected_rc == 0) != ("AFTER" in result.stdout):
                fail(f"TLS receiver evidence {mode}/{stale} did not fail closed: {result.stderr}")
            docker = bindir / "docker"
            if any(subprocess.run(command, env={**os.environ, "PATH": str(bindir) + ":/usr/bin:/bin", "HARNESS_MODE": mode}).returncode == 0
                   for command in ([str(docker), "cp", "unexpected", str(local)],
                                   [str(docker), "exec", "model", "sh", "-c", "UNEXPECTED_TASK7_REVIEW_COMMAND"])):
                fail("TLS sync fixture accepted an unexpected command")

        stage_helper = re.search(r"require_tdrib_stage\(\) \{.*?^\}", source, re.S | re.M)
        if stage_helper is None:
            fail("TLS tcps stage assertion helper not found")
        stage_file = tmp / "stage-evidence"
        stage_file.write_text("https-connected\nhttps-handshake\nhttps-bytes\n")
        driver = tmp / "stage-assert.sh"
        driver.write_text(f'''#!/bin/sh
fail() {{ printf 'FAIL:%s\\n' "$*" >&2; exit 99; }}
DIR="{tmp}"
{stage_helper.group(0)}
require_tdrib_stage tcps "{stage_file}"
printf AFTER
''')
        result = subprocess.run(["/bin/sh", str(driver)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 99 or "phase 14 tcps" not in result.stderr:
            fail("late HTTPS evidence satisfied the actual tcps stage assertion")
        stage_file.write_text(stage_file.read_text() + "tcps-connected\ntcps-handshake\ntcps-bytes\n")
        result = subprocess.run(["/bin/sh", str(driver)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode or "AFTER" not in result.stdout:
            fail("fresh tcps evidence did not satisfy the actual stage assertion")


def test_tls_received_caller_propagation():
    source = (ROOT / "tests/e2e/e2e-tls.sh").read_text()
    helpers = [re.search(rf"{name}\(\) \{{[^\n]*\n.*?\n\}}", source, re.S)
               for name in ("sync_receiver_file", "received", "received_count")]
    caller = re.search(r'received_count p2fail "\$OUT"\n\[ "\$RECEIVED" = 0 \] \|\| \{ echo "e2e-tls: phase 2 leaked \$RECEIVED events through an unverified handshake"; exit 1; \}', source)
    if any(item is None for item in helpers) or caller is None:
        fail("TLS checked receiver caller body not found")
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw); bindir = tmp / "receiver-caller-bin"; bindir.mkdir()
        write_exe(bindir / "docker", r'''#!/bin/sh
case "$1" in
  exec)
    [ "$#" -ge 3 ] && [ "$2" = model ] || exit 97
    if [ "$3" = test ]; then
      [ "$#" = 5 ] && [ "$4" = -e ] && [ "$5" = /private/evidence.jsonl ] || exit 97
      [ "$HARNESS_MODE" = copy_fail ] && exit 0; exit 1
    fi
    [ "$#" = 7 ] && [ "$3" = psql ] && [ "$4" = -U ] && [ "$5" = postgres ] && [ "$6" = -Atc ] && [ "$7" = "SELECT pg_logtap_stats()" ] || exit 97
    : > "$HARNESS_STATS" ;;
  cp)
    [ "$#" = 3 ] && [ "$2" = model:/private/evidence.jsonl ] && [ "$3" = "$HARNESS_OUT" ] || exit 97
    [ "$HARNESS_MODE" = copy_fail ] && exit 77; exit 97 ;;
  *) exit 97 ;;
esac
''')
        driver = tmp / "receiver-caller.sh"
        driver.write_text(f'''#!/bin/sh
fail() {{ printf 'FAIL:%s\\n' "$*" >&2; exit 99; }}
TLS_PYTHON=python TLS_CT_ID=model TLS_DIR_IN_CT=/private
E2E_TAG=tls E2E_SUF= OUT="{tmp / 'evidence.jsonl'}"
{chr(10).join(item.group(0) for item in helpers)}
{caller.group(0)}
printf 'SUMMARY\\n'
docker exec model psql -U postgres -Atc "SELECT pg_logtap_stats()"
printf 'FOLLOWING\\n'
''')
        for mode, expected_rc in (("copy_fail", 99), ("missing", 0)):
            stats = tmp / f"stats-{mode}"
            result = subprocess.run(["/bin/sh", str(driver)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env={**os.environ, "PATH": str(bindir) + ":/usr/bin:/bin", "HARNESS_MODE": mode,
                                         "HARNESS_OUT": str(tmp / "evidence.jsonl"), "HARNESS_STATS": str(stats)})
            if result.returncode != expected_rc:
                fail(f"TLS checked receiver caller {mode} returned {result.returncode}: {result.stderr}")
            continued = "SUMMARY\n" in result.stdout or "FOLLOWING\n" in result.stdout or stats.exists()
            if mode == "copy_fail":
                if "could not transfer receiver evidence" not in result.stderr or continued:
                    fail("TLS receiver transfer failure reached summary, stats, or following success")
            elif "SUMMARY\n" not in result.stdout or "FOLLOWING\n" not in result.stdout or not stats.exists():
                fail("TLS missing positive sink did not preserve checked caller success")


def test_tls_adapter_lifecycle():
    source = (ROOT / "tests/e2e/e2e-tls.sh").read_text()
    cleanup = re.search(r"cleanup\(\) \{\n.*?\n\}", source, re.S)
    adapter = re.search(r'if \[ -n "\$TLS_PYTHON" \]; then\n(?P<body>  TLS_DIR_IN_CT=.*?)\nelse\n  \(\n', source, re.S)
    if cleanup is None or adapter is None:
        fail("TLS adapter lifecycle bodies not found")
    cleanup_command = re.search(r"docker exec \"\$TLS_CT_ID\" sh -c '([^']*)' sh", cleanup.group(0))
    if cleanup_command is None:
        fail("TLS adapter cleanup command not found")

    # Shell-parse the current adapter rather than decoding its nested quotes in
    # Python. The capture is then the exact body strict mocks and PID tests run.
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw); bindir = tmp / "capture-bin"; bindir.mkdir()
        write_exe(bindir / "docker", r'''#!/bin/sh
private() {
  case "$1" in /tmp/pg-logtap-tls-tls-*) ;; *) exit 97 ;; esac
  id=${1#/tmp/pg-logtap-tls-tls-}; [ -n "$id" ] || exit 97
  case "$id" in *[!0-9]*) exit 97 ;; esac
}
case "$1" in
  cp)
    [ "$#" = 3 ] && [ "$2" = "$HARNESS_DIR/." ] || exit 97
    case "$3" in immutable-id:*/) dir=${3#immutable-id:}; dir=${dir%/}; private "$dir"; [ "$3" = "immutable-id:$dir/" ] || exit 97 ;; *) exit 97 ;; esac ;;
  exec)
    shift
    if [ "${1:-}" = -e ]; then
      [ "$1" = -e ] && [ "$2" = LD_LIBRARY_PATH ] || exit 97; shift 2
      [ "$1" = -e ] || exit 97; case "$2" in DIR=*) private_dir=${2#DIR=}; private "$private_dir" ;; *) exit 97 ;; esac; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_HTTPS=1 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_TCPS=2 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_EVIL=3 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_CHAIN=4 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_AMBIG=5 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_AUTH=6 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_DRIB=7 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_T12=8 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_WDRIB=9 ] || exit 97; shift 2
      [ "$1" = -e ] && [ "$2" = PORT_TDRIB=10 ] || exit 97; shift 2
    fi
    [ "${1:-}" = immutable-id ] || exit 97; shift
    case "$1" in
      test) [ -z "${private_dir:-}" ] && [ "$#" = 3 ] && [ "$2" = -x ] && [ "$3" = /fixture/python ] || exit 97 ;;
      mkdir) [ -z "${private_dir:-}" ] && [ "$#" = 3 ] && [ "$2" = -p ] || exit 97; private "$3" ;;
      sh) [ "$#" = 8 ] && [ "$2" = -c ] && [ "$4" = sh ] && [ "$5" = /fixture/python ] || exit 97
          dir=${6%/receiver.py}; private "$dir"
          [ "${private_dir:-}" = "$dir" ] && [ "$6" = "$dir/receiver.py" ] && [ "$7" = "$dir/receiver.log" ] && [ "$8" = "$dir/receiver.pid" ] || exit 97
          printf %s "$3" > "$HARNESS_CAPTURE"; exit 78 ;;
      *) exit 97 ;;
    esac ;;
  *) exit 97 ;;
esac
''')
        driver = tmp / "capture-driver.sh"
        driver.write_text(f'''#!/bin/sh
E2E_TAG=tls DIR="{tmp}" TLS_PYTHON=/fixture/python TLS_CT_ID=immutable-id
PORT_HTTPS=1 PORT_TCPS=2 PORT_EVIL=3 PORT_CHAIN=4 PORT_AMBIG=5 PORT_AUTH=6 PORT_DRIB=7 PORT_T12=8 PORT_WDRIB=9 PORT_TDRIB=10
fail() {{ exit 1; }}
{adapter.group('body')}
''')
        capture = tmp / "launcher-body"
        result = subprocess.run(["/bin/sh", str(driver)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env={**os.environ, "PATH": str(bindir) + ":/usr/bin:/bin", "HARNESS_DIR": str(tmp),
                                     "HARNESS_CAPTURE": str(capture)})
        if result.returncode == 0 or not capture.exists() or not capture.read_text():
            fail("current TLS adapter did not reach its shell-parsed launcher")
        launcher_body = capture.read_text()
        docker = bindir / "docker"
        launcher_env = ["-e", "LD_LIBRARY_PATH", "-e", "DIR=/tmp/pg-logtap-tls-tls-123",
                        "-e", "PORT_HTTPS=1", "-e", "PORT_TCPS=2", "-e", "PORT_EVIL=3",
                        "-e", "PORT_CHAIN=4", "-e", "PORT_AMBIG=5", "-e", "PORT_AUTH=6",
                        "-e", "PORT_DRIB=7", "-e", "PORT_T12=8", "-e", "PORT_WDRIB=9",
                        "-e", "PORT_TDRIB=10"]
        for tail in (["test", "-x", "/fixture/python"],
                     ["mkdir", "-p", "/tmp/pg-logtap-tls-tls-123"]):
            for prefix, expected in (([], 0), (launcher_env, 97)):
                result = subprocess.run([str(docker), "exec", *prefix, "immutable-id", *tail],
                                        env={**os.environ, "HARNESS_DIR": str(tmp), "HARNESS_CAPTURE": str(capture)})
                if result.returncode != expected:
                    fail(f"TLS capture fixture {tail[0]} env={bool(prefix)} returned {result.returncode}, expected {expected}")
        negatives = (
            [str(docker), "cp", str(tmp) + "/.", "UNEXPECTED_TASK7_REVIEW_DESTINATION"],
            [str(docker), "exec", "-e", "UNEXPECTED_TASK7_REVIEW_ENV=1", "immutable-id", "mkdir", "-p", "/UNEXPECTED_TASK7_REVIEW_DIRECTORY"],
        )
        if any(subprocess.run(command, env={**os.environ, "HARNESS_DIR": str(tmp), "HARNESS_CAPTURE": str(capture)}).returncode == 0
               for command in negatives):
            fail("TLS capture fixture accepted an unexpected command")

    def run_adapter_case(tmp, mode):
        bindir = tmp / "adapter-bin"; bindir.mkdir()
        write_exe(bindir / "docker", r'''#!/bin/sh
printf '%s\n' "$*" >> "$HARNESS_LOG"
die() { exit 97; }
private() {
  case "$1" in /tmp/pg-logtap-tls-tls-*) ;; *) die ;; esac
  id=${1#/tmp/pg-logtap-tls-tls-}; [ -n "$id" ] || die
  case "$id" in *[!0-9]*) die ;; esac
}
case "$1" in
  cp)
    [ "$#" = 3 ] || die
    if [ "$2" = "$HARNESS_DIR/." ]; then
      case "$3" in immutable-id:*/) dir=${3#immutable-id:}; dir=${dir%/}; private "$dir"; [ "$3" = "immutable-id:$dir/" ] || die ;; *) die ;; esac
      [ "$HARNESS_MODE" = copy_fail ] && exit 77; exit 0
    fi
    case "$2" in immutable-id:*/.) dir=${2#immutable-id:}; dir=${dir%/.}; private "$dir"; [ "$2" = "immutable-id:$dir/." ] || die ;; *) die ;; esac
    [ "$3" = "$HARNESS_DIR/receiver-failed/" ] || die; exit 0 ;;
  exec)
    shift
    while [ "${1:-}" = -e ]; do
      [ "$#" -ge 2 ] || die
      case "$2" in
        LD_LIBRARY_PATH|PORT_HTTPS=1|PORT_TCPS=2|PORT_EVIL=3|PORT_CHAIN=4|PORT_AMBIG=5|PORT_AUTH=6|PORT_DRIB=7|PORT_T12=8|PORT_WDRIB=9|PORT_TDRIB=10) ;;
        DIR=*) private "${2#DIR=}" ;;
        *) die ;;
      esac
      shift 2
    done
    [ "${1:-}" = immutable-id ] || die; shift
    case "${1:-}" in
      test) [ "$#" = 3 ] && [ "$2" = -x ] && [ "$3" = /fixture/python ] || die ;;
      mkdir) [ "$#" = 3 ] && [ "$2" = -p ] || die; private "$3" ;;
      sh)
        [ "${2:-}" = -c ] || die
        if [ "${3:-}" = "$HARNESS_LAUNCH" ]; then
          [ "$#" = 8 ] && [ "$4" = sh ] && [ "$5" = /fixture/python ] || die
          dir=${6%/receiver.py}; private "$dir"
          [ "$6" = "$dir/receiver.py" ] && [ "$7" = "$dir/receiver.log" ] && [ "$8" = "$dir/receiver.pid" ] || die
          printf launch >> "$HARNESS_HITS"
          [ "$HARNESS_MODE" = start_fail ] && exit 78; exit 0
        fi
        [ "${3:-}" = "$HARNESS_CLEANUP" ] || die
        [ "$#" = 6 ] && [ "$4" = sh ] || die
        dir=${5%/receiver.pid}; private "$dir"
        [ "$5" = "$dir/receiver.pid" ] && [ "$6" = "$dir" ] || die ;;
      *) die ;;
    esac ;;
  *) die ;;
esac
''')
        private = f"/tmp/pg-logtap-tls-tls-{os.getpid()}"
        env = {**os.environ, "PATH": str(bindir) + ":/usr/bin:/bin", "HARNESS_LOG": str(tmp / "calls"),
               "HARNESS_HITS": str(tmp / "hits"), "HARNESS_MODE": mode, "HARNESS_DIR": str(tmp),
               "HARNESS_PRIVATE": private, "HARNESS_LAUNCH": launcher_body, "HARNESS_CLEANUP": cleanup_command.group(1)}
        driver = tmp / "adapter-driver.sh"
        driver.write_text(f'''#!/bin/sh
E2E_TAG=tls DIR="{tmp}" TLS_PYTHON=/fixture/python TLS_CT_ID=immutable-id
TLS_DIR_IN_CT= TLS_PID_IN_CT= TLS_DIR_CLEANUP=0 RECV= METRICS_PORT0=9187
PORT_HTTPS=1 PORT_TCPS=2 PORT_EVIL=3 PORT_CHAIN=4 PORT_AMBIG=5 PORT_AUTH=6 PORT_DRIB=7 PORT_T12=8 PORT_WDRIB=9 PORT_TDRIB=10
fail() {{ printf 'FAIL:%s\\n' "$*" >&2; exit 1; }}
setguc() {{ :; }}
reload() {{ :; }}
{cleanup.group(0)}
trap cleanup EXIT INT TERM
{adapter.group('body')}
printf AFTER
''')
        result = subprocess.run(["/bin/sh", str(driver)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        trace = (tmp / "calls").read_text().splitlines() if (tmp / "calls").exists() else []
        docker = bindir / "docker"
        negatives = ([str(docker), "cp", "unexpected", str(tmp)],
                     [str(docker), "exec", "immutable-id", "sh", "-c", "UNEXPECTED_TASK7_REVIEW_COMMAND"])
        if any(subprocess.run(command, env=env).returncode == 0 for command in negatives):
            fail("TLS adapter fixture accepted an unexpected command")
        return result, trace, (tmp / "hits").read_text() if (tmp / "hits").exists() else ""

    for mode in ("copy_fail", "start_fail"):
        with tempfile.TemporaryDirectory() as raw:
            result, trace, hits = run_adapter_case(Path(raw), mode)
            retained = next((i for i, line in enumerate(trace) if line.startswith("cp immutable-id:/tmp/pg-logtap-tls-")), None)
            cleanup_i = next((i for i, line in enumerate(trace) if line.startswith("exec immutable-id sh -c")), None)
            launch_i = next((i for i, line in enumerate(trace) if line.startswith("exec -e LD_LIBRARY_PATH") and " sh -c " in line), None)
            if result.returncode == 0 or retained is None or cleanup_i is None or retained > cleanup_i:
                fail(f"TLS adapter {mode} did not retain output before guarded cleanup")
            if mode == "copy_fail" and (launch_i is not None or hits):
                fail("TLS adapter copy failure reached listener startup")
            if mode == "start_fail" and (launch_i is None or hits != "launch"):
                fail("TLS adapter startup failure missed its actual launcher boundary")

    with tempfile.TemporaryDirectory() as raw:
        result, trace, hits = run_adapter_case(Path(raw), "success")
        if result.returncode or "AFTER" not in result.stdout or hits != "launch":
            fail("TLS adapter success control did not reach its launcher")
        if any(line.startswith("cp immutable-id:/tmp/pg-logtap-tls-") for line in trace):
            fail("TLS adapter success control retained failure artifacts")
        if not any(line.startswith("exec immutable-id sh -c") for line in trace):
            fail("TLS adapter success control missed guarded cleanup")

    def run_launcher(tmp, pid_file):
        bindir = tmp / "launcher-bin"; bindir.mkdir()
        listener = tmp / "listener"
        write_exe(bindir / "nohup", "#!/bin/sh\nexec \"$@\"\n")
        write_exe(bindir / "sleep", "#!/bin/sh\nexit 0\n")
        write_exe(bindir / "python", "#!/bin/sh\nprintf started > \"$HARNESS_LISTENER\"\n")
        result = subprocess.run(["/bin/sh", "-c", launcher_body, "sh", str(bindir / "python"), str(tmp / "receiver.py"), str(tmp / "receiver.log"), str(pid_file)],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env={**os.environ, "PATH": str(bindir) + ":/usr/bin:/bin", "HARNESS_LISTENER": str(listener)})
        for _ in range(50):
            if listener.exists(): break
            time.sleep(.01)
        return result, listener

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        result, listener = run_launcher(tmp, tmp / "missing" / "receiver.pid")
        if result.returncode == 0 or listener.exists():
            fail("TLS launcher started the modeled listener without a recorded PID")

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw); pid_file = tmp / "receiver.pid"
        result, listener = run_launcher(tmp, pid_file)
        if result.returncode or not listener.exists() or not re.fullmatch(r"[0-9]+\n", pid_file.read_text()):
            fail("TLS launcher success control did not record PID before the modeled listener")


def test_actual_finalizers():
    source = ROOT / "tests/e2e/e2e-faults.sh"
    embedded = source.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    tree = ast.parse(embedded, filename=str(source))
    helpers = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
    append_branch = next(node for node in tree.body if isinstance(node, ast.If)
                         and isinstance(node.test, ast.Compare)
                         and isinstance(node.test.comparators[0], ast.Constant)
                         and node.test.comparators[0].value == "--final-append-only")
    finalizers = [
        (next(node.finalbody for node in append_branch.body if isinstance(node, ast.Try)),
         ["/tmp/chmodfail-target", "/tmp/writefail-target", "/tmp/writefail-offsets"],
         [None, "actual.json", "syscalls.log", "export.jsonl", "queue-after.bin", "stats", "log", "sink-read", "queue-read", "resume"]),
        (next(node.finalbody for node in tree.body if isinstance(node, ast.Try)),
         ["/tmp/preadfail-target", "/tmp/preadfail-offsets", "/tmp/payloadfail-target", "/tmp/payloadfail-offsets"],
         [None, "last-actual.json", "last-syscalls.log", "stats", "log"]),
    ]
    expected = {"pg_logtap.export_url": "tcp://saved.example:1234",
                "pg_logtap.export_fallback_file": "/fixture/saved-queue.bin",
                "pg_logtap.level_min": "19", "pg_logtap.flush_interval": "1000"}
    case_count = 0
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        for finalbody, controls, faults in finalizers:
            for fault in faults:
                case_count += 1
                armed, configured, effective, seen = set(controls), dict.fromkeys(expected, "mutated"), dict.fromkeys(expected, "mutated"), []
                def check_output(command, input=None):
                    seen.append(command)
                    assert command[:3] == ["docker", "exec", "model-container"]
                    args = command[3:]
                    if args == ["kill", "-CONT", "123"]:
                        if fault == "resume": raise OSError(errno.ESRCH, "modeled resume failure")
                        return b""
                    if args[:2] == ["rm", "-f"]:
                        assert args[2] in armed; armed.remove(args[2]); return b""
                    if args[:1] == ["cat"]:
                        if fault in ("sink-read", "queue-read"): raise OSError(errno.EIO, "modeled read failure")
                        return b"retained evidence\n"
                    assert args[:7] == ["psql", "-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-Atc"]
                    statement = args[7]
                    if statement.startswith("SHOW "): return effective[statement[5:]].encode()
                    match = re.fullmatch(r"ALTER SYSTEM SET (\S+) = '(.*)'", statement)
                    if match: configured[match[1]] = match[2].replace("''", "'"); return b""
                    if statement == "SELECT pg_reload_conf()": effective.update(configured); return b"t"
                    if fault == "stats": raise OSError(errno.EIO, "modeled stats failure")
                    return b'{"ring_events":0}'
                def shell_run(command, capture_output=False):
                    assert command == ["docker", "exec", "model-container", "cat", "/tmp/fsyncfail.log"]
                    if fault == "log": raise OSError(errno.EIO, "modeled log failure")
                    return types.SimpleNamespace(stdout=b"retained log\n")
                out = root / str(case_count); out.mkdir()
                env = dict(json=json, time=time, ct="model-container", out=out, worker="123",
                           queue="/fixture/queue", sink="/fixture/sink", controls=controls,
                           saved=expected.copy(), subprocess=types.SimpleNamespace(check_output=check_output, run=shell_run))
                exec(compile(ast.Module(body=helpers, type_ignores=[]), str(source), "exec"), env)
                trial = ast.Try(body=ast.parse("raise AssertionError('original failure')").body, handlers=[], orelse=[], finalbody=finalbody)
                code = compile(ast.fix_missing_locations(ast.Module(body=[trial], type_ignores=[])), str(source), "exec")
                wt, wb = Path.write_text, Path.write_bytes
                def write_text(path, *args, **kwargs):
                    if path.name == fault: raise OSError(errno.ENOSPC, "modeled full artifact")
                    return wt(path, *args, **kwargs)
                def write_bytes(path, *args, **kwargs):
                    if path.name == fault: raise OSError(errno.ENOSPC, "modeled full artifact")
                    return wb(path, *args, **kwargs)
                try:
                    with patch.object(Path, "write_text", write_text), patch.object(Path, "write_bytes", write_bytes):
                        exec(code, env)
                except Exception as error:
                    chain = []
                    while error:
                        chain.append(str(error)); error = error.__context__
                else:
                    fail("actual finalizer swallowed the original failure")
                if "original failure" not in chain or armed or configured != expected or effective != expected:
                    fail(f"actual finalizer failed restoration for {fault}: armed={armed}, errors={chain}")
    print(f"actual finalizers: {case_count}/15 restored controls and configured/effective GUCs")
