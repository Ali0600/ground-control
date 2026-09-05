"""Cross-origin write protection and DNS-rebinding refusal.

Loopback is not a boundary against a web page: the browser is on loopback too. Nine
mutating routes took no request body, which makes a cross-origin `<form method=POST>`
a CORS *simple request* — delivered and executed, with only the response withheld. A
page the user visited could loop pids against /api/ports/{pid}/kill, or disable a
backup agent by guessing its label.

Every test drives the real middleware stack through TestClient rather than calling the
class directly: the thing under test is what the server does to a request, and an
inner-seam call would skip the ordering that decides which guard fires first.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import main

client = TestClient(main.app, base_url="http://127.0.0.1:8787")

# Derived from the app's own route table, so a route added later inherits these tests
# instead of quietly shipping unprotected. That is the whole point: a hand-kept list
# forgets its newest member, which is exactly the member most likely to be unguarded.
MUTATING = sorted(
    {
        (method, route.path)
        for route in main.app.routes
        for method in (getattr(route, "methods", None) or set())
        if method not in {"GET", "HEAD", "OPTIONS"}
    }
)

# A concrete argument for each templated segment. Values are deliberately nonsense —
# these tests assert the request is REFUSED before any handler runs, so a 403 must
# arrive whether or not the target exists.
PARAMS = {"{label}": "com.example.job", "{slug}": "demo", "{pid}": "4711"}


def concrete(path: str) -> str:
    for token, value in PARAMS.items():
        path = path.replace(token, value)
    return path


def test_the_route_table_actually_yielded_mutating_routes():
    """A parametrised test over an empty list passes while asserting nothing. Pin the
    count so a refactor that empties this derivation fails loudly."""
    assert len(MUTATING) >= 9, f"expected the mutating routes, found {MUTATING}"


@pytest.mark.parametrize("method,path", MUTATING)
def test_a_cross_site_write_is_refused(method, path):
    """`Sec-Fetch-Site: cross-site` is what a real browser sends for a form posted from
    another origin. It is set by the browser and cannot be forged by page script."""
    r = client.request(method, concrete(path), headers={"sec-fetch-site": "cross-site"})
    assert r.status_code == 403, f"{method} {path} accepted a cross-site write"
    assert r.json()["ok"] is False


@pytest.mark.parametrize("method,path", MUTATING)
def test_a_foreign_origin_is_refused_without_fetch_metadata(method, path):
    """Older browsers send no Sec-Fetch-* headers; the Origin fallback must still
    refuse a foreign one."""
    r = client.request(method, concrete(path), headers={"origin": "http://evil.example"})
    assert r.status_code == 403, f"{method} {path} accepted a foreign Origin"


@pytest.mark.parametrize("method,path", MUTATING)
def test_the_dashboards_own_requests_are_allowed(method, path):
    """The guard must not break the page it protects: same-origin fetches carry
    `Sec-Fetch-Site: same-origin`, and anything is allowed through except a 403 from
    this middleware (a 404/409/422 from the handler is the route doing its job)."""
    r = client.request(method, concrete(path), headers={"sec-fetch-site": "same-origin"})
    assert r.status_code != 403, f"{method} {path} refused the dashboard's own request"


@pytest.mark.parametrize("method,path", MUTATING)
def test_a_non_browser_caller_is_allowed(method, path):
    """curl, the demo recorder's `page.request.post`, and the CLAUDE.md playbook send
    neither header. Refusing them would break documented workflows and buy nothing —
    a local process can talk to the socket regardless of what this middleware says."""
    r = client.request(method, concrete(path))
    assert r.status_code != 403, f"{method} {path} refused a non-browser caller"


def test_reads_are_not_blocked_cross_origin():
    """Only writes are gated here. A cross-origin READ is already unreadable to the
    calling page (no CORS headers are sent), and blocking it would break nothing an
    attacker cares about while risking the page's own navigations."""
    r = client.get("/health", headers={"sec-fetch-site": "cross-site"})
    assert r.status_code == 200


def test_top_level_navigation_to_the_page_still_works():
    """A user typing the URL or following a bookmark sends `Sec-Fetch-Site: none`."""
    r = client.get("/", headers={"sec-fetch-site": "none"})
    assert r.status_code == 200


# --------------------------------------------------------------------------- #
# DNS rebinding
# --------------------------------------------------------------------------- #
def test_a_foreign_host_header_is_refused():
    """The write guard does not cover reads, so a rebinding attack — an attacker-owned
    name re-resolved to 127.0.0.1 — would let a foreign page READ every response.
    TrustedHost closes that, and it is the reason reads can stay open above."""
    r = client.get("/health", headers={"host": "evil.example"})
    assert r.status_code == 400


@pytest.mark.parametrize("host", ["127.0.0.1:8787", "localhost:8787", "127.0.0.1", "localhost:9999"])
def test_the_real_hosts_are_accepted_on_any_port(host):
    """Starlette strips the port before matching, so the allowlist covers whatever port
    run.sh was given — asserted rather than assumed, since a port-sensitive match would
    break the dashboard the first time someone ran it on a different one."""
    r = client.get("/health", headers={"host": host})
    assert r.status_code == 200, f"Host: {host} was refused"


# --------------------------------------------------------------------------- #
# Input bounds and label scoping
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("lines", [0, -5, 100000])
def test_the_log_routes_refuse_an_out_of_range_line_count(lines, tmp_path, monkeypatch):
    """`lines` reads like a limit but was unbounded: `data[0:]` for 0 and nearly the
    whole file for a negative, on a log that is already 5.5 MB here."""
    r = client.get(f"/api/agents/com.example.job/log?lines={lines}")
    assert r.status_code == 422, f"lines={lines} was accepted"
    r = client.get(f"/api/apps/demo/log?lines={lines}")
    assert r.status_code == 422, f"lines={lines} was accepted on the app route"


@pytest.mark.parametrize("action", ["run", "stop", "enable", "disable"])
def test_the_agent_routes_refuse_a_dashboard_managed_app_label(action):
    """These labels are the most guessable on the machine — we mint them. Reaching an
    app through the agent routes would also skip the plist cleanup its own stop does,
    leaving the Apps section describing a job that is gone."""
    r = client.post(f"/api/agents/com.launchddash.app.demo/{action}")
    assert r.status_code == 404
    assert "/api/apps/" in r.json()["detail"], "the refusal should point at the right route"


def test_the_agent_log_route_refuses_one_too():
    r = client.get("/api/agents/com.launchddash.app.demo/log")
    assert r.status_code == 404
