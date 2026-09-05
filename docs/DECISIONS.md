# Design decisions — the roads not taken

## Backlog — alternatives worth trying later

- **All 11 demo scenes at full pacing (~40s)** — if scenes are added back and the length is
  acceptable. Holds come from `readingTime()` in `scripts/record-demo.mjs`.

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
