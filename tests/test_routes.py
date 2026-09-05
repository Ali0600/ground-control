"""HTTP-level tests for every route.

The routes were the one layer with no coverage at all: the parsers underneath are
tested hard, but nothing exercised the handlers that mutate real jobs — the 404/409
guards, the body validation, or the ordering that decides whether `/api/apps/discover`
reaches its own handler or is swallowed by `/api/apps/{slug}/log`.

Two rules hold this file together:

* **Never `with TestClient(app)`.** The context-manager form runs the lifespan, which
  starts the real 30-second watch loop — shelling out to lsof/ps against the machine
  and writing state. Constructing the client directly does not, so every test here
  drives the routes with the watcher asleep. `test_the_client_does_not_start_the_watcher`
  pins it.
* **Stub at the subprocess boundary, not above it.** Patching `launchd.run_now` would
  test the mock; patching `launchd._run` exercises the handler, the 404 lookup and the
  argv construction, and only stops at the point where a real `launchctl` would run.
"""

from __future__ import annotations

import plistlib

import pytest
from fastapi.testclient import TestClient

from app import apps, launchd, main, netwatch, ports

# NOT a context manager — see the module docstring. `base_url` matters: TrustedHost
# refuses TestClient's default `Host: testserver`, which is correct behaviour, so the
# client addresses the app the way a browser on this machine does.
client = TestClient(main.app, base_url="http://127.0.0.1:8787")

LABEL = "com.example.job"
VENDOR_LABEL = "com.apple.something"
APP_LABEL = "com.launchddash.app.demo"


@pytest.fixture
def agent_plist(tmp_path):
    """Install a fixture plist into the redirected AGENT_DIRS so `find_plist` and
    `list_agents` see exactly one job, plus a vendor one and a dashboard-owned one."""
    target = launchd.AGENT_DIRS[0]
    written = []
    for label in (LABEL, VENDOR_LABEL, APP_LABEL):
        path = target / f"{label}.plist"
        log = tmp_path / f"{label}.log"
        log.write_text("line one\nline two\nline three\n")
        path.write_bytes(plistlib.dumps({
            "Label": label,
            "ProgramArguments": ["/bin/echo", "hi"],
            "StandardOutPath": str(log),
            "StartInterval": 3600,
        }))
        written.append(path)
    yield target
    for path in written:
        path.unlink(missing_ok=True)
    launchd.invalidate_state()


@pytest.fixture
def no_subprocesses(monkeypatch):
    """Every shell-out stubbed: launchctl state/control, lsof, ps."""
    monkeypatch.setattr(launchd, "_launchctl_state_live", lambda label: {"loaded": True})
    monkeypatch.setattr(launchd, "_run", lambda cmd: {"ok": True, "detail": " ".join(cmd), "code": 0})
    monkeypatch.setattr(apps, "_run", lambda cmd: type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})())
    monkeypatch.setattr(ports, "_out", lambda cmd: "")
    launchd.invalidate_state()
    yield
    launchd.invalidate_state()


# --------------------------------------------------------------------------- #
# The harness itself
# --------------------------------------------------------------------------- #
def test_the_client_does_not_start_the_watcher(monkeypatch):
    """A `with TestClient(app)` here would run the lifespan and start the real watch
    loop against the live machine. Prove the plain client never calls it."""
    called = []
    monkeypatch.setattr(main, "_watch_once", lambda: called.append(1))
    client.get("/health")
    assert called == [], "the watch loop ran during a request — is a lifespan active?"


def test_health():
    r = client.get("/health")
    assert r.status_code == 200 and r.json() == {"ok": True}


def test_index_serves_the_page():
    r = client.get("/")
    assert r.status_code == 200
    assert "<title>" in r.text and "text/html" in r.headers["content-type"]


# --------------------------------------------------------------------------- #
# Agents
# --------------------------------------------------------------------------- #
def test_agents_hides_vendor_and_dashboard_apps_by_default(agent_plist, no_subprocesses):
    labels = [a["label"] for a in client.get("/api/agents").json()]
    assert LABEL in labels
    assert VENDOR_LABEL not in labels, "vendor jobs must be hidden without ?all=true"
    assert APP_LABEL not in labels, "dashboard-launched apps belong in the Apps section"


def test_agents_all_true_includes_vendor(agent_plist, no_subprocesses):
    labels = [a["label"] for a in client.get("/api/agents?all=true").json()]
    assert VENDOR_LABEL in labels
    assert APP_LABEL not in labels, "?all=true widens to vendor, never to our own apps"


@pytest.mark.parametrize("action", ["run", "stop", "enable", "disable"])
def test_agent_control_404s_for_an_unknown_label(action, agent_plist, no_subprocesses):
    r = client.post(f"/api/agents/com.example.nope/{action}")
    assert r.status_code == 404
    assert "com.example.nope" in r.json()["detail"]


