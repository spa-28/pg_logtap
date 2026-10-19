"""Hostless boundaries for the single native metrics pytest pilot.

No native scenario is run here. Docker is a denying executable for CLI tests;
case helpers see finite subprocess transcripts, and client sockets are doubles.
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time

import pytest

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "tests/e2e/e2e-metrics.sh"
NATIVE = ROOT / "tests/e2e/test_metrics.py"
CLIENT = ROOT / "tests/e2e/metrics_fragmented_client.py"
REAL_RUN = subprocess.run
REAL_POPEN = subprocess.Popen
REAL_UV = shutil.which("uv")
CONTEXT = {
    "PG_LOGTAP_METRICS_BOOTSTRAPPED": "1",
    "PG_LOGTAP_METRICS_CT": "pg-test",
    "PG_LOGTAP_METRICS_VEC": "vector-test",
    "PG_LOGTAP_METRICS_NET": "net_test",
    "PG_LOGTAP_METRICS_SUFFIX": "-123",
    "PG_LOGTAP_METRICS_PORT": "9187",
}
SAVED = [
    "ALTER SYSTEM SET pg_logtap.pattern = 'can''t\\test\nline';",
    "ALTER SYSTEM SET pg_logtap.pattern_exclude = '';",
    "ALTER SYSTEM SET pg_logtap.level_min = '19';",
    "ALTER SYSTEM SET pg_logtap.flush_interval = '100';",
    "ALTER SYSTEM SET pg_logtap.export_slow_ms = '0';",
    "ALTER SYSTEM SET pg_logtap.export_timeout_ms = '1000';",
    "ALTER SYSTEM SET pg_logtap.export_fallback_file = 'saved.bin';",
    "ALTER SYSTEM SET pg_logtap.fallback_max_mb = '64';",
    "ALTER SYSTEM SET pg_logtap.export_url = 'http://fake/it''s\\path';",
    "ALTER SYSTEM SET pg_logtap.metrics_addr = '127.0.0.1';",
    "ALTER SYSTEM SET pg_logtap.metrics_port = '9187';",
]
CID = "a1" * 32


def deny(*args, **kwargs):
    raise AssertionError("unmodeled subprocess/socket boundary")


@pytest.fixture(autouse=True)
def closed_boundaries(monkeypatch):
    monkeypatch.setattr(subprocess, "run", deny)
    monkeypatch.setattr(socket, "create_connection", deny)
    monkeypatch.setattr(socket, "socket", deny)


def native():
    assert NATIVE.is_file(), "native metrics pytest case is not implemented"
    from tests.e2e import test_metrics as metrics
    return metrics


def client():
    assert CLIENT.is_file(), "fragmented client is not extracted"
    from tests.e2e import metrics_fragmented_client
    return metrics_fragmented_client


def executable(path, source):
    path.write_text(source)
    path.chmod(0o755)


@pytest.fixture
def cli_env(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    log = tmp_path / "docker.jsonl"
    # Gate/freshness and failure diagnostics only. Everything else is denied,
    # including the old native shell body during RED.
    executable(bindir / "docker", f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
with open(os.environ["DOCKER_LOG"], "a") as f: f.write(json.dumps(a) + "\\n")
if a == ["inspect", "-f", "{{{{.State.Status}}}}/{{{{.State.ExitCode}}}}", "pglogtap-ready"]:
    print("exited/0"); sys.exit(0)
if len(a) == 6 and a[:3] == ["exec", "pg-test", "psql"] and a[3:5] == ["-U", "postgres"]:
    sys.exit(91)
if a[:3] == ["exec", "pg-test", "psql"] and a[3:6] == ["-U", "postgres", "-Atc"]:
    query = a[6] if len(a) == 7 else ""
    if query == "SELECT 1": print("1"); sys.exit(0)
    if query == "SELECT pg_logtap_version()":
        import re
        version = re.search(r'pub const version = "([^"]+)"', Path(os.environ["TREE_VERSION"]).read_text()).group(1)
        print(version); sys.exit(0)
    if query in ("SELECT pg_logtap_stats()", "SELECT pid || ' ' || backend_type FROM pg_stat_activity WHERE backend_type LIKE '%logtap%'"):
        sys.exit(0)
if a == ["network", "connect", "pglogtap-e2e_default", "pg-test"]: sys.exit(0)
if a == ["start", "pglogtap-vector"]: sys.exit(0)
if a == ["logs", "pg-test"]: sys.exit(0)
if len(a) == 4 and a[:2] == ["inspect", "-f"] and a[3] in ("pg-test", "pglogtap-vector") and a[2].startswith(("pg: ", "receiver: ")): sys.exit(0)
print("DENIED Docker boundary", file=sys.stderr)
sys.exit(91)
''')
    executable(bindir / "uv", f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
keys = [k for k in os.environ if k.startswith("PG_LOGTAP_METRICS_")]
Path(os.environ["UV_LOG"]).write_text(json.dumps({{"args": sys.argv[1:], "cwd": os.getcwd(), "env": {{k: os.environ[k] for k in keys}}}}))
sys.exit(int(os.environ.get("CHILD_STATUS", "0")))
''')
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG_LOGTAP_METRICS_")}
    env.update(PATH=f"{bindir}:/usr/bin:/bin", E2E_OUT=str(tmp_path / "out"),
               E2E_LOCK_DIR=str(tmp_path / "locks"), DOCKER_LOG=str(log),
               UV_LOG=str(tmp_path / "uv.json"), TREE_VERSION=str(ROOT / "src/version.zig"))
    return env


def cli_run(env, args=(), cwd=ROOT, timeout=10):
    return REAL_RUN(["/bin/sh", str(CLI), *args], env=env, cwd=cwd,
                    text=True, capture_output=True, timeout=timeout)


def docker_calls(env):
    path = Path(env["DOCKER_LOG"])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


@pytest.mark.parametrize("port", ["", "0", "65536", "-1", "1.5", "９１８７", "1;echo bad", "9" * 40])
def test_cli_invalid_port_precedes_bootstrap(cli_env, port):
    result = cli_run(cli_env, ["pg-test", port])
    assert result.returncode != 0
    assert docker_calls(cli_env) == [], "bad port reached Docker/bootstrap"
    assert not Path(cli_env["E2E_LOCK_DIR"]).exists()


def test_cli_missing_uv_precedes_implicit_container_lookup(cli_env):
    (Path(cli_env["PATH"].split(":")[0]) / "uv").unlink()
    result = cli_run(cli_env)
    assert result.returncode != 0
    assert docker_calls(cli_env) == [], "missing UV reached default-container Docker lookup"


@pytest.mark.parametrize("name", ["bad name", "bad/name", "-option", ".dot"])
def test_cli_rejects_container_before_lock_or_docker(cli_env, name):
    result = cli_run(cli_env, [name])
    assert result.returncode != 0
    assert docker_calls(cli_env) == []
    assert not Path(cli_env["E2E_LOCK_DIR"]).exists()


@pytest.mark.parametrize("status", [0, 2, 3, 4, 5, 17])
@pytest.mark.parametrize("invocation", ["absolute", "relative", "own-directory"])
def test_cli_native_selection_context_cwd_and_actual_status(cli_env, status, invocation):
    cli_env["CHILD_STATUS"] = str(status)
    cwd, command = {
        "absolute": (ROOT.parent, str(CLI)),
        "relative": (ROOT, "tests/e2e/e2e-metrics.sh"),
        "own-directory": (CLI.parent, "./e2e-metrics.sh"),
    }[invocation]
    result = REAL_RUN(["/bin/sh", command, "pg-test", "09187"], cwd=cwd, env=cli_env,
                      text=True, capture_output=True, timeout=10)
    assert result.returncode == status, result.stderr
    child = json.loads(Path(cli_env["UV_LOG"]).read_text())
    assert child["args"] == ["run", "--project", str(ROOT / "tests"), "--locked", "--only-group", "test",
                             "python", "-m", "pytest", str(NATIVE)]
    assert child["cwd"] == str(ROOT)
    assert child["env"] == {
        "PG_LOGTAP_METRICS_BOOTSTRAPPED": "1", "PG_LOGTAP_METRICS_CT": "pg-test",
        "PG_LOGTAP_METRICS_VEC": "pglogtap-vector", "PG_LOGTAP_METRICS_NET": "pglogtap-e2e_default",
        "PG_LOGTAP_METRICS_SUFFIX": child["env"]["PG_LOGTAP_METRICS_SUFFIX"],
        "PG_LOGTAP_METRICS_PORT": "9187",
    }
    assert child["env"]["PG_LOGTAP_METRICS_SUFFIX"][1:].isascii()
    assert child["env"]["PG_LOGTAP_METRICS_SUFFIX"][1:].isdigit()
    assert "PG_LOGTAP_METRICS_BOOTSTRAPPED" not in cli_env


def test_import_collection_and_missing_context_are_inert(cli_env, tmp_path):
    assert NATIVE.is_file(), "native metrics pytest case is not implemented"
    script = '''
import os, socket, subprocess, sys
calls = []
def forbidden(*a, **kw):
    calls.append(a)
    raise AssertionError("native boundary reached")
subprocess.run = forbidden
subprocess.Popen = forbidden
socket.socket = forbidden
socket.create_connection = forbidden
from tests.e2e import test_metrics as metrics
from tests.e2e import metrics_fragmented_client
assert calls == []
import pytest
status = pytest.main([sys.argv[1], "--collect-only", "-q", "-p", "no:cacheprovider"])
assert status == 0 and calls == []
status = pytest.main([sys.argv[1], "-q", "-p", "no:cacheprovider"])
assert status == 1 and calls == [], (status, calls)
'''
    result = REAL_RUN([sys.executable, "-c", script, str(NATIVE)], cwd=ROOT, env=cli_env,
                      text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "1 test collected" in result.stdout
    assert docker_calls(cli_env) == []


@pytest.mark.parametrize("key,value", [
    ("PG_LOGTAP_METRICS_BOOTSTRAPPED", ""), ("PG_LOGTAP_METRICS_BOOTSTRAPPED", "yes"),
    ("PG_LOGTAP_METRICS_CT", "bad/name"), ("PG_LOGTAP_METRICS_VEC", "x;bad"),
    ("PG_LOGTAP_METRICS_NET", "-bad"), ("PG_LOGTAP_METRICS_SUFFIX", "-x"),
    ("PG_LOGTAP_METRICS_SUFFIX", "-１２"), ("PG_LOGTAP_METRICS_PORT", "０"),
    ("PG_LOGTAP_METRICS_PORT", "0"), ("PG_LOGTAP_METRICS_PORT", "65536"),
])
def test_context_rejects_before_scenario_construction(monkeypatch, key, value):
    metrics = native()
    env = dict(CONTEXT, **{key: value})
    monkeypatch.setattr(metrics, "MetricsScenario", deny)
    monkeypatch.setattr(os, "environ", env)
    with pytest.raises(metrics.MetricsError):
        metrics.test_metrics()


def transcript(monkeypatch, steps):
    """A finite external transcript, never a simulated native product."""
    pending = iter(steps)
    seen = []
    def run(argv, **kwargs):
        check, code, out, err = next(pending)
        check(argv, kwargs)
        seen.append((argv, kwargs))
        return subprocess.CompletedProcess(argv, code, out, err)
    monkeypatch.setattr(subprocess, "run", run)
    return seen


def scenario(tmp_path, monkeypatch):
    metrics = native()
    monkeypatch.setattr(metrics, "METRICS_ROOT", tmp_path)
    return metrics, metrics.MetricsScenario(metrics.Context.from_env(CONTEXT))


def snapshot_command(argv, kw):
    assert argv[:4] == ["docker", "exec", "pg-test", "psql"]
    assert "-X" in argv and "ON_ERROR_STOP=1" in argv
    query = argv[-1]
    assert "format('ALTER SYSTEM SET %s = %L;'" in query
    assert "json_agg" in query and "WITH ORDINALITY" in query
    for name in ("pattern", "pattern_exclude", "level_min", "flush_interval", "export_slow_ms",
                 "export_timeout_ms", "export_fallback_file", "fallback_max_mb", "export_url", "metrics_addr", "metrics_port"):
        assert f"'pg_logtap.{name}'" in query


@pytest.mark.parametrize("code,out", [(1, ""), (0, "not json"), (0, json.dumps(SAVED[:-1])),
                                       (0, json.dumps(SAVED[:-1] + [None]))])
def test_incomplete_snapshot_means_zero_mutations(tmp_path, monkeypatch, code, out):
    metrics, case = scenario(tmp_path, monkeypatch)
    seen = transcript(monkeypatch, [(snapshot_command, code, out, "fake value-bearing error")])
    with pytest.raises(metrics.MetricsError, match="snapshot"):
        case.snapshot()
    case.cleanup()
    assert len(seen) == 1
    assert list(tmp_path.rglob("*.sql")) == []


def test_snapshot_is_exclusive_private_complete_and_outside_mount(tmp_path, monkeypatch):
    metrics, case = scenario(tmp_path, monkeypatch)
    case.base.mkdir()
    previous = case.base / "restore-123.sql"
    previous.write_text("do not overwrite")
    previous.chmod(0o600)
    transcript(monkeypatch, [(snapshot_command, 0, json.dumps(SAVED), "")])
    case.snapshot()
    assert previous.read_text() == "do not overwrite"
    assert case.restore_file != previous
    assert case.restore_file.stat().st_mode & 0o777 == 0o600
    assert case.restore_file.read_text() == "\n".join(SAVED) + "\n"
    assert case.restore_file.parent == case.base


def test_setguc_uses_psql_source_quoting_and_sanitizes(tmp_path, monkeypatch, capsys):
    metrics, case = scenario(tmp_path, monkeypatch)
    value = "fake'quote\\path\nsecond line"
    def quoted(argv, kw):
        assert argv[:5] == ["docker", "exec", "-i", "pg-test", "psql"]
        assert "guc=pg_logtap.export_url" in argv
        assert f"value={value}" in argv
        assert "-X" in argv and "ON_ERROR_STOP=1" in argv
        assert kw["input"] == "SELECT format('ALTER SYSTEM SET %s = %L', :'guc', :'value')\n\\gexec\n"
        assert value not in kw["input"]
        assert "-c" not in argv
    transcript(monkeypatch, [(quoted, 1, value, value)])
    with pytest.raises(metrics.MetricsError) as error:
        case.setguc("pg_logtap.export_url", value)
    assert value not in str(error.value)
    assert value not in capsys.readouterr().out + capsys.readouterr().err
    with pytest.raises(metrics.MetricsError):
        case.setguc("pg_logtap.bad;SQL", "x")


@pytest.mark.parametrize("text,key,want", [
    ("events_sent=12 events_replayed=3 ring_events=0", "events_sent", 12),
    (" events_sent=0\nring_events=00 ", "ring_events", 0),
    ("xevents_sent=99 events_sent=7", "events_sent", 7),
])
def test_stats_is_text_key_value_not_json(text, key, want):
    assert native().stat_value(text, key) == want


@pytest.mark.parametrize("text", ["{}", "events_sent=", "events_sent=-1", "events_sent=1.5",
                                      "events_sent=１", "events_sent=1 events_sent=2", "other=1"])
def test_stats_missing_duplicate_or_invalid_counter_fails(text):
    metrics = native()
    with pytest.raises(metrics.MetricsError):
        metrics.stat_value(text, "events_sent")


@pytest.mark.parametrize("text,want", [
    ("# HELP pg_logtap_queue_backlog count\npg_logtap_queue_backlog 10\r\n", 10),
    ("HTTP/1.0 200 OK\r\n\r\npg_logtap_queue_backlog 0\n", 0),
    ("pg_logtap_queue_backlog 1e1\n", 10),
])
def test_prom_backlog_numeric_sample(text, want):
    assert native().parse_prom_backlog(text) == want


@pytest.mark.parametrize("text", ["", "# pg_logtap_queue_backlog 10", "pg_logtap_queue_backlog_extra 10\n",
                                      'pg_logtap_queue_backlog{a="b"} 10\n', "pg_logtap_queue_backlog NaN\n",
                                      "pg_logtap_queue_backlog -1\n", "pg_logtap_queue_backlog 0.5\n",
                                      "pg_logtap_queue_backlog 0\npg_logtap_queue_backlog 1\n"])
def test_prom_backlog_missing_or_ambiguous_fails(text):
    metrics = native()
    with pytest.raises(metrics.MetricsError):
        metrics.parse_prom_backlog(text)


@pytest.mark.parametrize("code,stderr,passes", [(3, "ERROR:  P0001\n", True),
                                                (1, "ERROR:  P0001\n", True),
                                                (0, "", False), (2, "connection failed", False),
                                                (1, "ERROR:  42P01\n", False)])
def test_intentional_exception_is_not_infrastructure_success(tmp_path, monkeypatch, code, stderr, passes):
    metrics, case = scenario(tmp_path, monkeypatch)
    def probe(argv, kw):
        assert "VERBOSITY=sqlstate" in argv
        assert "RAISE EXCEPTION 'metrics e2e'" in argv[-1]
    transcript(monkeypatch, [(probe, code, "", stderr)])
    if passes:
        case.exception_probe()
    else:
        with pytest.raises(metrics.MetricsError):
            case.exception_probe()


def test_fragmented_client_chunks_timing_and_close(monkeypatch):
    module = client()
    calls = []
    class Connection:
        def sendall(self, data): calls.append(("send", data))
        def recv(self, size):
            calls.append(("recv", size))
            return b"HTTP/1.1 200 OK\r\n\r\npg_logtap_events_captured_total 1\n"
        def close(self): calls.append(("close",))
    def connect(address, timeout):
        calls.append(("connect", address, timeout))
        return Connection()
    monkeypatch.setattr(socket, "create_connection", connect)
    monkeypatch.setattr(module.time, "sleep", lambda delay: calls.append(("sleep", delay)))
    module.main(["pg-test", "9187"])
    assert calls == [("connect", ("pg-test", 9187), 8), ("send", b"GET /met"), ("sleep", 0.02),
                     ("send", b"rics HTTP/1.1\r\n\r\n"), ("sleep", 0.3), ("recv", 65536), ("close",)]


@pytest.mark.parametrize("response", [b"HTTP/1.1 404 Not Found\r\npg_logtap_x", b"HTTP/1.1 200 OK\r\n\r\nempty", None])
def test_fragmented_client_closes_on_bad_status_missing_body_and_recv_failure(monkeypatch, response):
    module = client()
    closed = []
    class Connection:
        def sendall(self, data): pass
        def recv(self, size):
            if response is None: raise OSError("controlled recv failure")
            return response
        def close(self): closed.append(True)
    monkeypatch.setattr(socket, "create_connection", lambda *a, **kw: Connection())
    monkeypatch.setattr(module.time, "sleep", lambda _: None)
    with pytest.raises((AssertionError, OSError)):
        module.main(["pg-test", "9187"])
    assert closed == [True]


def restore_command(argv, kw):
    assert argv[:5] == ["docker", "exec", "-i", "pg-test", "psql"]
    assert "-X" in argv and "ON_ERROR_STOP=1" in argv
    assert "-c" not in argv and "-Atc" not in argv
    assert kw["input"] == "\n".join(SAVED) + "\n"


def reload_command(argv, kw):
    assert argv[-1] == "SELECT pg_reload_conf()"


def remove_command(argv, kw):
    assert argv == ["docker", "rm", "-f", CID]


@pytest.mark.parametrize("failure", ["none", "restore", "reload", "remove", "unlink"])
def test_cleanup_restores_stdin_then_reload_and_removes_only_owned_id(tmp_path, monkeypatch, failure):
    metrics, case = scenario(tmp_path, monkeypatch)
    transcript(monkeypatch, [(snapshot_command, 0, json.dumps(SAVED), "")])
    case.snapshot()
    saved_path = case.restore_file
    case.scraper_id = CID
    steps = [(restore_command, int(failure == "restore"), "", "fake secret")]
    if failure != "restore":
        steps.append((reload_command, int(failure == "reload"), "t", "fake secret"))
    steps.append((remove_command, int(failure == "remove"), "", "fake secret"))
    seen = transcript(monkeypatch, steps)
    if failure == "unlink":
        original = Path.unlink
        def fail_unlink(path, *a, **kw):
            if path == saved_path: raise OSError("fake secret")
            return original(path, *a, **kw)
        monkeypatch.setattr(Path, "unlink", fail_unlink)
    if failure == "none":
        case.cleanup()
        assert not saved_path.exists()
    else:
        with pytest.raises(metrics.MetricsError) as error:
            case.cleanup()
        assert "fake secret" not in str(error.value)
        assert saved_path.exists()
    assert len(seen) == len(steps)


@pytest.mark.parametrize("embedded_newline", ["\r", "\r\n"], ids=["literal-CR", "literal-CRLF"])
def test_restore_preserves_literal_carriage_returns_before_deleting_recovery(tmp_path, monkeypatch, embedded_newline):
    _, case = scenario(tmp_path, monkeypatch)
    statements = SAVED.copy()
    statements[0] = f"ALTER SYSTEM SET pg_logtap.pattern = 'before{embedded_newline}after';"
    expected = "\n".join(statements) + "\n"
    transcript(monkeypatch, [(snapshot_command, 0, json.dumps(statements), "")])
    case.snapshot()
    saved_path = case.restore_file
    assert saved_path.read_bytes() == expected.encode("utf-8")

    def exact_restore(argv, kw):
        assert argv[:5] == ["docker", "exec", "-i", "pg-test", "psql"]
        assert "-X" in argv and "ON_ERROR_STOP=1" in argv
        assert "-c" not in argv and "-Atc" not in argv
        assert kw["input"] == expected

    def reload_after_faithful_restore(argv, kw):
        reload_command(argv, kw)
        assert saved_path.exists(), "recovery evidence removed before reload succeeded"

    seen = transcript(monkeypatch, [(exact_restore, 0, "", ""),
                                    (reload_after_faithful_restore, 0, "t", "")])
    case.cleanup()
    assert len(seen) == 2
    assert not saved_path.exists()


def create_command(argv, kw):
    assert argv[:2] == ["docker", "create"]
    assert argv[argv.index("--network") + 1] == "net_test"
    name = argv[argv.index("--name") + 1]
    assert name.startswith("pg-test-vector-metrics-123-")
    assert name != "pg-test-vector-metrics"
    assert "timberio/vector:0.57.0-alpine" in argv
    mounts = [argv[i + 1] for i, value in enumerate(argv) if value == "-v"]
    assert len(mounts) == 2
    config_mount = next(m for m in mounts if m.endswith(":/etc/vector/vector.yaml:ro"))
    output_mount = next(m for m in mounts if m.endswith(":/var/log"))
    config = Path(config_mount.split(":")[0])
    output = Path(output_mount.split(":")[0])
    assert output.is_dir()
    assert "scrape_interval_secs: 1" in config.read_text()
    assert "http://pg-test:9187/metrics" in config.read_text()
    assert not list(output.rglob("*.sql"))


@pytest.mark.parametrize("where", ["create", "start", "body"])
def test_partial_setup_and_body_failure_restore_and_cleanup_without_masking(tmp_path, monkeypatch, capsys, where):
    metrics, case = scenario(tmp_path, monkeypatch)
    monkeypatch.setattr(os, "environ", CONTEXT.copy())
    sleeps = []
    monkeypatch.setattr(metrics.time, "sleep", sleeps.append)
    steps = [(snapshot_command, 0, json.dumps(SAVED), ""),
             (create_command, int(where == "create"), "" if where == "create" else CID, "fake secret")]
    if where != "create":
        def start(argv, kw): assert argv == ["docker", "start", CID]
        steps.append((start, int(where == "start"), "", "fake secret"))
    if where == "body":
        def endpoint(argv, kw): assert "guc=pg_logtap.metrics_addr" in argv
        steps.append((endpoint, 1, "", "fake secret"))
    # Fail restoration too: the primary setup/body error must survive it.
    steps.append((restore_command, 1, "", "fake secret"))
    if where != "create": steps.append((remove_command, 0, "", ""))
    seen = transcript(monkeypatch, steps)
    with pytest.raises(metrics.MetricsError) as error:
        metrics.test_metrics()
    assert "cleanup" not in str(error.value)
    assert "fake secret" not in str(error.value)
    output = capsys.readouterr()
    assert "cleanup" in output.err and "fake secret" not in output.err
    assert len(seen) == len(steps)
    retained = list(case.base.glob("*.sql"))
    assert len(retained) == 1
    assert not list(case.base.glob("run*/output/*.sql"))


def test_owned_cidfile_recovers_create_interruption_and_rejects_names(tmp_path, monkeypatch):
    metrics, case = scenario(tmp_path, monkeypatch)
    def interrupted_create(argv, kw):
        create_command(argv, kw)
        Path(argv[argv.index("--cidfile") + 1]).write_text(CID + "\n")
    transcript(monkeypatch, [(snapshot_command, 0, json.dumps(SAVED), ""),
                            (interrupted_create, 1, "", "controlled interruption")])
    with pytest.raises(metrics.MetricsError):
        case.setup()
    seen = transcript(monkeypatch, [(restore_command, 0, "", ""), (reload_command, 0, "t", ""),
                                    (remove_command, 0, "", "")])
    case.cleanup()
    assert len(seen) == 3
    assert not case.restore_file.exists()
    # A container-looking name is not an immutable ID, even in our cidfile.
    case.scraper_id = None
    case.cidfile.write_text("pg-test-vector-metrics")
    transcript(monkeypatch, [])
    with pytest.raises(metrics.MetricsError):
        case.cleanup()


@pytest.mark.parametrize("sig", [signal.SIGHUP, signal.SIGINT, signal.SIGTERM])
def test_python_guard_interrupts_then_ignores_cleanup_and_restores_handlers(sig):
    metrics = native()
    old = {s: signal.getsignal(s) for s in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    with metrics.termination_guard() as begin_cleanup:
        with pytest.raises(KeyboardInterrupt):
            signal.raise_signal(sig)
        begin_cleanup()
        for repeated in old:
            signal.raise_signal(repeated)
    assert {s: signal.getsignal(s) for s in old} == old


@pytest.mark.parametrize("kind,tries", [("http", 15), ("vector", 60), ("ring", 60)])
def test_probe_waits_preserve_bounds_and_one_second_retry(tmp_path, monkeypatch, kind, tries):
    metrics, case = scenario(tmp_path, monkeypatch)
    sleeps = []
    monkeypatch.setattr(metrics.time, "sleep", sleeps.append)
    def probe(argv, kw):
        if kind == "http":
            assert argv[:4] == ["docker", "exec", "pg-test", "bash"]
            assert argv[-2:] == ["/readyz", "9187"]
            assert "read -r -t 8" in argv[5]
        elif kind == "vector":
            assert argv[-1] == "vector-test"
            assert '/dev/tcp/"$1"/8686' in argv[5]
        else:
            assert argv[-1] == "SELECT pg_logtap_stats()"
    seen = transcript(monkeypatch, [(probe, 1 if kind != "ring" else 0,
                                     "ring_events=1" if kind == "ring" else "", "")] * tries)
    with pytest.raises(metrics.MetricsError):
        {"http": lambda: case.wait_code("/readyz", 503), "vector": case.wait_vector,
         "ring": case.drain_ring}[kind]()
    assert len(seen) == tries
    assert sleeps == [1] * tries


def test_scrape_accepts_matching_lines_without_inventing_vector_schema(tmp_path, monkeypatch):
    metrics, case = scenario(tmp_path, monkeypatch)
    case.scrape_log = tmp_path / "scrapes.jsonl"
    case.scrape_log.write_text("plain pg_logtap_events_captured_total sample\n")
    sleeps = []
    monkeypatch.setattr(metrics.time, "sleep", sleeps.append)
    assert case.wait_scrapes() == 1
    assert sleeps == []
    case.scrape_log.write_text("other_metric 1\n")
    with pytest.raises(metrics.MetricsError):
        case.wait_scrapes()
    assert sleeps == [1] * 12


def test_fragmented_container_mounts_only_client_read_only(tmp_path, monkeypatch):
    metrics, case = scenario(tmp_path, monkeypatch)
    def command(argv, kw):
        assert argv == ["docker", "run", "--rm", "--network", "net_test", "-v",
                        f"{CLIENT}:/metrics_fragmented_client.py:ro", "python:3-alpine", "python",
                        "/metrics_fragmented_client.py", "pg-test", "9187"]
    seen = transcript(monkeypatch, [(command, 0, "", "")])
    case.check_fragmented_request()
    assert len(seen) == 1


def wait_file(path, process, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists(): return
        assert process.poll() is None, f"controlled child exited early: {process.returncode}"
        time.sleep(0.01)
    raise AssertionError(f"controlled child did not create {path.name}")


def lock_held(env):
    with (Path(env["E2E_LOCK_DIR"]) / "lock.pg-test").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False


@pytest.mark.parametrize("actual_uv", [False, True], ids=["fake-child", "actual-uv"])
@pytest.mark.parametrize("sig", [signal.SIGHUP, signal.SIGINT, signal.SIGTERM])
def test_cli_keeps_parent_fd9_through_signal_forwarding_and_child_cleanup(cli_env, tmp_path, sig, actual_uv):
    ready, cleaning, done, release = [tmp_path / name for name in ("ready", "cleaning", "done", "release")]
    child = tmp_path / "controlled_child.py"
    child.write_text('''import os, signal, sys, time
from pathlib import Path
root = Path(os.environ["CONTROLLED_ROOT"])
def interrupted(sig, frame):
    (root / "signal").write_text(str(sig))
    raise InterruptedError
for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM): signal.signal(sig, interrupted)
status = 0
try:
    (root / "ready").write_text(str(os.getpid()))
    while True: time.sleep(0.01)
except InterruptedError:
    status = 37
finally:
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM): signal.signal(sig, signal.SIG_IGN)
    (root / "cleaning").write_text("cleanup started")
    while not (root / "release").exists(): time.sleep(0.01)
    (root / "done").write_text("cleanup finished")
sys.exit(status)
''')
    uv = Path(cli_env["PATH"].split(":")[0]) / "uv"
    cli_env["CONTROLLED_ROOT"] = str(tmp_path)
    if actual_uv:
        assert REAL_UV, "the approved pilot requires an actual UV forwarding proof"
        # No project resolution/shared env lock in the nested controlled child.
        cli_env.update(UV_PROJECT_ENVIRONMENT=str(tmp_path / "nested-env"),
                       UV_CACHE_DIR=str(tmp_path / "nested-cache"), UV_PYTHON_DOWNLOADS="never")
        argv = [REAL_UV, "run", "--no-project", "--offline", "--python", sys.executable,
                "python", str(child)]
    else:
        argv = [sys.executable, str(child)]
    executable(uv, f"#!{sys.executable}\nimport os\nos.execv({argv[0]!r}, {argv!r})\n")
    with (tmp_path / "cli-output").open("w+") as output:
        process = REAL_POPEN(["/bin/sh", str(CLI), "pg-test"], env=cli_env, cwd=ROOT,
                             stdout=output, stderr=output)
        try:
            wait_file(ready, process)
            assert process.poll() is None
            lock_path = Path(cli_env["E2E_LOCK_DIR"]) / "lock.pg-test"
            assert Path(f"/proc/{process.pid}/fd/9").resolve() == lock_path
            assert lock_held(cli_env)
            os.kill(process.pid, sig)
            wait_file(cleaning, process)
            assert (tmp_path / "signal").read_text() == str(sig)
            assert process.poll() is None and lock_held(cli_env)
            # Parent trap must not reenter or release the lock on repetition.
            os.kill(process.pid, sig)
            assert process.poll() is None and lock_held(cli_env)
            release.write_text("finish cleanup")
            status = process.wait(timeout=10)
            assert done.exists()
            assert status == 37, output.read()
            assert not lock_held(cli_env)
        finally:
            release.touch()
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
