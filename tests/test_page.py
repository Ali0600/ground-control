"""Text-level guards on the dashboard page script.

The page is a hand-written string of HTML+JS with no JS test runner, so the few
constraints that are invisible at the point they matter get pinned here.
"""

import re

from app.main import PAGE

PANEL_CHILDREN = ("log", "logpath", "lognote", "follow")


def script() -> str:
    m = re.search(r"<script>(.*)</script>", PAGE, re.S)
    assert m, "the page must carry an inline <script>"
    return m.group(1)


def test_log_panel_is_reached_through_a_held_reference():
    """The panel is moved under the clicked row, so it lives inside a list whose
    innerHTML the 30s poll replaces — which DESTROYS it. A fresh getElementById
    then returns null and `row.after(null)` injects a literal "null" into the page
    (observed live). The node must be held in a variable, and its children reached
    through it."""
    js = script()
    capture = 'const logPanel = $("logwrap");'
    assert capture in js
    assert '$("logwrap")' not in js.split(capture, 1)[1], (
        "after capturing it, use `logPanel` — a fresh $(\"logwrap\") is null once a "
        "re-render has destroyed the parked node"
    )
    for child in PANEL_CHILDREN:
        assert f'$("{child}")' not in js, (
            f'reach #{child} via logPart("{child}") — $("{child}") is null while the '
            "panel is detached between innerHTML replacement and reattachLog()"
        )


def test_both_list_renderers_reattach_the_panel():
    """Each renderer that replaces a list's innerHTML must re-place the panel, or an
    open log silently disappears on the next poll."""
    js = script()
    for anchor in ('$("list").innerHTML = agents.map', '$("applist").innerHTML = apps.map'):
        assert anchor in js
        tail = js.split(anchor, 1)[1]
        # reattachLog() must appear before the next function declaration ends the renderer
        head = tail.split("\nasync function", 1)[0].split("\nfunction", 1)[0]
        assert "reattachLog()" in head, f"missing reattachLog() after `{anchor}`"


def test_claimed_port_rows_render_without_a_kill_button():
    """A claimed port has no process behind it — offering ✕ would be a lie. It gets a
    start affordance instead, and only when a single app claims it (else ambiguous)."""
    js = script()
    branch = js.split('if (p.kind === "claimed")', 1)
    assert len(branch) == 2, "the ports renderer must special-case claimed rows"
    claimed_block = branch[1].split("const where =", 1)[0]
    assert "data-kill" not in claimed_block and "killPort" not in claimed_block
    assert "claimed_by.length === 1" in claimed_block
    assert 'data-do="start"' in claimed_block, "the start affordance must survive"


def test_live_port_rows_open_by_name_not_by_ipv4_literal():
    """`localhost` resolves to ::1 OR 127.0.0.1, so it reaches the server whichever family
    it bound — a Vite/Next default bind is IPv6-only, where http://127.0.0.1:PORT is
    refused. It's also the host dev servers' Host-header allowlists expect."""
    js = script()
    ports_render = js.split('$("portlist").innerHTML', 1)[1].split("function ", 1)[0]
    # The port rides in a data-attribute now (a delegated listener builds the URL), so
    # the row must carry one and the listener must open localhost — never a literal.
    assert "data-open-port=" in ports_render
    # Anchored on an INTERPOLATION, not the bare address: the comment above this
    # renderer explains the rule and names 127.0.0.1, so a plain substring check
    # matches the prose and fails on correct code.
    assert "127.0.0.1:${" not in ports_render
    listener = js.split('$("portlist").onclick', 1)[1].split("$(\"showSystem\")", 1)[0]
    assert "http://localhost:${Number(openBtn.dataset.openPort)}" in listener
    # System listeners (AirPlay etc.) aren't web pages — no button for them.
    assert "p.system ? \"\"" in ports_render


def test_app_rows_open_by_name_too():
    js = script()
    apps_render = js.split('$("applist").innerHTML', 1)[1].split("function ", 1)[0]
    assert "data-open-port=" in apps_render
    listener = js.split('$("applist").onclick', 1)[1].split('$("portlist").onclick', 1)[0]
    assert "http://localhost:${Number(openBtn.dataset.openPort)}" in listener
    assert "window.open(`http://127.0.0.1:" not in js and "window.open('http://127.0.0.1:" not in js


def test_claimed_rows_have_no_open_button():
    """Nothing is serving a claimed port — Open would just fail; it gets a start button."""
    js = script()
    claimed = js.split('if (p.kind === "claimed")', 1)[1].split("const where =", 1)[0]
    assert "window.open" not in claimed


def test_port_checker_reports_free_but_declared():
    js = script()
    checker = js.split("function checkPort", 1)[1]
    assert 'p.kind !== "claimed"' in checker, "a claimed row must not read as taken"
    assert "free — declared by" in checker


def test_remove_arms_before_it_deletes():
    """Removal is destructive (stops the app, drops its config), so the first click must
    only arm the button — same two-tap contract as the port kill control."""
    js = script()
    fn = js.split("async function removeApp", 1)[1].split("\n}", 1)[0]
    assert "armedRemove !== slug" in fn, "first click must arm, not delete"
    arm_block = fn.split("armedRemove !== slug", 1)[1].split("return;", 1)[0]
    assert 'method: "DELETE"' not in arm_block, "the arming branch must not call the API"
    assert 'method: "DELETE"' in fn, "the confirmed branch must call DELETE"
    assert "loadPorts()" in fn, "a freed port must refresh the ports section"


