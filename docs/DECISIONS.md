# Design decisions — the roads not taken

## Backlog — alternatives worth trying later

- **A menu bar item for the Mac app** — the active-alert count in the menu bar, beside the
  window rather than instead of it. Seam: `ServerMonitor.onUpdate` already hands the count to
  `macos/Sources/GroundControl/AppDelegate.swift`; add an `NSStatusItem` there.
- **A notarized, universal Mac app built by CI** — a DMG on GitHub Releases, so the app can be
  handed to someone else. Seam: the signing step in `macos/build.sh` plus a release workflow;
  needs a Developer ID certificate as a repository secret.
- **All 11 demo scenes at full pacing (~40s)** — if scenes are added back and the length is
  acceptable. Holds come from `readingTime()` in `scripts/record-demo.mjs`.
- **State robustness (audit PR 4, not started)** — a corrupt `netwatch.json` silently
  re-seeds (losing acks, roster and ledger with no warning); `save_state` swallows `OSError`
  while `/api/watch/ack` still reports success; `apps.json` is written truncate-then-write,
  unlocked, by two writers; `/api/watch` ships 113 KB every 30 s; `launchd.py` mixes naive-local
  and UTC-aware timestamps in one record. Seams: `netwatch.load_state`/`save_state`,
  `apps._write_config`, `api_watch`, `launchd._last_run`.
- **Docs + hygiene (audit PR 5, not started)** — `docs/demo.mp4` is committed but referenced by
  nothing (the two demo files are ~72% of `.git`); `docs/learnings.md` uses `##` where the house
  shape says `###`; no `LICENSE` on a public portfolio repo; the archive-growth claim in
  `CLAUDE.md` is ~4× optimistic (measured ~5.8 KB/day, so 1 MB in ~6 months, not "years").
- **Alert lifecycle** — an `active` alert is removed only by an explicit ack or an agent
  recovery, so a listener that exited months ago still alerts. Auto-resolve when the subject is
  gone, and separate `resolved` from `acked`. Evidence: 29 standing unacked alerts before this
  session's incident. Seam: `netwatch.observe`'s `active` bookkeeping.
- **`_TRANSITION_KINDS` is dead code** — referenced nowhere in `app/` after its tautological
  test was replaced by two behavioural ones. Either make it load-bearing in `observe`'s two
  branches or delete it and move the comment.
- **A light theme** — the redesign put every colour behind `:root` custom properties, so this
  is now one `@media (prefers-color-scheme: light)` block redefining ~20 tokens rather than a
  hunt through the stylesheet. Deferred because the demo GIF only shows one theme and it
  doubles the visual QA surface. Seam: the token block at the top of `PAGE`'s `<style>`.

---

## 2026-11-10 — What kind of Mac app

**Fork:** the user asked for "a macOS app" for the dashboard and named no approach, so the
options below were weighed and the choice made by the agent, not the user. Revisit freely.

- **A) A native Swift shell — AppKit + `WKWebView`, built by SwiftPM and a script — that is a
  client of the existing agent.** About 1.4 MB, no new dependency for the server, and native parts
  where a browser tab can't help: a Dock badge, a screen for "the server is down" that can
  start it, outside links handed to the real browser.
- **B) Bundle the Python server inside the app (py2app / pywebview).** One thing to install —
  but the app would own a second server fighting the agent for `:8787`, the network watch would
  stop whenever the app quit, and a two-dependency server would gain a GUI toolkit.
- **C) Electron or Tauri.** Cross-platform, but the tool is macOS-only by nature (launchd,
  `lsof`), and they add Chromium (~150 MB) or a Rust toolchain to show one local page; Tauri
  renders through the same WebKit anyway.
- **D) Safari's "Add to Dock" web app.** No code at all — but nothing native: no way to start
  or restart the agent at the moment the page is unreachable, and a badge would need page
  changes for the Badging API.
- **E) A menu-bar-only app (`LSUIElement`) with a popover.** Suits an always-on monitor, but the
  dashboard is five dense tabs, which want a real window.

**Chosen: A.**

- B — *rejected* — a second server undermines the agent the whole tool is built around.
- C — *rejected* — a browser runtime to wrap the browser engine macOS already ships.
- D — *rejected* — "the server is down" is exactly when a native screen is needed.
- E — *deferred — worth trying* as an addition beside the window, not a replacement. Revisit
  hook: `ServerMonitor.onUpdate` already delivers the count to `AppDelegate`.

**Sub-fork: signing.** Ad hoc (`codesign --sign -`), chosen: it runs on the Mac that built it
and needs no Apple Developer account. A Developer ID–signed, notarized, universal build
published by CI is *deferred — worth trying* (see Backlog); it plugs in at `build.sh`'s
signing step.

