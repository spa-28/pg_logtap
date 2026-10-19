"""One ordered, opt-in native metrics scenario; imports/collection are inert."""
from contextlib import contextmanager
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

import pytest

METRICS_ROOT = Path("/tmp/logtap-metrics")
GUC_NAMES = (
    "pg_logtap.pattern", "pg_logtap.pattern_exclude", "pg_logtap.level_min",
    "pg_logtap.flush_interval", "pg_logtap.export_slow_ms", "pg_logtap.export_timeout_ms",
    "pg_logtap.export_fallback_file", "pg_logtap.fallback_max_mb", "pg_logtap.export_url",
    "pg_logtap.metrics_addr", "pg_logtap.metrics_port",
)
SNAPSHOT_SQL = """
SELECT json_agg(format('ALTER SYSTEM SET %s = %L;', name, current_setting(name)) ORDER BY ord)
  FROM unnest(ARRAY[""" + ", ".join(f"'{name}'" for name in GUC_NAMES) + """])
  WITH ORDINALITY AS gucs(name, ord)
"""
SET_SQL = "SELECT format('ALTER SYSTEM SET %s = %L', :'guc', :'value')\n\\gexec\n"
HTTP_CODE = r'''
exec 3<>/dev/tcp/127.0.0.1/"$2" || exit
printf "GET %s HTTP/1.0\r\n\r\n" "$1" >&3
IFS= read -r -t 8 line <&3 || exit
set -- $line; printf "%s\n" "$2"
'''
PROM_BACKLOG = r'''
exec 3<>/dev/tcp/127.0.0.1/"$1" || exit
printf "GET /metrics HTTP/1.0\r\n\r\n" >&3
while IFS= read -r -t 8 line <&3; do
  case "$line" in "pg_logtap_queue_backlog "*) printf "%s\n" "$line"; exit 0;; esac
done
exit 1
'''
TERMINATION_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)


class MetricsError(RuntimeError):
    """A value-free native failure safe for pytest diagnostics."""


@dataclass(frozen=True)
class Context:
    ct: str
    vec: str
    net: str
    suffix: str
    port: int

    @classmethod
    def from_env(cls, env):
        if env.get("PG_LOGTAP_METRICS_BOOTSTRAPPED") != "1":
            raise MetricsError("metrics requires the e2e-metrics.sh bootstrap")
        values = [env.get(f"PG_LOGTAP_METRICS_{key}", "") for key in ("CT", "VEC", "NET", "SUFFIX", "PORT")]
        ct, vec, net, suffix, port = values
        if not all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value) for value in (ct, vec, net)):
            raise MetricsError("invalid metrics container/network context")
        if not re.fullmatch(r"-[0-9]+", suffix):
            raise MetricsError("invalid metrics marker suffix")
        if not re.fullmatch(r"[0-9]+", port):
            raise MetricsError("invalid metrics port")
        try:
            number = int(port)
        except ValueError:
            raise MetricsError("invalid metrics port") from None
        if not 1 <= number <= 65535:
            raise MetricsError("invalid metrics port")
        return cls(ct, vec, net, suffix, number)


def stat_value(text, key):
    values = [token.partition("=")[2] for token in text.split() if token.partition("=")[0] == key]
    if len(values) != 1 or not re.fullmatch(r"[0-9]+", values[0]):
        raise MetricsError("missing or invalid metrics stats counter")
    return int(values[0])


def parse_prom_backlog(text):
    samples = re.findall(r"^pg_logtap_queue_backlog ([^\r\n]+)\r?$", text, re.MULTILINE)
    if len(samples) == 1:
        try:
            value = Decimal(samples[0])
            if value.is_finite() and value >= 0 and value == value.to_integral_value():
                return int(value)
        except InvalidOperation:
            pass
    raise MetricsError("missing or invalid Prometheus backlog gauge")


@contextmanager
def termination_guard():
    old = {sig: signal.getsignal(sig) for sig in TERMINATION_SIGNALS}

    def begin_cleanup():
        for sig in TERMINATION_SIGNALS:
            signal.signal(sig, signal.SIG_IGN)

    def interrupted(sig, frame):
        begin_cleanup()
        raise KeyboardInterrupt("metrics interrupted")

    try:
        for sig in TERMINATION_SIGNALS:
            signal.signal(sig, interrupted)
        yield begin_cleanup
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


