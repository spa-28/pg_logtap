#!/usr/bin/env python3
"""Validate both release archives before extracting; no third-party modules."""
import io
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zlib


SQL = re.compile(r"extension/pg_logtap--[0-9]+\.[0-9]+\.[0-9]+(?:--[0-9]+\.[0-9]+\.[0-9]+)?\.sql\Z")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def members(archive, debug, version):
    seen = set()
    files = {}
    dirs = {"", "lib"} if debug else {"", "lib", "extension"}
    for member in archive:
        name = member.name
        if name.startswith("./"):
            name = name[2:]
        if name == ".":
            name = ""
        require(not name.startswith("/") and "\\" not in name and
                (not name or all(p not in ("", ".", "..") for p in name.split("/"))),
                "unsafe archive path: " + member.name)
        require(name not in seen, "duplicate archive path: " + name)
        seen.add(name)
        if member.isdir():
            require(name in dirs, "unexpected directory: " + name)
            continue
        require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and not member.issparse(),
                "non-regular archive member: " + name)
        allowed = (name == "lib/pg_logtap.so.debug") if debug else (
            name in ("lib/pg_logtap.so", "extension/pg_logtap.control") or SQL.fullmatch(name))
        require(allowed, "unexpected archive member: " + name)
        files[name] = member
    required = {"lib/pg_logtap.so.debug"} if debug else {
        "lib/pg_logtap.so", "extension/pg_logtap.control",
        "extension/pg_logtap--" + version + ".sql"}
    require(required <= files.keys(), "missing required archive members")
    if not debug:
        control = archive.extractfile(files["extension/pg_logtap.control"]).read().decode("utf-8")
        match = re.search(r"^default_version\s*=\s*'([^']+)'", control, re.MULTILINE)
        require(match and match.group(1) == version, "archive control version mismatch")
    return files


def glibc_versions(text):
    names = set(re.findall(r"\bGLIBC_([A-Za-z0-9_.]+)", text))
    require(names, "ELF has no GLIBC requirements")
    for name in names:
        require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", name), "unsupported GLIBC requirement: " + name)
        numbers = tuple(int(n) for n in name.split("."))
        require((numbers + (0, 0, 0))[:3] <= (2, 28, 0), "GLIBC requirement exceeds 2.28: " + name)


def readelf(*args):
    return subprocess.check_output(["readelf", "-W"] + list(args), env=dict(os.environ, LC_ALL="C")).decode("utf-8")


def elf_pair(runtime, debug, arch):
    machines = {"amd64": "Advanced Micro Devices X86-64", "arm64": "AArch64"}
    require(arch in machines, "unsupported architecture: " + arch)
    machine = machines[arch]
    for path in (runtime, debug):
        header = readelf("-h", str(path))
        require(re.search(r"Class:\s+ELF64\b", header) and
                re.search(r"Data:.*little endian", header) and
                re.search(r"Type:\s+DYN\b", header) and
                re.search(r"Machine:\s+" + re.escape(machine) + r"\s*$", header, re.MULTILINE),
                "wrong ELF architecture/type: " + str(path))
    glibc_versions(readelf("--version-info", str(runtime)))
    sections = readelf("-S", str(runtime))
    require(".gnu_debuglink" in sections and not re.search(r"\.(?:zdebug_|debug_)", sections),
            "runtime must have debuglink and no DWARF")
    debug_sections = readelf("-S", str(debug))
    require(all(section in debug_sections for section in (".debug_info", ".debug_abbrev", ".debug_line")),
            "debug archive has no complete DWARF")
    link = runtime.parent / "debuglink.bin"
    copy = runtime.parent / "objcopy-output.so"
    # objcopy's implicit output rewrites its input; never alter the smoked .so.
    subprocess.check_call(["objcopy", "--dump-section", ".gnu_debuglink=" + str(link), str(runtime), str(copy)])
    copy.unlink()
    data = link.read_bytes()
    end = data.find(b"\0")
    require(end >= 0 and data[:end] == b"pg_logtap.so.debug", "wrong debuglink filename")
    crc_offset = (end + 4) & ~3
    require(len(data) == crc_offset + 4 and not any(data[end:crc_offset]), "invalid debuglink payload")
    expected = struct.unpack("<I", data[crc_offset:])[0]
    require(expected == zlib.crc32(debug.read_bytes()) & 0xffffffff, "debuglink CRC mismatch")
    link.unlink()