def test_watch_section_is_polled_with_everything_else():
    js = script()
    assert 'id="watchlist"' in PAGE
    loadall = js.split("function loadAll", 1)[1].split("\n", 1)[0]
    assert "loadWatch()" in loadall


def test_watch_title_badge_sets_and_resets():
    js = script()
    assert "`(${n}!) Ground Control`" in js
    assert "document.title = n ?" in js  # ternary: resets when nothing is active


def test_watch_ack_rides_data_attributes_not_inline_js():
    """Alert keys and summaries embed process COMMAND NAMES — arbitrary text. An
    inline onclick with an interpolated key lets a quote in a process name break
    into JS; data-attributes + one delegated listener keep it inert, and every
    HTML interpolation in the renderer must pass through esc()."""
    js = script()
    watch = js.split("async function loadWatch", 1)[1].split('$("watchlist").onclick', 1)[0]
    assert 'data-ack="${esc(a.key)}"' in watch
    assert 'data-ackcmd="${esc(a.command)}"' in watch
    assert "esc(a.summary)" in watch
    assert "onclick" not in watch, "no inline handlers in the watch renderer"
    assert "button[data-ack],button[data-ackcmd]" in js  # the delegated listener


def test_watch_allow_app_only_for_listener_alerts():
    """'Always allow <command>' makes no sense on a connection alert (the command
    there is our own server); it's offered only for listen: keys."""
    js = script()
    watch = js.split("async function loadWatch", 1)[1]
    assert 'a.key.startsWith("listen:")' in watch


def test_history_is_a_mounted_tab_panel_not_a_sheet():
    """History has had three homes: an in-section toggle, a header-opened slide-over sheet,
    and now the fifth tab. It must be STATIC page HTML (present outside <script>) so a list
    re-render can never destroy it — the destroyed-log-panel lesson — and each retired
    surface must be gone entirely, because two ways to reach one thing is the bug the
    previous two moves were fixing."""
    body = PAGE.split("<script>", 1)[0]
    panel = body.split('id="panel-history"', 1)[1].split("</section>", 1)[0]
    assert 'role="tabpanel"' in panel.split('>', 1)[0], 'history must be a real tabpanel'
    for part in ("histmeta", "histevents", "histdevices", "histnotifs"):
        assert f'id="{part}"' in panel, f"#{part} must live inside the history panel"
    for gone in ("histsheet", "sheetback", "openHistory", "closeHistory", "histBtn"):
        assert gone not in PAGE, f"the sheet is retired — {gone} must not survive it"
    assert "showHistory" not in PAGE and "historywrap" not in PAGE and "loadNotifications" not in PAGE


def test_history_tab_fetches_on_demand_only():
    """The full ring is larger than the live summary, so /api/watch/history is fetched
    only by the history loader — and re-fetched by the 30s poll ONLY while that tab is
    showing, so a tab nobody is on costs zero extra requests."""
    js = script()
    assert js.count('api("/api/watch/history")') == 1, "history fetched from exactly one place"
    loader = js.split("async function loadHistory", 1)[1].split("function renderHistory", 1)[0]
    assert 'api("/api/watch/history")' in loader
    loadall = js.split("function loadAll", 1)[1].split("\n", 1)[0]
    assert "if (historyOpen) loadHistory()" in loadall  # poll re-fetch gated on open
    # the sent-banner body (process-named text) is esc()'d in the history renderer
    render = js.split("function renderHistory", 1)[1]
    assert "esc(nt.body)" in render
    # The banner TITLE is deliberately not rendered: every banner this app sends carries
    # the app's own name, so on screen it is a constant rather than information — and
    # after the rename it displayed the OLD name back at you. Still stored, just not
    # shown, so the assertion is on the INTERPOLATION, not on the identifier appearing
    # anywhere (a comment explaining the rule would otherwise trip it).
    assert "${esc(nt.title)}" not in render and "${nt.title}" not in render


def test_escape_closes_the_open_log_panel():
    """Escape used to close the history sheet. With history a tab, the log panel is the
    only transient surface left — so Escape moved rather than being dropped, because a key
    that silently stops doing anything is how a UI loses its keyboard affordances."""
    js = script()
    assert 'e.key === "Escape" && openLog' in js
    assert "closeHistory" not in js, "the sheet's closer must not linger"


def test_watch_renders_detail_and_failed_send_count():
    js = script()
    render = js.split("function renderWatch", 1)[1].split("async function loadHistory", 1)[0]
    assert "esc(a.detail)" in render
    assert "failed sends" in render  # notify_failures surfaced in the meta line
    ev = js.split("function evListHTML", 1)[1].split("function toggleEvent", 1)[0]
    assert "esc(e.detail)" in ev  # the recent-tail rows escape their detail too


