"""No personal data in a public repo.

The repo already has a privacy gate — `scripts/assemble-demo.sh` refuses to publish the
demo GIF if any captured frame's text contains `$HOME`, the LAN IP, the hostname or an
RFC-1918 literal. It guards the artifact and never looked at the source, and the source
was carrying exactly those categories: a phone named after the author, their real
subnet, their router's model (which names the ISP), and a real home path.

Two halves, because neither can do the other's job:

* **This file** runs in CI on a machine that knows nothing about the author. It can only
  check STRUCTURE — an unrecognised `/Users/<name>`, a `.local` device name, a private
  address outside a closed set of documented fixtures.
* **`scripts/privacy-check.sh`** derives the real needles at run time (`$HOME`, the LAN
  IP, `LocalHostName`, the git author) and greps the same file list. CI cannot know
  those, and committing them to make it possible would be the leak itself.

The allowlists below are deliberately small and closed. Their value is not the specific
values — it is that adding one is a decision someone has to make on purpose, at the
moment when the right question ("is this a real address?") is the obvious one to ask.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent

# Placeholder home directories. Anything else means a real path was pasted in.
ALLOWED_USERS = {"dev", "demo", "CHANGE_ME", "x"}

# Fixture addresses, all documented example values and none of them anyone's real
# network. RFC 5737 (198.51.100/203.0.113/192.0.2) would be tidier, but `classify_remote`
# sorts by RFC-1918 membership, so its `lan` branch can ONLY be exercised with private
# addresses — the tests for the feature's core would be testing the wrong branch.
ALLOWED_PRIVATE_IPS = {
    "10.0.1.1",    # a gateway
    "10.0.1.5",    # the local host in conn fixtures
    "10.0.1.9",    # a remote device
    "10.0.1.37",   # a remote device
    "10.0.1.99",   # a second remote device (distinct-fakes assertions need two)
    "192.168.1.5",  # a second private range, so classify_remote is not tested on one prefix
    "172.16.0.9",   # the third RFC-1918 block — classify_remote must cover all three
}

# Fictional device names. `.local`/`.lan` is how macOS publishes a real device, so any
# other spelling of one is a leak.
ALLOWED_HOSTNAMES = {
    "lab-phone.local",  # the fixture device
    "router.lan",       # the fixture gateway
    "device-1.local",   # demo mode's OWN masked output, quoted in the README
}

_RFC1918 = re.compile(
    r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|192\.168\.\d{1,3}\.\d{1,3}"
    r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"
)
_USER_PATH = re.compile(r"/Users/([A-Za-z0-9_.-]+)")
# NOT `.home`: that alternation matched `Path.home`, a code expression. macOS
# publishes a device as <name>.local, and .lan is the usual router suffix.
_DEVICE_NAME = re.compile(r"\b[\w-]+\.(?:local|lan)\b", re.I)

# Files that legitimately contain address PREFIXES rather than addresses: the classifier
# itself, and this file. Named individually so the exemption cannot silently widen.
_PREFIX_SOURCES = {"app/netwatch.py", "tests/test_privacy.py", "scripts/privacy-check.sh"}


def tracked_text_files() -> "list[Path]":
    """Every tracked file git considers text. Binary (the demo GIF/MP4) is skipped —
    a frame's *pixels* are the demo gate's job, not this one's."""
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=REPO, capture_output=True, text=True, check=True
    )
    files = []
    for name in out.stdout.split("\0"):
        if not name:
            continue
        path = REPO / name
        if not path.is_file():
            continue
        try:
            path.read_text()
        except UnicodeDecodeError:
            continue  # binary
        files.append(path)
    return files


@pytest.fixture(scope="module")
def tracked():
    files = tracked_text_files()
    # A scan over an empty list passes while asserting nothing — the gate that evaluates
    # less than it claims. Pin that we actually found the tree.
    assert len(files) > 20, f"only {len(files)} tracked text files — is git ls-files working?"
    return files


