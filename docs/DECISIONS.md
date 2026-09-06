# Design decisions — the roads not taken

## Backlog — alternatives worth trying later

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

---

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