def test_event_rows_expand_on_click_from_cache_not_a_refetch():
    """Clicking an event toggles an inline card, re-rendered from the LAST fetch (no
    network on click). The row TEMPLATE consults expandedEvents so an open card survives
    the 30s re-render — the parked-panel lesson one level up."""
    js = script()
    # the toggle handler must not fetch — it re-renders from cache
    toggle = js.split("function toggleEvent", 1)[1].split("\n}", 1)[0]
    assert "fetch(" not in toggle, "a click must never trigger a request"
    assert "rerender()" in toggle
    # the row template gates the card on expandedEvents (survives re-render)
    evlist = js.split("function evListHTML", 1)[1].split("function toggleEvent", 1)[0]
    assert "expandedEvents.has(id)" in evlist
    assert 'data-ev="${esc(id)}"' in evlist  # id rides a data-attribute, not inline JS
    # both containers wire the delegated toggle
    assert '$("watchlist").onclick' in js and '$("histevents").onclick' in js


def test_event_card_escapes_the_command_line_and_offers_agent_log():
    """The listener card shows the full command line — the most attacker-shaped string in
    the app — so it must be esc()'d; agent cards get a delegated View-log button."""
    js = script()
    card = js.split("function evCard", 1)[1].split("function evListHTML", 1)[0]
    assert "esc(d.args)" in card, "the command line must be escaped"
    assert "portData.find" in card, "listener card cross-checks the live port list"
    assert 'data-agentlog="${esc(d.label' in card  # log button rides a data-attribute
    # View log switches to the Agents tab first, then reuses the log panel that parks under
    # the agent's row — SYNCHRONOUSLY, since a hash write alone would leave the panel opening
    # inside a hidden panel until the hashchange task ran.
    fn = js.split("function openAgentLog", 1)[1].split("\n", 1)[0]
    assert 'goTab("agents")' in fn and "showLog(label)" in fn
    assert fn.index('goTab("agents")') < fn.index("showLog(label)"), "switch tab, then open"


def test_rows_carry_the_log_key_the_panel_is_placed_by():
    """placeLog() finds its row by data-log-key; both row templates must emit one,
    matching the keys openLogPanel is called with (label / app:<slug>)."""
    js = script()
    assert 'data-log-key="${esc(a.label)}"' in js
    assert 'data-log-key="app:${esc(a.slug)}"' in js
    assert '[data-log-key="${openLog}"]' in js


def test_devices_roster_is_built_from_conn_sightings():
    """The roster was implicit in event history and never browsable. It aggregates
    the persisted conn sightings by remote host — a static sheet section."""
    js = script()
    assert 'id="histdevices"' in PAGE
    fn = js.split("function devicesHTML", 1)[1].split("\nfunction ", 1)[0]
    assert 'key.startsWith("conn:")' in fn
    assert "esc(d.hostname || rhost)" in fn  # a device names ITSELF over DHCP/mDNS
    assert "esc(rhost)" in fn
    assert '$("histdevices").innerHTML = devicesHTML()' in js


def test_legacy_conn_keys_are_split_on_the_LAST_colon():
    """An IPv6 remote is full of colons, so `conn:<host>:<port>` must not be split
    naively — entries written before rhost/lport were stored fall back to this."""
    js = script()
    fn = js.split("function connParts", 1)[1].split("\nfunction ", 1)[0]
    assert "lastIndexOf" in fn
    assert ".split(" not in fn


def test_sighting_stats_and_run_ledger_ride_both_watch_fetches():
    """Either fetch may be the last to land, so both must refresh the caches —
    otherwise an open sheet shows stats that silently stop updating."""
    js = script()
    for loader in ("async function loadWatch", "async function loadHistory"):
        body = js.split(loader, 1)[1].split("\n}", 1)[0]
        assert "knownStats =" in body, f"{loader} must refresh knownStats"
        assert "agentRuns =" in body, f"{loader} must refresh agentRuns"


def test_event_cards_show_sightings_and_runs_escaped():
    js = script()
    card = js.split("function evCard", 1)[1].split("\nfunction ", 1)[0]
    assert 'sightingLines(e.key, "times listening")' in card
    assert 'sightingLines(e.key, "connections")' in card
    assert "agentRuns[d.label]" in card
    assert "esc(r.exit ==" in card, "a parsed exit value is still text going into HTML"
    assert "esc(new Date(r.ts).toLocaleString())" in card


def test_missing_stats_degrade_quietly():
    """Old events (pre-stats) and pruned keys have no entry — the card must omit the
    lines, never render 'undefined'."""
    js = script()
    fn = js.split("function sightingLines", 1)[1].split("\nfunction ", 1)[0]
    assert "if (!s || !s.first_seen) return \"\";" in fn


def test_archive_size_is_surfaced():
    js = script()
    assert "h.archive_bytes" in js


# --------------------------------------------------------------------------- #
# Demo mode — masking private data for a public screen recording
# --------------------------------------------------------------------------- #
def test_api_is_the_only_place_a_response_becomes_data():
    """Demo mode masks inside api(), so every renderer and toast is downstream of it.
    A new call site that reads .json() itself would bypass the mask and leak — the
    same one-choke-point rule as the shared port scan."""
    js = script()
    assert js.count("await fetch(") == 1, "fetch belongs to api() alone"
    assert js.count(".json()") == 1, "api() is the only response reader"
    fn = js.split("async function api(", 1)[1].split("\n}", 1)[0]
    assert "await fetch(url, opts)" in fn
    assert "return demoMode ? scrub(j) : j;" in fn