class MetricsScenario:
    """Case-private Docker/psql operations, not a general E2E harness."""

    def __init__(self, context):
        self.context = context
        self.base = METRICS_ROOT / context.ct
        self.restore_file = None
        self.restore_ready = False
        self.scraper_id = None
        self.cidfile = None
        self.output_dir = None
        self.scrape_log = None

    def docker(self, *args, input=None, label="metrics command", check=True):
        try:
            result = subprocess.run(["docker", *args], input=input, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        except (OSError, subprocess.SubprocessError):
            raise MetricsError(f"{label} failed") from None
        if check and result.returncode != 0:
            # Never attach CompletedProcess/CalledProcessError: psql argv/stderr
            # may contain saved URLs, credentials, or arbitrary GUC values.
            raise MetricsError(f"{label} failed")
        return result

    def sql(self, query, *, label="metrics SQL"):
        return self.docker("exec", self.context.ct, "psql", "-X", "-U", "postgres", "-v",
                           "ON_ERROR_STOP=1", "-Atc", query, label=label).stdout.strip()

    def snapshot(self):
        raw = self.sql(SNAPSHOT_SQL, label="GUC snapshot")
        try:
            statements = json.loads(raw)
        except (ValueError, TypeError):
            raise MetricsError("GUC snapshot is not complete") from None
        if (not isinstance(statements, list) or len(statements) != 11
                or not all(isinstance(s, str) and s.strip() and "\x00" not in s for s in statements)):
            raise MetricsError("GUC snapshot is not complete")
        try:
            self.base.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd, path = tempfile.mkstemp(prefix=f"restore{self.context.suffix}-", suffix=".sql", dir=self.base)
            self.restore_file = Path(path)
            with os.fdopen(fd, "w") as saved:
                saved.write("\n".join(statements) + "\n")
                saved.flush()
                os.fsync(saved.fileno())
            self.restore_ready = True
        except OSError:
            raise MetricsError("could not save private GUC recovery file") from None

    def setguc(self, name, value):
        if not re.fullmatch(r"[A-Za-z0-9_.]+", name):
            raise MetricsError("invalid GUC name")
        self.docker("exec", "-i", self.context.ct, "psql", "-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1",
                    "-v", f"guc={name}", "-v", f"value={value}", input=SET_SQL, label="set GUC")

    def reload(self):
        if self.sql("SELECT pg_reload_conf()", label="GUC reload") != "t":
            raise MetricsError("GUC reload failed")

    def setup(self):
        self.snapshot()
        try:
            run_dir = Path(tempfile.mkdtemp(prefix=f"run{self.context.suffix}-", dir=self.base))
            self.output_dir = run_dir / "output"
            self.output_dir.mkdir(mode=0o700)
            self.scrape_log = self.output_dir / "vector-metrics.jsonl"
            config = run_dir / "vector.yaml"
            config.write_text(f"""sources:
  prom:
    type: prometheus_scrape
    endpoints:
      - http://{self.context.ct}:{self.context.port}/metrics
    scrape_interval_secs: 1
sinks:
  file_out:
    type: file
    inputs: [prom]
    path: /var/log/vector-metrics.jsonl
    encoding: {{ codec: json }}
""")
            self.cidfile = run_dir / "scraper.cid"
        except OSError:
            raise MetricsError("could not prepare private metrics scraper files") from None
        name = f"{self.context.ct}-vector-metrics{self.context.suffix}-{uuid.uuid4().hex[:12]}"
        result = self.docker("create", "--cidfile", str(self.cidfile), "--name", name,
                             "--network", self.context.net, "-v", f"{config}:/etc/vector/vector.yaml:ro",
                             "-v", f"{self.output_dir}:/var/log", "timberio/vector:0.57.0-alpine",
                             "--config", "/etc/vector/vector.yaml", label="create metrics scraper")
        identifier = result.stdout.strip()
        if not re.fullmatch(r"[0-9a-f]{64}", identifier):
            raise MetricsError("metrics scraper creation returned no immutable ID")
        self.scraper_id = identifier
        self.docker("start", self.scraper_id, label="start metrics scraper")
        time.sleep(3)

    def cleanup(self):
        errors = []
        if self.restore_ready:
            try:
                saved = self.restore_file.read_bytes().decode("utf-8")
                self.docker("exec", "-i", self.context.ct, "psql", "-X", "-U", "postgres", "-v",
                            "ON_ERROR_STOP=1", input=saved, label="GUC restoration")
                self.reload()
                self.restore_ready = False
            except (MetricsError, OSError):
                errors.append("GUC restoration")
        # A strictly private cidfile also covers interruption just after create.
        # Never recover ownership by name, prefix, regular Vector, or PG ID.
        if self.scraper_id is None and self.cidfile is not None and self.cidfile.exists():
            try:
                identifier = self.cidfile.read_text().strip() if not self.cidfile.is_symlink() else ""
                if not re.fullmatch(r"[0-9a-f]{64}", identifier):
                    raise MetricsError("invalid owned scraper ID")
                self.scraper_id = identifier
            except (MetricsError, OSError):
                errors.append("scraper identity")
        if self.scraper_id is not None:
            try:
                self.docker("rm", "-f", self.scraper_id, label="remove metrics scraper")
                self.scraper_id = None
            except MetricsError:
                errors.append("scraper removal")
        if not errors and self.restore_file is not None:
            try:
                self.restore_file.unlink()
            except OSError:
                errors.append("recovery file removal")
        if errors:
            recovery = f"; recovery file: {self.restore_file}" if self.restore_file is not None else ""
            raise MetricsError("metrics cleanup failed (" + ", ".join(errors) + ")" + recovery)

    def wait_for(self, predicate, tries, label):
        for _ in range(tries):
            if predicate():
                return
            time.sleep(1)
        raise MetricsError(f"{label} timed out after {tries} tries")

    def http_code(self, route):
        result = self.docker("exec", self.context.ct, "bash", "-c", HTTP_CODE, "bash", route,
                             str(self.context.port), check=False)
        return result.stdout.strip() if result.returncode == 0 else ""

    def wait_code(self, route, expected):
        self.wait_for(lambda: self.http_code(route) == str(expected), 15, f"{route} status {expected}")

    def liveness(self):
        if self.http_code("/healthz") != "200" or self.http_code("/livez") != "200":
            raise MetricsError("metrics liveness failed")

    def wait_vector(self):
        self.wait_for(lambda: self.docker("exec", self.context.ct, "bash", "-c",
                                         'exec 3<>/dev/tcp/"$1"/8686', "bash", self.context.vec,
                                         check=False).returncode == 0, 60, "Vector readiness")

    def counter(self, key):
        return stat_value(self.sql("SELECT pg_logtap_stats()"), key)

    def drain_ring(self):
        self.wait_for(lambda: self.counter("ring_events") == 0, 60, "ring drain")

    def backlog(self):
        value = self.sql("SELECT queue_backlog FROM pg_logtap_delivery")
        if not re.fullmatch(r"[0-9]+", value):
            raise MetricsError("invalid SQL backlog")
        return int(value)

    def assert_backlog(self, expected, tries):
        self.wait_for(lambda: self.backlog() == expected, tries, f"SQL backlog {expected}")
        sql = self.backlog()
        prom = parse_prom_backlog(self.docker("exec", self.context.ct, "bash", "-c", PROM_BACKLOG,
                                              "bash", str(self.context.port), label="Prometheus backlog").stdout)
        if sql != expected or prom != sql:
            raise MetricsError(f"quiescent backlog mismatch (SQL={sql}, Prometheus={prom}, expected={expected})")

    def worker_pid(self):
        value = self.sql("SELECT pid FROM pg_stat_activity WHERE backend_type LIKE '%logtap%' LIMIT 1")
        return value if re.fullmatch(r"[0-9]+", value) else ""

    def gen(self, marker, count):
        if (marker, count) not in (("warmup", 1), ("backlog", 10)):
            raise MetricsError("invalid metrics marker")
        self.sql(f"""DO $$ DECLARE i int := 0; BEGIN
    WHILE i < {count} LOOP
      RAISE WARNING 'logtap metrics {marker}{self.context.suffix} %', i;
      i := i + 1;
    END LOOP; END $$""", label="generate metrics markers")

    def exception_probe(self):
        result = self.docker("exec", self.context.ct, "psql", "-X", "-U", "postgres", "-v",
                             "ON_ERROR_STOP=1", "-v", "VERBOSITY=sqlstate", "-qc",
                             "DO $$ BEGIN RAISE EXCEPTION 'metrics e2e'; END $$", check=False)
        if result.returncode not in (1, 3) or not re.search(r"^ERROR:\s+P0001\s*$", result.stderr, re.MULTILINE):
            raise MetricsError("intentional metrics exception probe did not reach the server")

    def wait_scrapes(self):
        for _ in range(12):
            try:
                got = sum("pg_logtap_events_captured_total" in line for line in self.scrape_log.read_text().splitlines())
            except FileNotFoundError:
                got = 0
            except OSError:
                raise MetricsError("could not read metrics scrape output") from None
            if got >= 1:
                return got
            time.sleep(1)
        raise MetricsError("no captured-events metric in 12 scrape attempts")

    # Groups 1..8 preserve the old script's assertion ordering and wait budgets.
    def check_scrapes(self):
        self.setguc("pg_logtap.metrics_addr", "0.0.0.0")
        self.setguc("pg_logtap.metrics_port", str(self.context.port))
        self.reload()
        self.exception_probe()
        got = self.wait_scrapes()
        time.sleep(2)  # Vector file-sink batch flush, as in the shell scenario.
        print(f"scrapes_with_metrics={got}")

    def isolate_capture(self):
        for name, value in (("pattern", "^logtap metrics "), ("pattern_exclude", ""), ("level_min", "19"),
                            ("flush_interval", "100"), ("export_slow_ms", "0"), ("export_timeout_ms", "1000"),
                            ("export_url", f"http://{self.context.vec}:8686")):
            self.setguc(f"pg_logtap.{name}", value)
        self.reload()
        time.sleep(2)
        self.wait_vector()
        self.drain_ring()
        self.assert_backlog(0, 30)
        self.setguc("pg_logtap.export_fallback_file", f"pg_logtap-metrics{self.context.suffix}.bin")
        self.setguc("pg_logtap.fallback_max_mb", "64")
        self.reload()
        time.sleep(1)

    def check_startup(self):
        oldpid = self.worker_pid()
        if not oldpid:
            raise MetricsError("metrics worker not found")
        self.docker("exec", self.context.ct, "kill", "-TERM", oldpid, label="worker TERM")
        self.wait_for(lambda: (newpid := self.worker_pid()) and newpid != oldpid, 15, "worker respawn")
        self.wait_code("/readyz", 503)
        self.liveness()
        self.gen("warmup", 1)
        self.wait_code("/readyz", 200)
        self.drain_ring()
        time.sleep(1)

    def check_unrelated_reload(self):
        sent, replayed = self.counter("events_sent"), self.counter("events_replayed")
        self.setguc("pg_logtap.flush_interval", "200")
        self.reload()
        time.sleep(1)
        if self.http_code("/readyz") != "200":
            raise MetricsError("unrelated SIGHUP cleared readiness")
        if self.counter("events_sent") != sent or self.counter("events_replayed") != replayed:
            raise MetricsError("unexpected delivery hid unrelated-SIGHUP readiness")

    def check_failed_receiver(self):
        failed = self.counter("send_cycles_failed")
        self.setguc("pg_logtap.export_url", "http://pglogtap-silent:9499")
        self.reload()
        self.wait_code("/readyz", 503)
        if self.counter("send_cycles_failed") != failed:
            raise MetricsError("URL reset was tested only after a failed send")
        self.gen("backlog", 10)
        self.assert_backlog(10, 20)
        if self.http_code("/readyz") != "503":
            raise MetricsError("failed receiver reported ready")
        self.liveness()

    def check_recovery(self):
        self.setguc("pg_logtap.export_url", f"http://{self.context.vec}:8686")
        self.reload()
        self.wait_code("/readyz", 200)
        self.assert_backlog(0, 30)

    def check_disabled_export(self):
        self.setguc("pg_logtap.export_url", "")
        self.reload()
        self.wait_code("/readyz", 503)
        self.liveness()

    def check_fragmented_request(self):
        client = Path(__file__).with_name("metrics_fragmented_client.py")
        self.docker("run", "--rm", "--network", self.context.net, "-v",
                    f"{client}:/metrics_fragmented_client.py:ro", "python:3-alpine", "python",
                    "/metrics_fragmented_client.py", self.context.ct, str(self.context.port),
                    label="fragmented metrics GET")

    def run(self):
        self.check_scrapes()
        self.isolate_capture()
        self.check_startup()
        self.check_unrelated_reload()
        self.check_failed_receiver()
        self.check_recovery()
        self.check_disabled_export()
        self.check_fragmented_request()


@pytest.mark.e2e
def test_metrics():
    context = Context.from_env(os.environ)
    scenario = MetricsScenario(context)
    with termination_guard() as begin_cleanup:
        primary_failure = False
        try:
            scenario.setup()
            scenario.run()
        except BaseException:
            primary_failure = True
            raise
        finally:
            begin_cleanup()
            try:
                scenario.cleanup()
            except MetricsError as error:
                if not primary_failure:
                    raise
                print(str(error), file=sys.stderr)