@pytest.mark.parametrize(
    "action,expect",
    [("run", "kickstart"), ("stop", "kill"), ("enable", "enable"), ("disable", "disable")],
)
def test_agent_control_reaches_launchctl_with_the_right_verb(
    action, expect, agent_plist, no_subprocesses
):
    r = client.post(f"/api/agents/{LABEL}/{action}")
    assert r.status_code == 200 and r.json()["ok"] is True
    assert expect in r.json()["detail"] and LABEL in r.json()["detail"]


def test_expected_exit_is_recorded_for_the_actions_that_kill_a_job(agent_plist, no_subprocesses):
    """run/stop/disable can each terminate a running job. The watcher must not banner
    those as failures, so the label is parked in the expected-exit set — enable, which
    kills nothing, must NOT park one."""
    for action in ("run", "stop", "disable"):
        main._expected_exits.clear()
        client.post(f"/api/agents/{LABEL}/{action}")
        assert LABEL in main._expected_now(), f"{action} should expect an exit"
    main._expected_exits.clear()
    client.post(f"/api/agents/{LABEL}/enable")
    assert LABEL not in main._expected_now(), "enable does not stop anything"
    main._expected_exits.clear()


def test_expected_exit_expires(monkeypatch):
    """A stale entry would permanently mute a real failure for that job."""
    clock = [1000.0]
    monkeypatch.setattr(main.time, "monotonic", lambda: clock[0])
    main._expected_exits.clear()
    main._expect_exit(LABEL)
    assert LABEL in main._expected_now()
    clock[0] += main._EXPECTED_EXIT_TTL_S + 1
    assert LABEL not in main._expected_now()
    assert LABEL not in main._expected_exits, "the expired entry must be dropped, not just hidden"


def test_agent_log_returns_the_tail(agent_plist, no_subprocesses):
    r = client.get(f"/api/agents/{LABEL}/log?lines=2")
    assert r.status_code == 200
    assert r.json()["text"] == "line two\nline three"


def test_agent_log_404s_for_an_unknown_label(agent_plist, no_subprocesses):
    assert client.get("/api/agents/com.example.nope/log").status_code == 404


# --------------------------------------------------------------------------- #
# Apps
# --------------------------------------------------------------------------- #
@pytest.fixture
def one_app(tmp_path, monkeypatch):
    project = tmp_path / "proj"
    project.mkdir()
    apps.CONFIG_PATH.write_text(
        '[{"slug": "demo", "name": "Demo", "dir": "%s", "command": "./dev.sh", "port": 3000}]'
        % project
    )
    monkeypatch.setattr(apps, "tcc_blocked", lambda d: False)
    yield project
    apps.CONFIG_PATH.unlink(missing_ok=True)


def test_apps_lists_the_configured_app(one_app, no_subprocesses):
    [info] = client.get("/api/apps").json()
    assert info["slug"] == "demo" and info["port"] == 3000
    assert info["missing"] is False and info["blocked"] is False


@pytest.mark.parametrize("action", ["start", "stop", "restart"])
def test_app_control_404s_for_an_unknown_slug(action, one_app, no_subprocesses):
    r = client.post(f"/api/apps/nope/{action}")
    assert r.status_code == 404 and "nope" in r.json()["detail"]


def test_app_delete_404s_for_an_unknown_slug(one_app, no_subprocesses):
    assert client.delete("/api/apps/nope").status_code == 404


def test_app_start_refuses_a_missing_directory(one_app, no_subprocesses):
    apps.CONFIG_PATH.write_text(
        '[{"slug": "demo", "name": "Demo", "dir": "/nonexistent/xyz", "command": "./dev.sh"}]'
    )
    r = client.post("/api/apps/demo/start")
    assert r.status_code == 200 and r.json()["ok"] is False
    assert "not found" in r.json()["detail"]


def test_app_log_404s_for_an_unknown_slug(one_app, no_subprocesses):
    assert client.get("/api/apps/nope/log").status_code == 404


def test_discover_is_reachable_and_not_swallowed_by_the_slug_log_route(monkeypatch):
    """`/api/apps/discover` and `/api/apps/{slug}/log` share a prefix. Registration
    order decides which wins; nothing else pins it, and a reorder would turn scanning
    into a 404 for an app called "discover"."""
    paths = [r.path for r in main.app.routes if getattr(r, "path", "").startswith("/api/apps")]
    assert paths.index("/api/apps/discover") < paths.index("/api/apps/{slug}/log")

    monkeypatch.setattr(main.discover, "discover_apps", lambda: [{"slug": "x", "name": "X"}])
    r = client.get("/api/apps/discover")
    assert r.status_code == 200 and r.json()[0]["slug"] == "x"