**Sub-fork: the icon.** Drawn by code at build time (`GroundControlIcon`), chosen over a
committed `.icns`: a committed build artifact needs a drift check, and PNG output isn't
guaranteed byte-identical across macOS releases. Revisit if a designed icon arrives — macOS
26's Icon Composer `.icon` format would replace the generator.

---

## 2026-09-06 — Tabs over one long page

**Fork:** the page stacked four sections in an 880px column, so reaching the network watch
was a screen and a half of scrolling, and the History sheet gave the page a second navigation
model on top of that. What replaces the scroll?

- **A) Five tabs (Agents · Apps · Ports · Watch · History), all panels mounted, tab in the
  URL hash.** One model for everything, the header stops competing for room, and each panel
  can carry its own controls.
- **B) Stacked sections with a sticky jump-nav.** Everything stays visible at once and no
  state is added — but the scroll is the complaint, and a jump-nav only automates it.
- **C) Keep the sheet and make the four sections collapsible.** Cheapest diff, but it leaves
  two navigation models and makes "where is that thing" depend on what you collapsed.

**Chosen: A**, with the sheet retired into the fifth tab (the user's call on both). Panels are
mounted and every renderer keeps polling: the sections are coupled — the log panel parks under
a row in two different lists, the watch card cross-checks the port scan, and the `(N!)` title
badge comes from a fetch no visible panel owns — so unmounting the hidden ones would break four
features to save four requests.

- B — *rejected* — it keeps the scroll, which was the whole complaint.
- C — *rejected* — two ways to reach one thing is the bug the sheet itself was introduced to
  fix (it replaced an in-section toggle for the same reason).

**Sub-fork: where does the current tab live?**

- **The URL hash (chosen).** Shareable (`/#ports`), survives a reload, costs nothing at rest.
- `localStorage` — *rejected* — storage is banned outright in this script, deliberately: it is
  what stops demo mode surviving a reload and showing someone else's machine as if it were
  yours. One exception erodes the rule.
- Nothing at all — *rejected* — a reload dropping you back on Agents is the kind of small
  friction that makes a dashboard feel disposable.

`history.replaceState` rather than assigning `location.hash`, so Back leaves the dashboard
instead of walking through five tabs. **Revisit hook:** `goTab` in `PAGE` is the single
runtime path; every switch — click, arrow keys, hashchange, an event card's View log — goes
through it.


## 2026-09-05 — Refusing cross-origin writes without adding auth

**Fork:** how does a localhost-only tool stop a page the user visits from driving its
mutating routes? Loopback is not a boundary — the browser is on loopback too, and nine routes
took no request body, which makes a cross-origin form post a CORS *simple request*: delivered
and executed, with only the response withheld.

- **A) Fetch metadata** — refuse a non-GET whose `Sec-Fetch-Site` is not same-origin, with an
  `Origin`-vs-`Host` fallback for older browsers. The header is set by the browser and cannot
  be forged by page script. No state, no token store, no cookie.
- **B) A CSRF token** — mint one into the page, require it on every write. The standard answer,
  but it needs a store, a rotation story, and it breaks `curl`, the demo recorder and the
  documented playbook.
- **C) Require a custom header** (`X-Requested-With`) — forces a preflight on everything.
  Cheaper than B, but it still breaks every non-browser caller.
- **D) Real auth** — a password or token on a single-user localhost tool, i.e. a credential to
  manage for a threat model that does not include other local users.

**Chosen: A.** It is the only option that costs nothing at rest and keeps non-browser callers
working — a caller sending neither header is not a browser, and a local process can reach the
socket regardless of what any middleware says, so refusing it would buy nothing. Paired with
`TrustedHostMiddleware` for DNS rebinding, which is what allows reads to stay open.

- B — *deferred — worth trying* if the dashboard ever serves more than one user, or moves off
  loopback. **Revisit hook:** `BlockCrossOriginWrites` in `app/main.py` is one class; a token
  check slots into the same `__call__`.
- C — *rejected* — same cost as A plus broken CLI access.
- D — *rejected* — a credential nobody wants to manage, guarding against an attacker who would
  already have the machine.

## 2026-09-05 — Fixture addresses for a repo whose feature classifies addresses

**Fork:** the test suite committed the author's real subnet, phone name and router model. What
replaces them?

- **A) RFC 5737 documentation addresses** (`192.0.2.x`, `198.51.100.x`) — unambiguously fake,
  and the CI gate could then forbid *every* private literal outright.
- **B) Private addresses from a range that is not the author's**, with a closed allowlist.

**Chosen: B.** `classify_remote` sorts by RFC-1918 membership, so its `lan` branch can only be
exercised with private addresses — under A the tests for the feature's core would silently be
testing the `public` branch instead. The allowlist is small and closed so adding an entry is a
deliberate act, at the moment when "did this come off a real network?" is the obvious question,
and it fails on a **stale** entry too.

