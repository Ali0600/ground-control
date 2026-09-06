# Ground Control — agent notes

Local FastAPI + zero-dependency web UI (127.0.0.1:8787): a control tower for the machine —
inventories and controls launchd jobs, launches dev apps as managed agents, attributes
every listening port to its project, and watches the network for change (new listeners,
LAN exposure, connecting devices, failed jobs). See [README.md](README.md) for the
user-facing picture.

**Naming (renamed from "launchd dashboard" 2026-08-11).** The product and the GitHub repo
are **Ground Control**; `APP_NAME` in `app/main.py` is the single source for the UI title,
the FastAPI title and every banner title. Three things deliberately KEEP the old name and
must not be "tidied": the agent labels (`com.launchddash.*` — a label is an identity that
installed plists and running jobs refer to), this machine's checkout path
(`~/launchd-dashboard`, which the installed server plist points at absolutely), and the
historical entries in `docs/DECISIONS.md` / `docs/learnings.md`, which are records.

## Layout
- `app/launchd.py` — agent discovery, `launchctl` parsing, schedule humanize/next-run, control.
- `app/ports.py` — `lsof`/`ps` parsing, project + agent attribution.
- `app/apps.py` — the app launcher: `apps.json` parsing, plist generation, start/stop/restart/remove.
- `app/discover.py` — "Scan for projects": root scanning, launch inference, adoption.
- `app/annotations.py` — `labels.json` (purpose/repo/note per job).
- `app/netwatch.py` — network watch: connection parsing, remote classification, the
  observe() diff rules, ack allow-lists, osascript notifier, `netwatch.json` state.
- `app/main.py` — routes **plus the entire UI** as one `PAGE` string (HTML + inline JS),
  and the background watcher loop (lifespan task).
- `tests/` — pytest, fixtures only; no live `launchctl`/`lsof` in tests.

## Common commands
- Run: `./run.sh` (creates `.venv` on first run, serves :8787). It self-hosts as the agent
  `com.launchddash.server` — after merging, `launchctl kickstart -k gui/$(id -u)/com.launchddash.server`
  to pick up the new code.
- Tests: `.venv/bin/python -m pytest -q` · Lint: `.venv/bin/ruff check .`
- The UI is a Python string, so there's no JS runner: syntax-check it with
  `python -c "from app.main import PAGE"` → extract `<script>` → `node --check`.

## Workflow
- **Branch → PR → green → squash-merge.** `main` is protected by rulesets (required check
  **"Lint + test"**; history protection has no bypass).
- **That check name is a contract with a ruleset stored in the GitHub UI, where no diff shows
  it.** Adding the 3.9/3.12 matrix renamed the only job to `Lint + test (py3.9)`, so the
  required context could never report again — the PR was refused by the base-branch policy with
  nothing red to explain why, and every later PR would have been too. `ci.yml` now carries an
  aggregate `gate` job that owns the name and `needs:` the matrix, with `if: always()` — without
  that, a failed matrix leaves the gate SKIPPED, and a skipped required check does not block a
  merge. `tests/test_workflows.py` pins both.
- **Never pipe the gate**: `gh pr checks … | tail` swallows the exit code and merged a red PR
  once. Run it unpiped so `&&` sees the real status, and confirm `gh run list` after.
- Commit messages: no `Co-Authored-By` trailer. Backticks in `-m` get eaten by zsh — use
  `git commit -F <file>` and `gh pr create --body-file` for anything with code formatting.
- Docs ship with the change; machine-local config (`apps.json`, `labels.json`) is gitignored,
  with a committed `.example`.

## Important notes / gotchas
- **macOS TCC blocks launchd agents from `~/Documents`/`~/Desktop`/`~/Downloads`** — the agent
  gets `EPERM` ("Operation not permitted", *not* the permission-bits `EACCES`) with no prompt,
  while the same command works from Terminal (which holds the folder grant). This repo lives at
  the home root for that reason; `tcc_blocked()` marks such projects **blocked** rather than
  letting them die cryptically. Never place agent-run code back in those folders.
- **Generated plists must bake their environment.** launchd gives a minimal PATH and no shell
  profile, so `robust_path()` assembles homebrew + `~/.local/bin` + the newest fnm node. Same
  reason Python inference prefers `.venv/bin/python` over a bare interpreter name.