def test_demo_toggle_exists_and_rerenders_everything():
    js = script()
    assert 'id="demoToggle"' in PAGE
    assert "demoMode" not in PAGE.split("<script>", 1)[0], "state is JS, not markup"
    handler = js.split('$("demoToggle").onchange', 1)[1].split("};", 1)[0]
    assert "loadAll()" in handler          # covers the list, ports, watch AND open sheet
    assert "if (openLog) refreshLog()" in handler  # an open log panel too
    # Never persisted: forgetting demo mode is on would read as a broken dashboard.
    # Stated as a flat prohibition — the old form ("demoMode" absent before the first
    # localStorage occurrence, OR no localStorage at all) was satisfied by its second
    # clause and could not fail while the page had no storage calls at all.
    assert "localStorage" not in js and "sessionStorage" not in js


def _scrub_js() -> str:
    """The self-contained scrub block, lifted out of PAGE so it can be RUN."""
    js = script()
    # drop the rest of the marker line — it carries a prose comment, not code
    block = js.split("// __SCRUB__", 1)[1].split("\n", 1)[1].split("// __/SCRUB__", 1)[0]
    assert "function scrub(" in block
    return block


def test_scrub_actually_masks_what_it_claims():
    """Text assertions can't tell a working masker from a decorative one, and this is
    a privacy gate — so the block is extracted and EXECUTED under node."""
    import json as _json
    import shutil
    import subprocess

    node = shutil.which("node")
    # A skip here would silently disarm a privacy gate; fail loudly instead.
    assert node, "node is required to verify demo-mode masking"

    payload = {
        "rhost": "10.0.1.37",
        "hostname": "lab-phone.local",
        "summary": "device lab-phone.local (10.0.1.37) connected to :8081",
        "addresses": ["127.0.0.1", "fe80::abc%en0", "*"],
        "args": "/Users/dev/projects/app/.venv/bin/python app.py --port 8000",
        "ts": "2026-08-07T13:10:15+00:00",
        "label": "com.groceryhelper.recipes",
        "port": 8081,
        "again": "10.0.1.37",
        "other": "10.0.1.99",
    }
    prog = _scrub_js() + f"""
const out = scrub({_json.dumps(payload)});
console.log(JSON.stringify(out));
"""
    res = subprocess.run([node, "-e", prog], capture_output=True, text=True, timeout=30)
    assert res.returncode == 0, res.stderr
    out = _json.loads(res.stdout)

    assert out["rhost"] == "192.0.2.1"                    # RFC 5737 documentation range
    # BOTH halves of the mapping are needed: "same real → same fake" alone passes even
    # when the map is broken and every address collapses onto 192.0.2.1 (proven by
    # sabotage), so distinct reals must also stay distinct.
    assert out["again"] == "192.0.2.1", "same IP must map to the SAME fake all recording"
    assert out["other"] != out["rhost"], "different devices must not collapse into one"
    assert out["other"].startswith("192.0.2.")
    assert out["hostname"].startswith("device-") and out["hostname"].endswith(".local")
    assert "10.0.1.37" not in out["summary"] and "lab-phone" not in out["summary"]
    assert "192.0.2.1" in out["summary"]
    assert out["addresses"][0] == "127.0.0.1", "loopback stays real (else every row reads exposed)"
    assert out["addresses"][1].startswith("2001:db8::")   # RFC 3849
    assert out["addresses"][2] == "*"
    assert out["args"] == "/Users/demo/projects/app/.venv/bin/python app.py --port 8000"
    assert out["ts"] == "2026-08-07T13:10:15+00:00", "a clock time is not an IPv6 address"
    assert out["label"] == "com.groceryhelper.recipes", "labels are the portfolio — kept"
    assert out["port"] == 8081


def test_object_keys_are_masked_and_still_join_to_the_masked_values():
    """The sighting roster is an OBJECT KEYED BY ADDRESS (`conn:<ip>:<port>`), and keys used
    to be copied verbatim while values were masked. Two consequences, and the second is why
    asserting "no real address survives" is not enough on its own:

      1. the devices roster rendered the real LAN address — in demo mode, on the one screen
         the demo GIF exists to show;
      2. the roster key and the matching event's `key` VALUE no longer agreed, so the
         first/last-seen lookup missed and every conn card lost its sighting lines.

    Masking both sides fixes both, because the fake map is stable within a session — so this
    test pins the JOIN, not just the absence."""
    import json as _json
    import shutil
    import subprocess

    node = shutil.which("node")
    assert node, "node is required to verify demo-mode masking"
    payload = {
        "known": {"conn:10.0.1.9:8081": {"first_seen": "2026-08-07T13:10:15+00:00", "sessions": 3}},
        "events": [{"key": "conn:10.0.1.9:8081", "summary": "device 10.0.1.9 connected"}],
    }
    prog = _scrub_js() + f"console.log(JSON.stringify(scrub({_json.dumps(payload)})));"
    res = subprocess.run([node, "-e", prog], capture_output=True, text=True, timeout=30)
    assert res.returncode == 0, res.stderr
    out = _json.loads(res.stdout)

    key = list(out["known"])[0]
    assert "10.0.1.9" not in key, f"the roster key still carries a real address: {key}"
    assert "192.0.2." in key, f"the key must be masked, not dropped: {key}"
    assert out["events"][0]["key"] == key, (
        "the masked key and the masked value must still be the same string, or "
        "sightingLines() silently finds nothing for every conn card in a recording"
    )
    assert out["known"][key]["sessions"] == 3, "the roster entry itself must survive"
    assert out["known"][key]["first_seen"] == "2026-08-07T13:10:15+00:00"