def validate(runtime, debug, arch, version, destination):
    # Open both once: validation and extraction use the same file descriptors.
    with tarfile.open(runtime, "r:gz") as rt, tarfile.open(debug, "r:gz") as dt:
        runtime_files = members(rt, False, version)
        debug_files = members(dt, True, version)
        with tempfile.TemporaryDirectory(prefix="archive-smoke-") as temp:
            root = Path(temp)
            for archive, files in ((rt, runtime_files), (dt, debug_files)):
                for name, member in files.items():
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, path.open("wb") as target:
                        shutil.copyfileobj(source, target)
            elf_pair(root / "lib/pg_logtap.so", root / "lib/pg_logtap.so.debug", arch)
            if destination:
                # Only publish an entirely validated pair to a fresh directory.
                shutil.copytree(str(root), destination)
    print("archive paths, ELF/glibc and detached DWARF/CRC: OK")


def self_test():
    version = "1.2.3"
    valid = [("lib/pg_logtap.so", tarfile.REGTYPE),
             ("extension/pg_logtap.control", tarfile.REGTYPE),
             ("extension/pg_logtap--1.2.3.sql", tarfile.REGTYPE)]

    def fixture(path, entries):
        with tarfile.open(str(path), "w:gz") as archive:
            for name, kind in entries:
                item = tarfile.TarInfo(name)
                item.type = kind
                item.linkname = "lib/pg_logtap.so"
                data = b"default_version = '1.2.3'\n"
                item.size = len(data) if kind == tarfile.REGTYPE else 0
                archive.addfile(item, io.BytesIO(data) if item.size else None)

    cases = [("/lib/pg_logtap.so", tarfile.REGTYPE),
             ("../pg_logtap.so", tarfile.REGTYPE),
             ("lib/../pg_logtap.so", tarfile.REGTYPE),
             ("lib//pg_logtap.so", tarfile.REGTYPE),
             ("./lib/pg_logtap.so", tarfile.REGTYPE),  # normalized duplicate
             ("lib/pg_logtap.so", tarfile.REGTYPE),
             ("extension/unexpected.sql", tarfile.REGTYPE),
             ("lib/pg_logtap.so.debug", tarfile.REGTYPE),
             ("extension/pg_logtap--9.9.9.sql", tarfile.SYMTYPE),
             ("extension/pg_logtap--9.9.9.sql", tarfile.LNKTYPE),
             ("extension/pg_logtap--9.9.9.sql", tarfile.GNUTYPE_SPARSE),
             ("lib/device", tarfile.CHRTYPE),
             ("lib/fifo", tarfile.FIFOTYPE),
             ("unexpected", tarfile.DIRTYPE)]
    with tempfile.TemporaryDirectory(prefix="archive-negative-") as temp:
        path = Path(temp) / "fixture.tar.gz"
        fixture(path, valid)
        with tarfile.open(str(path)) as archive:
            members(archive, False, version)
        for bad in cases:
            fixture(path, valid + [bad])
            try:
                with tarfile.open(str(path)) as archive:
                    members(archive, False, version)
            except ValueError:
                pass
            else:
                raise AssertionError("accepted unsafe fixture: " + repr(bad))
        fixture(path, [("lib/pg_logtap.so.debug", tarfile.REGTYPE)])
        with tarfile.open(str(path)) as archive:
            members(archive, True, version)
        fixture(path, [("lib/pg_logtap.so.debug", tarfile.REGTYPE)] + valid)
        try:
            with tarfile.open(str(path)) as archive:
                members(archive, True, version)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted runtime members in debug archive")
    glibc_versions("GLIBC_2.2.5 GLIBC_2.28")
    for requirement in ("GLIBC_2.29", "GLIBC_2.9 GLIBC_2.34", "GLIBC_2.28.0.1", "GLIBC_PRIVATE"):
        try:
            glibc_versions(requirement)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted " + requirement)
    print("temporary negative archive fixtures and GLIBC boundaries: OK")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) in (5, 6):
            validate(*sys.argv[1:5], sys.argv[5] if len(sys.argv) == 6 else None)
        else:
            sys.exit("usage: archive-smoke.py runtime.tar.gz debug.tar.gz amd64|arm64 version [new-destination] | --self-test")
    except (ValueError, tarfile.TarError, OSError, subprocess.CalledProcessError) as error:
        sys.exit("archive smoke: " + str(error))