- **`stop_app` keeps the plist for `login: true` apps; `remove_app` must always delete it** —
  otherwise a removed app resurrects at next login pointing at a deleted directory. This
  asymmetry is deliberate and test-pinned.
- **`restart` must wait for the job to unload.** `bootout` returns while the process is still
  dying, and `start_app`'s already-running check would then skip the bootstrap, leaving nothing
  running (found live; unit tests all passed).
- **Deduplicate directories by `(st_dev, st_ino)`, never by `Path.resolve()`.** macOS volumes
  are case-insensitive, so `~/projects` and `~/Projects` are one directory that `resolve()`
  reports as two — every project got listed twice. Lowercasing would break case-sensitive volumes.
- **The Apps row must follow reality, not `apps.json`.** A dev server silently lands elsewhere
  when its port is taken (Next.js steps 3000→3001), so `/api/apps` joins live agent ports →
  `open_port` / `port_mismatch`. Declared ports also drive `claimed_ports()`, which is what makes
  a stopped project's port stay visible — and what frees it when the entry is removed.
- **`discover` and `adopt` must agree on "already configured".** They once keyed on directory vs
  slug respectively, so a *moved* project rendered adoptable and then refused. There is an
  invariant test: anything the UI offers with an enabled checkbox must be accepted by `adopt`.
- **Never drop a project silently.** `classify_project` always returns a candidate; when nothing
  can be inferred it carries `launchable: False` + a reason. A silent skip reads as a broken scanner.
- **Script inference stays narrowly `dev.sh`/`run.sh`.** Repos ship task scripts
  (`isolate.sh`, `render_job.sh`, `cleanup.sh`); launching one by accident is worse than not launching.
- **HTTP carries slugs only.** Commands come exclusively from the local config file — keep any
  new endpoint on that side of the trust boundary.