def test_one_device_masks_to_one_fake_across_summary_and_detail():
    """The bug this test exists for shipped in a published GIF: the detail line used
    to render `2607:6bc0::10:443`, which the masker sees as ONE longer address — a
    different string from the bare host in the summary — so the same device appeared
    as two different fakes in the same row. Bracketing keeps them one."""
    import json as _json
    import shutil
    import subprocess

    node = shutil.which("node")
    assert node, "node is required to verify demo-mode masking"
    payload = {
        "summary": "PUBLIC address 2607:6bc0::10 connected to :63900 (codex)",
        "detail": "[2607:6bc0::10]:443 → :63900 · pid 48553",
    }
    prog = _scrub_js() + f"console.log(JSON.stringify(scrub({_json.dumps(payload)})));"
    res = subprocess.run([node, "-e", prog], capture_output=True, text=True, timeout=30)
    assert res.returncode == 0, res.stderr
    out = _json.loads(res.stdout)

    fakes = set(re.findall(r"2001:db8::\d+", out["summary"] + " " + out["detail"]))
    assert len(fakes) == 1, f"one device must read as one address, got {fakes}"
    assert "2607:6bc0" not in out["detail"]
    assert ":443" in out["detail"], "the port must survive as a port, not be absorbed"


def test_the_page_script_carries_no_control_characters():
    """The JS lives inside a PYTHON string, so `\\b` in a regex is Python's BACKSPACE,
    not a word boundary — a regex that silently matches nothing. Backslashes must be
    doubled. This caught the demo-mode IP regexes being dead on arrival; the check is
    generic so the next regex added here can't repeat it."""
    js = script()
    bad = {c for c in js if ord(c) < 9 or 11 <= ord(c) <= 12 or 14 <= ord(c) <= 31}
    assert not bad, (
        f"control characters in the page script: {sorted(hex(ord(c)) for c in bad)} — "
        "a single-backslash escape leaked through Python's string parsing"
    )


def test_demo_can_be_armed_by_url_before_the_first_fetch():
    """`?demo=1` must set demoMode BEFORE loadAll(), or the first render — the first
    frame a recorder captures — shows real IPs. Clicking the toggle always leaves that
    window open, which is precisely what this feature exists to prevent."""
    js = script()
    boot = js.split('$("portcheck").oninput = checkPort;', 1)[1]
    arm, _, rest = boot.partition("loadAll();")
    assert "demoMode = true" in arm, "arm demo mode before the first loadAll()"
    assert "location.search" in arm and "location.hash" in arm
    assert '$("demoToggle").checked = true' in arm, "the checkbox must reflect it"
    assert 'classList.add("demo")' in arm, "and so must the visible pill"


def test_the_product_name_is_consistent_across_every_surface():
    """The name shows up in four places that a rename can easily half-finish: the tab
    title, the header, the title badge, and every macOS banner. The banner titles must
    come from APP_NAME rather than a repeated literal — a half-rename leaves your
    notifications filed under the old name, which is invisible until one fires."""
    import inspect

    from app import main

    assert main.APP_NAME == "Ground Control"
    assert f"<title>{main.APP_NAME}</title>" in PAGE
    assert f"⌁</span> {main.APP_NAME} " in PAGE
    js = script()
    assert f"`(${{n}}!) {main.APP_NAME}`" in js and f'"{main.APP_NAME}"' in js

    src = inspect.getsource(main)
    assert "post_notification(APP_NAME" in src, "banners must use the constant"
    assert "launchd dashboard" not in src, "stale product name left in main.py"


def test_the_whole_page_script_parses():
    """Only the ~50-line scrub block is ever handed to a JS engine (by the two tests
    above). The other ~750 lines are checked as TEXT, so a stray brace anywhere in them
    ships a completely blank dashboard with a green suite — the page is one string in a
    Python file, invisible to ruff and to any JS tooling.

    `node --check` parses without executing, so `document`/`location` are irrelevant."""
    import shutil
    import subprocess

    node = shutil.which("node")
    assert node, "node is required to parse-check the page script"
    r = subprocess.run([node, "--check"], input=script(), capture_output=True, text=True)
    assert r.returncode == 0, f"the page script does not parse:\n{r.stderr}"