def test_adopt_rejects_a_malformed_body(monkeypatch):
    monkeypatch.setattr(main.discover, "discover_apps", lambda: [{"slug": "x"}])
    client.get("/api/apps/discover")  # populate the server-side candidate list
    for bad in ({}, {"slugs": "x"}, {"slugs": [1]}):
        r = client.post("/api/apps/adopt", json=bad)
        assert r.status_code == 400, f"{bad!r} should be refused"


def test_adopt_409s_before_any_scan_has_run():
    """Adoption reads the server-side scan, so without one there is nothing to adopt —
    and the browser cannot supply a directory or command to stand in for it."""
    main._discovered.clear()
    r = client.post("/api/apps/adopt", json={"slugs": ["x"]})
    assert r.status_code == 409 and "scan" in r.json()["detail"]


# --------------------------------------------------------------------------- #
# Ports
# --------------------------------------------------------------------------- #
LSOF_ONE = "p4711\ncnode\nf25\nn127.0.0.1:5173\n"


def test_ports_lists_listeners_and_hides_system_by_default(monkeypatch, one_app):
    monkeypatch.setattr(launchd, "_launchctl_state_live", lambda label: {"loaded": True})
    monkeypatch.setattr(ports, "_out", lambda cmd: LSOF_ONE if "-sTCP:LISTEN" in cmd else "")
    rows = client.get("/api/ports").json()
    live = [r for r in rows if r.get("kind") != "claimed"]
    assert [r["port"] for r in live] == [5173]


def test_ports_includes_a_claimed_row_for_a_declared_but_unbound_port(monkeypatch, one_app):
    """The app declares :3000 and nothing is serving it — the row must survive, or a
    project's port vanishes from the section the moment it stops."""
    monkeypatch.setattr(launchd, "_launchctl_state_live", lambda label: {"loaded": True})
    monkeypatch.setattr(ports, "_out", lambda cmd: "")
    rows = client.get("/api/ports").json()
    assert [r["port"] for r in rows if r.get("kind") == "claimed"] == [3000]


def test_kill_refuses_a_pid_that_holds_no_listening_port(monkeypatch):
    """The security control: the endpoint may only signal a process that is currently
    listening, re-checked live rather than trusted from the request."""
    killed = []
    monkeypatch.setattr(ports, "_out", lambda cmd: LSOF_ONE)
    monkeypatch.setattr(ports.os, "kill", lambda pid, sig: killed.append(pid))
    r = client.post("/api/ports/999/kill")
    assert r.json()["ok"] is False and "not holding a listening port" in r.json()["detail"]
    assert killed == [], "a non-listening pid must never be signalled"


def test_kill_signals_a_listening_pid(monkeypatch):
    killed = []
    monkeypatch.setattr(ports, "_out", lambda cmd: LSOF_ONE)
    monkeypatch.setattr(ports.os, "kill", lambda pid, sig: killed.append((pid, sig)))
    r = client.post("/api/ports/4711/kill")
    assert r.json()["ok"] is True
    assert killed == [(4711, ports.signal.SIGTERM)]


# --------------------------------------------------------------------------- #
# Watch
# --------------------------------------------------------------------------- #
def test_watch_reports_an_empty_state_without_failing():
    r = client.get("/api/watch")
    assert r.status_code == 200
    assert set(r.json()) >= {"active", "events", "errors", "last_run", "known", "agent_runs"}


def test_watch_history_reports_the_archive_size():
    r = client.get("/api/watch/history")
    assert r.status_code == 200 and isinstance(r.json()["archive_bytes"], int)


def test_ack_rejects_a_body_with_neither_key_nor_command():
    r = client.post("/api/watch/ack", json={"nope": 1})
    assert r.status_code == 400


def test_ack_refuses_a_key_that_is_not_an_active_alert():
    """The allow-lists may only ever be seeded from server-minted active alerts, so a
    browser cannot mute an alert it invents (or one that has not fired yet)."""
    netwatch.save_state({"seeded_at": "2026-01-01T00:00:00+00:00", "active": {}})
    r = client.post("/api/watch/ack", json={"key": "listen:evil:1"})
    assert r.status_code == 200 and r.json()["ok"] is False


def test_ack_accepts_an_active_alert_and_persists_it():
    netwatch.save_state({
        "seeded_at": "2026-01-01T00:00:00+00:00",
        "active": {"listen:node:5173": {"kind": "new_listener", "summary": "s", "severity": "warn"}},
    })
    r = client.post("/api/watch/ack", json={"key": "listen:node:5173"})
    assert r.json()["ok"] is True
    assert "listen:node:5173" in (netwatch.load_state().get("acked") or {})