def test_no_real_home_path_is_committed(tracked):
    """`/Users/<someone>` in a public repo names its author. The demo gate already
    refuses to publish a FRAME containing `$HOME`; the source had one anyway."""
    offenders = []
    for path in tracked:
        rel = path.relative_to(REPO).as_posix()
        for line_no, line in enumerate(path.read_text().splitlines(), 1):
            for user in _USER_PATH.findall(line):
                if user not in ALLOWED_USERS:
                    offenders.append(f"{rel}:{line_no} /Users/{user}")
    assert not offenders, (
        "real home paths committed:\n  " + "\n  ".join(offenders)
        + f"\nUse one of {sorted(ALLOWED_USERS)} in fixtures."
    )


def test_no_private_address_outside_the_fixture_allowlist(tracked):
    """A private address in a fixture is fine; the author's own subnet is not. The
    allowlist is closed so a NEW one has to be added deliberately — which is the moment
    to ask whether it came off a real network."""
    offenders = []
    for path in tracked:
        rel = path.relative_to(REPO).as_posix()
        if rel in _PREFIX_SOURCES:
            continue
        for line_no, line in enumerate(path.read_text().splitlines(), 1):
            for ip in _RFC1918.findall(line):
                if ip not in ALLOWED_PRIVATE_IPS:
                    offenders.append(f"{rel}:{line_no} {ip}")
    assert not offenders, (
        "private addresses outside the fixture allowlist:\n  " + "\n  ".join(offenders)
        + "\nIf this is a made-up example, add it to ALLOWED_PRIVATE_IPS with a comment. "
        "If it came off a real network, do not commit it."
    )


def test_no_real_device_name_is_committed(tracked):
    """macOS publishes a device as `<name>.local`, and people name devices after
    themselves. Fixtures get fictional ones."""
    offenders = []
    for path in tracked:
        rel = path.relative_to(REPO).as_posix()
        if rel in _PREFIX_SOURCES:
            continue
        for line_no, line in enumerate(path.read_text().splitlines(), 1):
            for host in _DEVICE_NAME.findall(line):
                if host.lower() not in ALLOWED_HOSTNAMES:
                    offenders.append(f"{rel}:{line_no} {host}")
    assert not offenders, (
        "device names committed:\n  " + "\n  ".join(offenders)
        + f"\nFixtures use {sorted(ALLOWED_HOSTNAMES)}."
    )


def test_the_allowlists_are_all_still_used(tracked):
    """A two-way ratchet. A stale entry is an allowlist that outlived its fixture, and
    the next reader treats it as blessing something nobody checked — the same failure as
    a hand-kept list whose newest member is missing, seen from the other end."""
    blob = "\n".join(p.read_text() for p in tracked)
    unused = sorted(
        {ip for ip in ALLOWED_PRIVATE_IPS if ip not in blob}
        | {h for h in ALLOWED_HOSTNAMES if h not in blob}
    )
    assert not unused, f"allowlist entries no longer used by any fixture: {unused}"


def test_the_gate_can_actually_fail(tmp_path, monkeypatch):
    """An instrument that cannot reject anything is not a check. Feed the scanners a
    file carrying each forbidden shape and confirm every one is caught — otherwise a
    green run here proves only that the regexes never matched."""
    bait = tmp_path / "bait.txt"
    bait.write_text(
        "home = /Users/realperson/projects\n"
        "phone = 192.168.44.7\n"
        "device = Someones-iPhone.local\n"
    )
    monkeypatch.setattr("tests.test_privacy.REPO", tmp_path)

    users = [u for u in _USER_PATH.findall(bait.read_text()) if u not in ALLOWED_USERS]
    ips = [i for i in _RFC1918.findall(bait.read_text()) if i not in ALLOWED_PRIVATE_IPS]
    hosts = [h for h in _DEVICE_NAME.findall(bait.read_text()) if h.lower() not in ALLOWED_HOSTNAMES]
    assert users == ["realperson"], users
    assert ips == ["192.168.44.7"], ips
    assert hosts == ["Someones-iPhone.local"], hosts