# --------------------------------------------------------------------------- #
# Escaping — the four renderers that predate esc()
# --------------------------------------------------------------------------- #
# Anchored on the `.map(` that builds the ROW, not on the innerHTML assignment: every
# renderer assigns innerHTML twice — once for its empty state, once for the rows — and
# splitting on the first occurrence captured the empty-state line and stopped. The ports
# slice was 53 characters, so the escaping guard below passed while inspecting nothing.
# The sabotage harness caught that; reading the test did not.
RENDERERS = {
    # name: (start marker, end marker, a string that MUST appear in the slice)
    "agents": ("agents.map(a => {", '}).join("")', "data-agent="),
    "apps": ("apps.map(a => {", '}).join("")', "data-app="),
    "discover": ("cands.map(c => {", '}).join("")', "data-adopt="),
    "ports": ("shown.map(p => {", '}).join("")', "data-kill="),
}


def renderer(name: str) -> str:
    start, end, marker = RENDERERS[name]
    js = script()
    assert js.count(start) == 1, f"{name}: {js.count(start)} matches for {start!r}"
    body = js.split(start, 1)[1].split(end, 1)[0]
    # A slice that captured the wrong region is the failure mode these guards had, and
    # it presents as a PASS. Refuse to assert over a body that cannot be the renderer.
    assert marker in body, f"{name}: slice missing {marker!r} — wrong region captured"
    assert len(body) > 400, f"{name}: slice is only {len(body)} chars — wrong region"
    return body


def test_every_renderer_escapes_the_strings_it_interpolates():
    """Everything these four render comes from the machine: plist Labels, apps.json,
    `lsof` process names, a scanned repo's package.json `name`, directory names. They
    were written before esc() existed and escaped nothing, while every renderer defined
    BELOW esc() escaped everything — a split by position, not by principle.

    A dev server run from a directory called `<img src=x onerror=…>` was enough; the
    script then runs on the dashboard's own origin and can drive every route.

    The rule: no `${...}` in these renderers may reach HTML unescaped. Numeric-only
    interpolations are allowed through `Number(...)`, and a few named locals are
    pre-escaped or built from literals — those are listed, so a NEW bare interpolation
    fails rather than joining an ever-growing allowlist."""
    import re

    # Locals that are already escaped or are literal HTML built above the template.
    SAFE = {
        "dot", "pill", "exit", "next", "note", "hover", "port", "portTag", "login",
        "open", "action", "sub", "drift", "sharedNote", "state", "inert", "agent",
        "exposed", "sys", "openBtn", "start", "who", "shownPort", "where",
    }
    offenders = []
    for name in RENDERERS:
        body = renderer(name)
        for expr in re.findall(r"\$\{([^{}]*)\}", body):
            e = expr.strip()
            if e.startswith(("esc(", "Number(", "rel(")) or e in SAFE:
                continue
            # A ternary whose BOTH branches are string literals is safe whatever it
            # contains — nothing from the API reaches the output. Each branch matches
            # its own quote style, since a single-quoted branch legitimately holds the
            # double quotes of an HTML attribute.
            literal = r"""(?:'[^']*'|"[^"]*")"""
            if re.fullmatch(rf"[^?]*\?\s*{literal}\s*:\s*{literal}", e):
                continue
            if e.startswith(("a.pid", "p.pid", "p.port", "a.last_exit", "a.open_port")):
                continue  # numbers from the API, never strings
            offenders.append(f"{name}: ${{{e}}}")
    assert not offenders, (
        "unescaped interpolations in a renderer:\n  " + "\n  ".join(offenders)
    )


def test_no_renderer_puts_a_value_inside_an_inline_handler():
    """esc() does NOT make a value safe inside `onclick="act('${x}')"` — the browser
    decodes &#39; back to a quote before the JS parser runs, so the string still breaks
    out. Action values must ride in data-attributes read by a delegated listener, which
    is what the watch renderer has always done."""
    import re

    for name in RENDERERS:
        body = renderer(name)
        inline = re.findall(r'on\w+="[^"]*\$\{', body)
        assert not inline, f"{name}: value interpolated into an inline handler: {inline}"


def test_the_delegated_listeners_are_bound_to_static_containers():
    """The handlers must sit on the containers whose innerHTML is replaced, not on the
    rows — a per-row binding would be lost on every 30s poll, and re-binding inside a
    render function accumulates handlers."""
    js = script()
    for container in ("list", "applist", "portlist"):
        assert f'$("{container}").onclick' in js, f"no delegated handler for #{container}"


# --------------------------------------------------------------------------- #
# Tabs
#
# The page was one long column: reaching the network watch meant a screen and a half of
# scrolling. It is now five tabs. The rules below are the ones that are invisible at the
# point they matter — a tab whose panel is missing, a switch that fetches before demo mode
# is armed, a panel whose `hidden` attribute is overruled by a display: rule.
# --------------------------------------------------------------------------- #
TAB_NAMES = ["agents", "apps", "ports", "watch", "history"]

# What each panel must OWN, now that the controls left the shared header.
PANEL_CONTENTS = {
    "agents": ("showVendor", "cards", "list", "logwrap"),
    "apps": ("scanBtn", "applist", "discover"),
    "ports": ("portverdict", "portcheck", "showSystem", "portlist"),
    "watch": ("watchmeta", "watchlist"),
    "history": ("histmeta", "histevents", "histdevices", "histnotifs"),
}


def body() -> str:
    return PAGE.split("<script>", 1)[0]


def panel(name: str) -> str:
    return body().split(f'id="panel-{name}"', 1)[1].split("</section>", 1)[0]