- A — *rejected* — would make the strongest-looking gate certify a configuration the feature
  never runs in. **Revisit hook:** `ALLOWED_PRIVATE_IPS` in `tests/test_privacy.py`; only worth
  revisiting if `classify_remote` ever stops keying on RFC-1918 membership.

## 2026-09-05 — Recovering a destroyed state file

**Fork:** a test overwrote the live `netwatch.json`. The append-only archive and an older
snapshot survived. How much is rebuilt?

- **A) Rebuild what the archive witnessed** — events, notifications, first-seen history, the
  ack decisions and the run ledger — and leave `active` alone.
- **B) Also reconstruct `active`** from the archive's alert records.
- **C) Hunt for a Time Machine copy.**

**Chosen: A** (user's call). The archive records which alerts *fired*, not which were still
unacknowledged, so B would re-raise alerts the user had already dismissed — trading a clean
slate for noise. C needed a backup destination that would not mount.

- B — *rejected — cannot distinguish acked from open*; the roster rebuilds itself as things are
  seen again.
- C — *rejected — destination unavailable*.
- **What did not come back:** ~86 roster rows that never generated an event (mostly Chrome's
  per-session ephemeral listeners) and their `sessions` counts, now restarting from 1.

---

## 2026-08-04 — Network watch: alert channel

**Fork:** where do network-watch alerts reach the user?

- **A) macOS banners + dashboard** — native `osascript` notifications from the always-on
  agent, plus an alerts section and `(N!)` title badge. Reaches the user with the page
  closed; needed a spike to prove banners fire from a launchd context (they do).
- **B) Dashboard only** — title badge + section. Zero notification plumbing, but silent
  unless the page is open.

**Chosen:** A (user's call). The spike passed on the first try, so the fallback flag for
B was never needed.

- B — `rejected — defeats the point of an always-on watcher; the dashboard page is
  rarely open`.

## 2026-08-04 — Network watch: LAN-device connection noise

**Fork:** how loud is a device on your own Wi-Fi connecting to one of your servers
(e.g. the phone hitting Expo `:8081`)?

- **A) Alert once per (device, port)** — first sighting banners, one tap acks forever;
  public remotes always alert. An unfamiliar LAN device still pushes a banner.
- **B) List only, never banner** — quietest, but a compromised IoT box or a guest's
  laptop probing dev servers would surface only if the user happened to look.

**Chosen:** A (user's call). The key excludes the ephemeral remote port, which is what
bounds the noise to once-per-device-per-service.

- B — `rejected — hides exactly the event the feature exists for`. *Revisit hook:* if A
  proves noisy in practice, `_ALERT_SEVERITY["lan_connect"]` is the one line that
  downgrades it to log-only.

## 2026-08-11 — What to call this thing

**Fork:** "launchd dashboard" named the substrate, not the product. Four of six pillars
(app launcher, port intelligence, network watch, longitudinal memory) aren't about launchd,
and the macOS jargon buries the "monitoring and control plane" story for anyone skimming.

- **A) Ground Control** — mission-control metaphor, covers observe/control/remember/alert,
  launchd becomes an implementation detail.
- **B) Portside** — short and brandable, leans on the port-intelligence half.
- **C) Engine Room** — evocative but a more generic phrase.
- **D) Keep the name** — zero churn, instantly clear to a Mac-literate audience.

**Chosen:** A, renamed at both product and GitHub-repo level (GitHub redirects the old URL).

- B, C — `rejected — each names one pillar or nothing in particular`.
- D — `rejected — the name was actively costing discoverability`. *Revisit hook:* `APP_NAME`
  in `app/main.py` is the single source for every user-visible title.

**Deliberately NOT renamed:** the `com.launchddash.*` agent labels (a label is an identity
that installed plists and running jobs refer to), the local checkout path, and the historical
entries in these docs. Churn with no visible benefit.

## 2026-08-11 — Demo GIF pacing vs. total length

**Fork:** readable captions need ~3.5s each; 11 scenes at that rate is ~40s, long for a
looping README GIF.

- **A) Merge the thin scene pairs, ~29s** — fold port-attribution + "exposed" into one and
  "it watches" + "what it watches for" into one, tighten the copy, hold each ~3.6s.
- **B) All 11 scenes at ~3.5s (~40s)** — nothing cut, but many viewers won't reach the end.
- **C) All 11 at ~2.7s (~30s)** — readable only if you're already paying attention.

**Chosen:** A. It landed at **36s over 10 scenes** rather than the estimated 29 — the merge
saved one scene but splitting the launcher into a before/after pair added one back, and
honest reading time averages ~3.7s. Kept the generous timing because "too fast" was the
actual complaint.

- C — `rejected — re-creates the reported problem in milder form`.
- B — `deferred — worth trying` if scenes are ever added back. *Revisit hook:* holds are
  derived in `readingTime()` in `scripts/record-demo.mjs`; the constants there set the pace.