- **`innerHTML =` destroys child nodes.** The log panel is *moved* under the clicked row, so it
  lives inside a list the 30s poll re-renders: it's held in `const logPanel` and its children are
  reached through it (`getElementById` can't see a detached subtree either).
- **Link to `localhost:<port>`, never the IPv4 literal.** `localhost` resolves to `::1` *or*
  `127.0.0.1`, so it reaches the server whichever family it bound; a Vite/Next default bind is
  IPv6-only on macOS, where `http://127.0.0.1:PORT` is refused outright (measured). It's also the
  host dev servers' Host-header allowlists expect — an IP literal trips their cross-origin warning.
- **"exposed" = bound to `*` (`0.0.0.0`/`::`), i.e. reachable from the LAN**, not just this Mac —
  `is_localhost()` requires *every* bound address to be loopback. Note `next dev` binds all
  interfaces unless `-H 127.0.0.1` is passed, so adopted Next apps are exposed by default; Expo's
  `:8081` is exposed on purpose (the phone must reach Metro). Verify a claim like this by curling
  the machine's own LAN IP, not by reading the flag.
- **`osascript display notification` DOES fire from a launchd agent** (spike-verified
  2026-08-04, user confirmed the banner on screen — exit 0 alone proves nothing). The
  script string must be escaped backslashes-FIRST-then-quotes (`_osa_str`): a listener's
  command name is attacker-influenced text and must never break out of the AppleScript
  string. Same reason the watch UI escapes every interpolation and rides ack targets in
  `data-` attributes with one delegated listener — never inline `onclick='…${key}…'`.
- **Inbound requires an ADDRESS match, not just a port match** (`_can_receive`). macOS
  draws ephemeral ports from 49152–65535 and local tools (editors, AI agents) listen on
  *loopback* ports in that same range, so an OUTBOUND connection's local port routinely
  equals a port we listen on. Port-only matching reported those as "a PUBLIC address
  connected to you" — **every public alert on this machine was one, all with rport 443**.
  A loopback-only listener cannot be reached at a public address; that's the discriminator.
  Treat `*`, `0.0.0.0` and `::` all as "all interfaces" — reading `::` as IPv6-only would
  DROP real inbound IPv4, and a missed connection is the worse failure here.
- **Render host+port through `endpoint()` / the JS twin — IPv6 needs brackets.**
  `2607:6bc0::10:443` reads as a longer address, and demo mode masks that merged string
  to a *different* fake than the bare host elsewhere in the row, so one device renders as
  two (it shipped that way in a published GIF). Events also store `lhost`, without which
  a stored connection can't be re-adjudicated later.
- **The network watch seeds SILENTLY on first run** — the value is the diff, and a
  day-one storm of 20 banners about your existing setup would train the user to ignore
  the channel. Corollary: deleting `netwatch.json` re-seeds (no alerts until something
  *changes* again); a corrupt file is parked as `.bak`, never overwritten blind.
- **Exposure outranks attribution in the watch rules.** An agent- or project-attributed
  listener is log-only on loopback but BANNERS when bound `*` — your own `next dev`
  without `-H` is exactly the case to catch. Per-key acks likewise don't survive a
  loopback→exposed flip (a new fact); only `acked_commands` silences a command entirely
  (Chrome binds `*` on a fresh random port per session, so per-key ack can't quiet it).
- **`/api/ports` and the watcher share ONE scan path** (`_scan_ports()` in main.py,
  now returns `(ports, specs, agents)`). Don't add a second listener-scan/attribution
  assembly — two paths answering "who holds this port?" will drift, which is the
  moved-project bug all over again. The agent list it returns also feeds the failure watch.
- **Agent-failure alerts are EDGE-triggered and episode-based** (`observe_agents`). A
  banner fires on the healthy **True→False** transition, not on seeing a failed agent
  (first sighting seeds silently — you'd otherwise be re-told old history every restart).
  `agent_failed` is in `_TRANSITION_KINDS`, so it **ignores a prior ack** — an ack ends
  the current episode, the next failure is a new fact (a permanent per-agent mute would
  have re-hidden the recipes job). Recovery (False→True) is log-only and clears the alert.
  Watches only the user's OWN agents (`list_agents(include_vendor=True)` minus vendor);
  `com.launchddash.app.*` are excluded by `list_agents` and deliberately unwatched (dev
  servers exit nonzero constantly during iteration — that's noise, not a failure).
- **`known` entries are the ROSTER, not a seen-set — never drop one.** Each carries
  `first_seen`/`last_seen`/`live`/`sessions` (+ `exposed` for listeners, `rhost`/`lport`/
  `hostname` for conns, so nothing has to re-parse a colon-riddled IPv6 key). `sessions`
  counts **episodes** — incremented only on a dead→live transition, so a dev server left
  up all day is 1, not 2 880. Keys missing from a scan are marked `live: False` and kept:
  that's what makes "last seen 2h ago" and the Devices roster possible.
- **`_touch()` must tolerate a LEGACY entry shape forever** (`{}` / `{"exposed": bool}`
  from before sighting stats). It backfills on first touch — `first_seen` then honestly
  means "tracked since". A naive `setdefault`-then-increment lands on `sessions: 2` for
  every pre-existing key; there is a test for exactly that.
- **The run ledger records a run only when `last_run` moved AND no pid is live**
  (`_record_run`). Mid-run, `last_exit` is still the PREVIOUS run's, so sampling then
  pairs a fresh timestamp with a stale exit code. Deferring costs one cycle. KeepAlive
  services (a pid forever) therefore keep only their seed record — correct, the ledger
  is for scheduled/one-shot jobs.
- **`netwatch.log.jsonl` is append-only and never rotated** (`archive_records`, one
  writer: the watcher thread). It exists because the in-state rings are capped at 200;
  at dozens of records a day it takes years to reach a megabyte. Failures print and are
  swallowed — the archive must never break a watch cycle.
- **Every dashboard-initiated agent stop MUST mark an expected-exit** (`_expect_exit`,
  ~90s TTL) or it banners "agent X failed (exit 143)". Currently marked in `api_stop`,
  `api_run` (kickstart -k kills first), `api_disable`. **Adding a new endpoint that kills
  or unloads a real agent means adding `_expect_exit(label)` to it.** A manual
  `launchctl kill` from a terminal still banners once — acceptable, and honest.
- **The watcher RECORDS every banner it sends** (`record_notification`, the **Network
  History** sheet + `/api/watch/history`), successes and failures both; a failed send bumps
  `notify_failures`, surfaced in the meta line — a dead notification channel must announce
  itself, same principle as `watch_errors`. `post_notification` runs OUTSIDE the state
  lock (osascript can take seconds); recording re-takes the lock after.
- **The UI is FIVE TABS (`TABS` in the page script), and switching is VISIBILITY ONLY.**
  Every panel stays mounted (`hidden` attribute, plus a `[hidden] { display: none !important }`
  guard — the bare attribute loses to any `display:` rule) and every renderer keeps running on
  the 30s poll whether or not its panel shows, because the sections are coupled: the log panel
  parks under a row in `#list` OR `#applist`, `evCard` cross-checks `portData`, removing an app
  refreshes ports, and the `(N!)` title badge comes from a fetch the Watch panel doesn't own.
  Unmounting the hidden ones would break four features to save four requests.
  - **The hash is the ONLY persistence** (storage is banned outright — see the demo-mode
    rule), so `/#ports` is a shareable link. `goTab` uses `history.replaceState`, not
    `location.hash`: a tab is a view, so Back should leave the page rather than walk back
    through five tabs.
  - **`selectTab` must never fetch.** Boot runs it BEFORE the demo-arming block would have a
    chance to matter — the order is arm demo → `selectTab(fromHash())` → `loadAll()` — because
    `/?demo=1#history` would otherwise put an unmasked history request on the first frame a
    recorder captures. `goTab` is the runtime path and fetches history when that tab becomes
    visible; a text test and a node-executed one pin both halves.
  - **History is a tab panel, not an overlay** — never built inside a poll-re-rendered list,
    because `innerHTML` destroys child nodes (the log-panel lesson). `/api/watch/history` is
    fetched from ONE place (`loadHistory`), and the 30s poll re-fetches it ONLY while
    `historyOpen`, so a tab nobody is on costs zero requests. Every interpolation goes through
    `esc()` (bodies/summaries embed process command names).
  - **Escape closes the open LOG PANEL** now that the sheet is gone. Don't "restore" it to
    closing a history overlay; there isn't one.
- **Events carry a structured `data` dict** (`_emit`'s `data` arg → `_listener_data` /
  `_conn_data` / `_agent_data`) beside the compact `detail` string — that's what the
  click-to-expand card reads (full command line `args`, addresses, remote endpoint, exit
  code…). **Old persisted events have no `data`** — every consumer must tolerate `{}`.
  The listener card's headline is `args`, the most attacker-shaped string in the app —
  `esc()` it. Card expansion state lives in a JS `expandedEvents` Set that the row
  TEMPLATE (`evListHTML`) consults, so an open card survives the 30s re-render; a click
  toggles the Set and re-renders from the CACHED fetch (`lastWatch`/`lastHistory`) — never
  refetches. The listener card cross-checks the already-polled `portData` for "still
  listening now". `resolve_hostname` (dscacheutil, best-effort, cached, `""` on miss —
  output shape verified live: a `name:` line when resolvable, nothing when not) names LAN
  devices; only inbound rows about to alert are resolved, so it runs rarely.
- **The page's JS lives inside a PYTHON string, so every backslash must be DOUBLED.**
  A single `\b` in a regex literal is Python's backspace character (0x08) — the regex
  compiles, matches nothing, and looks fine in review. That shipped the demo-mode IP
  masking dead on arrival; a `test_page.py` guard now fails on any control character in
  the script, and the scrub block is extracted and RUN under node rather than
  text-asserted (a privacy gate can't be verified by grepping for its own source).
- **`api()` is the only place a response becomes data** (`await fetch` + `.json()`).
  Demo mode masks inside it, so every renderer and toast is downstream by construction —
  a new call site that reads `.json()` itself would silently leak real IPs into a
  recording. Pinned by a count assertion. Masking is **display-only**: never scrub
  server-side, the API and `netwatch.json` must stay truthful.
- **Dependency floors must stay Python-3.9-installable** (`run.sh` uses the system `python3`).
  `fastapi>=0.129` / `uvicorn>=0.40` / `pytest>=9` need ≥3.10 and are ignored in `dependabot.yml`;
  CI runs 3.12 and cannot catch this — dry-run any floor bump on the 3.9 venv. PRs also run the
  user's own [preflight](https://github.com/Ali0600/preflight) action with `python-version: 3.9`.

## Security invariants

- **Loopback is not a boundary against a web page** — the browser is on loopback too. Nine
  mutating routes take no request body, which makes a cross-origin `<form method=POST>` a CORS
  *simple request*: delivered and EXECUTED, with only the response withheld. `BlockCrossOriginWrites`
  (a pure ASGI middleware in `app/main.py`) refuses a non-GET whose `Sec-Fetch-Site` is not
  same-origin, falling back to comparing `Origin` against the `Host` we were addressed as. A
  caller sending neither header is not a browser (curl, the recorder, the playbook below) and is
  allowed — a local process reaches the socket regardless. `TrustedHostMiddleware` closes DNS
  rebinding, which is what lets reads stay open. `tests/test_security.py` parametrises over the
  app's **own route table**, so a route added later inherits the tests instead of shipping
  unguarded.
- **Every renderer escapes what it interpolates.** `esc()` used to sit halfway down the script:
  everything below it escaped, everything above it did not — a split by position, not principle.
  The four above it interpolate plist Labels, `apps.json`, `lsof` process names, directory names,
  and the `name` of any `package.json` under a scanned root. Cloning a repo named
  `<img src=x onerror=…>` and clicking Scan was a live XSS on the dashboard's own origin, which
  can drive every route including adopt + start → `/bin/zsh -c`. **`esc()` does NOT help inside
  `onclick="act('${x}')"`** — the browser decodes `&#39;` before the JS parser runs — so action
  values ride in `data-` attributes read by delegated listeners on the static containers.
- **`lines` is clamped** on both log routes (`Query(200, ge=1, le=5000)`): unbounded, `lines=0`
  meant `data[0:]` — the whole file through a parameter that reads like a limit.
- **The agent routes refuse `com.launchddash.app.*` labels.** We mint them, so they are the most
  guessable on the machine, and their own stop path is what deletes the generated plist.
- **A workspace `package.json` `name` is validated** against npm's grammar before it becomes a
  shell word in `npm run dev -w <name>` — that string comes from a repo under a scanned root and
  is persisted to `apps.json`, then run by `/bin/zsh -c`.

## Privacy — this repo is public

Two gates, because neither can do the other's job:

- **`pytest tests/test_privacy.py`** runs in CI, where nothing is known about this
  machine, so it checks STRUCTURE: an unrecognised `/Users/<name>`, a `.local` device
  name, a private address outside a closed fixture allowlist. Adding to an allowlist is
  meant to be a deliberate act — that is the moment to ask "is this a real address?".
- **`./scripts/privacy-check.sh`** is the half only this machine can run. It derives the
  needles at run time (`$HOME`, the LAN IP, `LocalHostName`, `ComputerName`, the git
  author name and email, the LAN prefix) and greps every tracked file. **Run it before
  pushing.** Committing those values so CI could check them would be the leak itself.

Fixture conventions: `/Users/dev` (and `/Users/demo` for masked output), `10.0.1.x`
addresses, `lab-phone.local`, `router.lan`. The repo carried a phone named after the
author, their real subnet and their router's model until 2026-09-05 — the demo gate in
`assemble-demo.sh` had been guarding published GIF frames for the same categories all
along, and simply never looked at the source.

## Re-recording the demo (`docs/demo.gif`)
```bash
curl -s -X POST http://127.0.0.1:8787/api/apps/waymark/stop   # the app whose Start we film
cd <any checkout with playwright installed> && DEMO_EVENT_MATCH=<an event to expand> \
  node <this repo>/scripts/record-demo.mjs                    # playwright lives THERE, not here
cd <this repo> && ./scripts/assemble-demo.sh
```
- **Playwright is deliberately not a dependency** (it would pull a browser download into a
  zero-dependency repo); the script resolves it from the *working directory*, so run it from
  a checkout that has it. It loads `?demo=1` so masking is armed before the first fetch and
  **refuses to record** if it can't confirm that from the DOM.
- **One frame per scene, held by an explicit duration** — never repeat frames to fake dwell.
  The first version captured the same screenshot 8–12× at a flat 10fps, which put each
  caption on screen for under a second (only 12 of 106 frames were distinct). Holds come
  from each caption's word count, so timing follows the copy.
- **Never add an `fps=` filter to the GIF pipeline.** It resamples to a constant rate and
  silently flattens every hold — the captions become unreadable again and the file still
  looks fine. `assemble-demo.sh` reads the delays back out of the finished GIF and exits 1
  if they are uniform or under 1.4s; both outputs are staged and only moved into `docs/`
  once that check *and* the privacy gate pass.
- **`DEMO_EVENT_MATCH` picks which event gets expanded on camera.** The card renders a full
  command line, so "whatever happened most recently" can put unrelated third-party software
  in a published GIF.
- The GIF size is ~940K and will not shrink by cutting frames: identical frames compress to
  nearly nothing, so the bytes are the ten *distinct* full-screen frames.

## Testing conventions
- Fixtures only — no live `launchctl`/`lsof`; neutral paths (`/Users/dev`), never real ones.
- **`tests/conftest.py` redirects every real-file path, and patching the module constant is NOT
  enough.** These functions capture the path as a DEFAULT ARGUMENT — `def save_state(state, path
  = STATE_PATH)` — and defaults are evaluated once at def time, so `setattr(netwatch,
  "STATE_PATH", tmp)` leaves `save_state.__defaults__` holding the real `Path`. The no-argument
  call, the only dangerous one, is exactly what the rebinding misses: a `save_state(state)` while
  writing that fixture destroyed the live `netwatch.json` (recovered from `netwatch.log.jsonl`,
  which is why that archive is append-only). The fixture patches the attribute **and** every
  captured default, including importers (`discover` imports `CONFIG_PATH` from `apps`) and
  list-valued search paths (`launchd.AGENT_DIRS`).
- **A test for destructive behaviour must prove it is safe BEFORE performing the destructive
  step.** `test_a_default_argument_write_lands_in_the_sandbox` asserts the defaults are
  redirected by inspection, then writes. The first version detected the fault by *performing*
  it, so the sabotage run that "proved the test worked" destroyed the file a second time.
- **Route tests never use `with TestClient(app)`** — the context-manager form runs the lifespan
  and starts the real 30-second watch loop against the machine. Stub at the subprocess boundary
  (`launchd._run`, `apps._run`, `ports._out`), not above it: patching `launchd.run_now` tests
  the mock, patching `_run` exercises the handler, the lookup and the argv.
- The UI's invisible constraints are pinned as **text assertions over the `PAGE` string** in
  `tests/test_page.py` (no JS runner exists here) — except the two blocks that are EXECUTED
  under node against a stub, because a text assertion cannot tell a working masker from a
  decorative one: `// __SCRUB__` (demo masking) and `// __TABS__` (tab switching). Keep both
  self-contained; the tab stub models only `hidden` / `tabIndex` / `setAttribute`, so reaching
  for `classList` or `querySelector` in that block breaks it loudly, which is the point.
- **Prove new tests fail-first.** Sabotage, watch it go red, then restore **from a file copy and
  compare checksums** — never `git checkout` on a file with uncommitted work. **A changed file
  hash is not proof the mutation reached the JUDGE**: writing `app/main.py` and immediately
  launching pytest raced here, and about half the runs imported the pre-sabotage source and
  reported a false survivor. Wait until a CHILD interpreter's own `PAGE` hash differs from the
  pristine one before running the test, and report "never became visible" as a harness fault
  rather than as a verdict.
- Check the **test count**, not just "passed": an edit once silently merged two tests and the
  suite still read green.

## Verifying against the live dashboard
The agent runs the merged code, so verify through it (`curl` the API, or the browser pane) rather
than trusting unit tests alone — every bug in this repo's history was found that way.
- Re-check `window.innerHeight` before believing any browser geometry: the harness viewport
  degenerates to 0 after a navigate, which makes `scrollIntoView` scroll unconditionally.
- Measure what the user perceives: the clicked row's `getBoundingClientRect().top`, not
  `window.scrollY` — removing content above the fold changes scroll for the same visual position.
- Use a throwaway app entry for destructive checks; never test removal on the user's real apps.