def test_every_tab_has_a_panel_and_every_panel_a_tab():
    """Compared WHOLE, in both directions and in order. A per-tab check ("each tab's panel
    exists") passes happily when a panel is added with no tab, or a tab is deleted — the
    membership is the rule, so the membership is what gets asserted."""
    js = script()
    tabs = re.findall(r'data-tab="(\w+)"', body())
    panels = re.findall(r'id="panel-(\w+)"', body())
    assert tabs == TAB_NAMES, f"tab buttons are {tabs}"
    assert panels == TAB_NAMES, f"panels are {panels}"
    assert 'const TABS = ["agents", "apps", "ports", "watch", "history"];' in js, (
        "the script's list must agree with the markup — it is what selectTab iterates"
    )
    # Agents is the landing tab: it must be the one pre-selected in the STATIC markup, or
    # the first frame shows a different tab than the one the script is about to select.
    assert 'id="tab-agents" data-tab="agents" aria-controls="panel-agents" aria-selected="true"' in body()


def test_hidden_panels_cannot_be_overridden_by_a_display_rule():
    """`[hidden]` is a UA rule with the lowest possible weight, and .row/.cards both set
    display — so without this guard a tab switch sets the attribute and nothing moves. The
    same trap cost a modal in another project two speculative fixes."""
    assert re.search(r"\[hidden\]\s*\{\s*display:\s*none\s*!important", PAGE), (
        "add [hidden] { display: none !important } — the attribute alone loses to any "
        "display: declaration on the element"
    )


def test_selecting_a_tab_is_visibility_only():
    """selectTab runs at BOOT, before the demo-mode arming block. If it could fetch, then
    /?demo=1#history would put an unmasked history request on the very first frame a
    screen recorder captures — the exact thing demo mode exists to prevent."""
    js = script()
    fn = js.split("function selectTab", 1)[1].split("\n}", 1)[0]
    for forbidden in ("innerHTML", "api(", "fetch(", "loadHistory("):
        assert forbidden not in fn, f"selectTab must not {forbidden} — it is visibility only"
    assert ".hidden =" in fn and "historyOpen =" in fn


def test_tab_state_lives_in_the_hash_only():
    """Storage is banned outright in this script (see the demo-mode test), so the hash is
    the only place a tab can persist — and it makes /#ports a shareable link."""
    js = script()
    assert "function fromHash" in js
    assert js.count('addEventListener("hashchange"') == 1, "one listener, or a switch loops"
    assert "history.replaceState(" in js, (
        "replaceState, not location.hash: a tab is a view, so Back should leave the page "
        "rather than walk back through five tabs"
    )


def test_boot_arms_demo_then_picks_the_tab_then_fetches():
    """Order is the whole rule. The tab must be applied before the first fetch (so the
    right panel is showing when data lands) but AFTER masking is armed, and through
    selectTab — goTab fetches."""
    js = script()
    boot = js.split('$("portcheck").oninput = checkPort;', 1)[1]
    arm, _, rest = boot.partition("loadAll();")
    assert "selectTab(fromHash())" in arm, "pick the tab before the first fetch"
    assert arm.index('classList.add("demo")') < arm.index("selectTab(fromHash())"), (
        "arm demo mode FIRST — selecting #history before that would fetch unmasked"
    )
    assert "goTab(" not in arm, "boot must use selectTab: goTab fetches history"
    assert "loadHistory(" not in arm
    assert "selectTab(" not in rest


def test_switching_to_history_fetches_it_immediately():
    """History is the one panel the poll skips while hidden, so arriving on it has to
    fetch — otherwise the tab reads "Loading…" for up to 30 seconds."""
    js = script()
    fn = js.split("function goTab", 1)[1].split("\n}", 1)[0]
    assert "selectTab(name)" in fn and "loadHistory()" in fn
    assert fn.index("selectTab(name)") < fn.index("loadHistory()")
    click = js.split('$("tabs").onclick', 1)[1].split("\n", 1)[0]
    assert "goTab(" in click and "data-tab" in click


def test_each_tabs_controls_live_in_its_own_panel():
    """The old header carried every control for every section; that is what ran it out of
    room. A control left behind in the header is a control that acts on a panel you cannot
    see while you are pressing it."""
    for name, ids in PANEL_CONTENTS.items():
        markup = panel(name)
        for el in ids:
            assert f'id="{el}"' in markup, f'#{el} must live inside the {name} panel'
    shell = body().split("<section", 1)[0]
    for global_ctl in ("demoToggle", "refresh", "tabs"):
        assert f'id="{global_ctl}"' in shell, f"#{global_ctl} is global — it stays in the top bar"


def test_the_tablist_follows_the_aria_tabs_pattern():
    """A tab bar that is only styled like one is a row of buttons to a screen reader, and
    arrow keys are how the pattern is actually driven."""
    markup = body()
    assert 'role="tablist"' in markup
    for name in TAB_NAMES:
        assert f'role="tab" id="tab-{name}" data-tab="{name}" aria-controls="panel-{name}"' in markup
        assert f'role="tabpanel" aria-labelledby="tab-{name}"' in markup
    js = script()
    keys = js.split('$("tabs").onkeydown', 1)[1].split("\n};", 1)[0]
    for key in ("ArrowLeft", "ArrowRight", "Home", "End"):
        assert key in keys, f"{key} must move between tabs"
    sel = js.split("function selectTab", 1)[1].split("\n}", 1)[0]
    assert "aria-selected" in sel and "tabIndex" in sel, (
        "selection must be announced, and only the selected tab is a tab stop"
    )


def test_tab_counts_are_written_as_text_by_the_renderers():
    """The counts are what make a hidden panel legible — 3 failed agents, 2 exposed ports.
    They come from machine-derived data, so they go in as text: setCount is the one writer
    and it must never reach for innerHTML."""
    js = script()
    fn = js.split("function setCount", 1)[1].split("\n}", 1)[0]
    assert "textContent" in fn and "innerHTML" not in fn
    for name in TAB_NAMES:
        assert f'id="count-{name}"' in body()
    writers = {
        "agents": "async function load(",
        "apps": "async function loadApps(",
        "ports": "async function loadPorts(",
        "watch": "function renderWatch(",
        "history": "function renderHistory(",
    }
    for name, start in writers.items():
        renderer = js.split(start, 1)[1].split("\n}", 1)[0]
        assert f'setCount("{name}"' in renderer, f"{start} must publish the {name} count"


def test_the_markup_carries_no_inline_event_handlers():
    """Every action now rides a data-attribute read by a delegated listener on a static
    container. The renderers were already held to that; the four hand-written handlers in
    the static markup were the exception, and an exception is how the rule erodes."""
    assert not re.search(r'\son\w+="', body()), "bind it in the script instead"


def test_watch_event_rows_name_their_severity_in_text():
    """Severity used to be carried by the colour of an 8px dot and nothing else — unreadable
    to a screen reader, and the two reds are exactly the pair that colour blindness merges."""
    js = script()
    rows = js.split("function evListHTML", 1)[1].split("function toggleEvent", 1)[0]
    assert '<span class="pill ${dot}">${sev}</span>' in rows
    for word in ('"alert"', '"notice"', '"log"'):
        assert word in rows


def test_loading_apps_disarms_a_pending_remove():
    """✕ arms for 3s before it deletes. The 30s poll re-renders inside that window, so the
    button goes back to reading "✕" while the next click still deletes — a destructive
    action whose confirmation is invisible. loadPorts already reset its twin."""
    js = script()
    fn = js.split("async function loadApps", 1)[1].split("\n}", 1)[0]
    assert "armedRemove = null" in fn


def _tabs_js() -> str:
    """The self-contained tab block, lifted out of PAGE so it can be RUN."""
    js = script()
    block = js.split("// __TABS__", 1)[1].split("\n", 1)[1].split("// __/TABS__", 1)[0]
    assert "function selectTab(" in block
    return block


def test_tab_switching_actually_toggles_the_right_panel():
    """Text assertions can see that selectTab mentions `.hidden`; they cannot see whether it
    hides the right things. So the block is EXECUTED against a stub DOM and the OUTCOME is
    asserted — which panel is showing, which tab is the tab stop, and that an unknown hash
    lands somewhere real instead of a blank page."""
    import json as _json
    import shutil
    import subprocess

    node = shutil.which("node")
    assert node, "node is required to verify tab switching"

    driver = """
const nodes = {};
const node = (id) => nodes[id] || (nodes[id] = { id, hidden: false, tabIndex: null, attrs: {},
  setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k]; } });
const document = { getElementById: node };
const location = { hash: "#ports" };
const $ = (id) => document.getElementById(id);
%s
const snap = () => Object.fromEntries(TABS.map((t) => [t, {
  hidden: $("panel-" + t).hidden,
  sel: $("tab-" + t).getAttribute("aria-selected"),
  ti: $("tab-" + t).tabIndex,
}]));
const out = {};
selectTab(fromHash()); out.ports = snap(); out.openOnPorts = historyOpen; out.current = currentTab;
location.hash = "#history"; selectTab(fromHash()); out.history = snap(); out.openOnHistory = historyOpen;
out.junk = (location.hash = "#nope", fromHash());
out.demo = (location.hash = "#demo", fromHash());
out.empty = (location.hash = "", fromHash());
console.log(JSON.stringify(out));
""" % _tabs_js()

    run = subprocess.run([node, "-e", driver], capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    out = _json.loads(run.stdout)

    for showing, state in (("ports", out["ports"]), ("history", out["history"])):
        for name, seen in state.items():
            on = name == showing
            assert seen["hidden"] is not on, f"{name} visibility wrong while on {showing}"
            assert seen["sel"] == ("true" if on else "false"), f"{name} aria-selected on {showing}"
            assert seen["ti"] == (0 if on else -1), f"{name} tabindex on {showing}"
    assert out["current"] == "ports"
    # historyOpen is what gates the 30s history re-fetch: wrong here and the tab either
    # goes stale or every other tab pays for a fetch it never shows.
    assert out["openOnPorts"] is False and out["openOnHistory"] is True
    # An unknown hash must land on a real tab. Without the membership check the page would
    # show five hidden panels and read as broken. "#demo" is demo mode's arming alias, not
    # a tab, and must fall through the same way.
    assert out["junk"] == "agents" and out["demo"] == "agents" and out["empty"] == "agents"
