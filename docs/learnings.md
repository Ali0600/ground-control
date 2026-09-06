# Learnings

## `lsof -F`: machine-parsable field output beats column scraping

`lsof` (and friends) offer a field mode (`-F pcn` → one `p<pid>` / `c<command>` /
`n<name>` item per line) designed for programs to parse, instead of the human table.

**Why it came up:** the port tracker parses `lsof -iTCP -sTCP:LISTEN`. The table format
breaks on process names with spaces — a live listener here was literally
`Code Helper (Plugin)`, which `awk`-style column splitting shreds into four fields.
Field mode has no columns to mis-split.

**Takeaway:** when a CLI tool has a "for programs" output mode (`-F`, `--porcelain`,
`--json`), parse that — never the human-readable table.

## Attribute a socket to a service by walking the parent-pid chain

The process holding a port is usually a *child* of the process a service manager knows
about (launchd spawns `run.sh`, which execs/spawns `uvicorn`; the listener's pid ≠ the
agent's pid).

**Why it came up:** linking listening ports to the launchd agent that owns them — a
direct pid comparison missed every agent that starts via a wrapper script. Walking
`pid → ppid → …` (from one `ps -axo pid=,ppid=`, with a cycle guard) until an ancestor
matches an agent pid attributes them correctly.

**Takeaway:** to map a resource (socket/file/child) back to a managed service, compare
against the service pid's whole *ancestry*, not just the pid itself.

## launchd agents get EPERM in TCC-protected folders — EPERM ≠ EACCES

macOS privacy protection (TCC) guards `~/Documents`, `~/Desktop`, and `~/Downloads` per
*app*. Terminal.app holds a grant the user approved once, so everything launched from a
shell inherits it — but a launchd agent runs under `launchd`, gets no grant and no prompt,
and any file read in those folders fails with `PermissionError: [Errno 1] Operation not
permitted`.

**Why it came up:** self-hosting this dashboard as `com.launchddash.server` failed with
exit 256 while `./run.sh` from the terminal worked perfectly — the repo lived in
`~/Documents`, so the agent's Python couldn't even read `.venv/pyvenv.cfg`. Moving the
repo to `~/launchd-dashboard` (home root, like `~/grocery-helper`, whose weekly agent
always worked) fixed it with no settings changes.

**Takeaway:** put anything a background agent must read outside TCC-protected folders —
and read the errno: `Operation not permitted` (EPERM) with correct Unix permission bits
means a sandbox/TCC layer, not `chmod`.

## What "detecting an intruder" means without root: diff the lsof scan, don't promise an IDS

User-level polling of `lsof` can genuinely detect three things: a **new process
listening** (backdoors, but also SSH/Screen Sharing being switched on), a listener
**flipping from loopback to LAN-exposed**, and **established inbound connections**
(classified loopback / private / public via stdlib `ipaddress`). It structurally cannot
see port scans (packet-level, needs root), connections shorter than the poll interval
(sampling blind spot), or outbound traffic.

**Why it came up:** the user asked to be alerted "if someone is listening on a port or
if someone is hacking". The always-on dashboard agent already scanned listeners every
30s — the missing piece was only a persisted baseline to diff against, plus alert rules.
Naming it "Network watch" (not intrusion detection) keeps the promise honest.

**Takeaway:** a monitoring feature is a *diff against a baseline* plus an honest
statement of the sampling blind spots — seed the baseline silently (a day-one alert
storm trains users to ignore the channel), alert on transitions only, and say plainly
what the instrument cannot see.

## macOS banners from a daemon: osascript works, but treat the text as hostile

`osascript -e 'display notification …'` fires real banners from a launchd agent
(spike-verified — and exit 0 alone is not proof; a human confirmed the banner rendered).
The notification text embeds process command names, which any local process chooses for
itself, so the AppleScript string must be escaped backslashes-first-then-quotes or a
crafted name breaks out of the literal.

**Why it came up:** the network watch posts banners naming the listener that triggered
them. The same data flows into the dashboard HTML, where it likewise needs entity
escaping and `data-`-attribute event delegation instead of inline `onclick='…${key}…'`.

**Takeaway:** anything a monitored process can name itself with is untrusted input to
every sink downstream of the monitor — escape per-context (AppleScript, HTML, JS), and
prove the escaping with an injection-shaped test.

## A language embedded in another language's string literal gets its escapes eaten

When JS (or SQL, or a shell command, or a regex) lives inside a Python string, Python's
escape rules run **first**. `\b` becomes a backspace character; `\n` becomes a newline;
`\d` survives only because Python leaves unknown escapes alone. The result compiles and
runs — it just doesn't do what it says.

**Why it came up:** the dashboard's UI is one big Python string. Demo-mode's IP-masking
regexes were written `/\b(?:\d{1,3}\.){3}\d{1,3}\b/` and shipped matching *nothing*,
because both `\b` word boundaries had become 0x08. Text-asserting tests passed happily —
they were grepping the same broken source. Extracting the block and **executing it under
node** exposed it in one run.

**Takeaway:** double every backslash when embedding one language in another's string
literal (or use a raw string), and verify embedded code by *running* it, not by asserting
on its text. A generic "no control characters in the output" check catches the whole class.

## A sabotage that applies is still not proof — check the test can distinguish

Fail-first has two failure modes, not one: the sabotage never applied (the file is
unchanged), or it applied and the test passed anyway because the assertion can't tell the
two states apart.

**Why it came up:** breaking demo mode's stable IP map (`return make(store.size + 1)`
instead of a memoized lookup) left the suite green. The file *had* changed — but with the
map broken, `store.size` is always 0, so every address returned `192.0.2.1`, which
satisfied the "same IP maps to the same fake" assertion by accident. The fix was to also
assert that two *different* IPs get *different* fakes.

**Takeaway:** after a sabotage, confirm the file changed (checksum) AND that the test went
red. A green suite under an applied sabotage means the assertion is decorative — usually
because it checks one direction of an invariant that needs both.

## A port number is not an identity: match the address too

Two sockets can share a port number and have nothing to do with each other. An
*outbound* connection gets an ephemeral local port (macOS: 49152–65535), and long-lived
local tools listen on loopback ports in that same range — so "this connection's local
port equals a port we listen on" is satisfied constantly by traffic flowing the other
way.

**Why it came up:** the network watch flagged five "PUBLIC address connected to you"
alerts, in red, as its most serious finding. Every one was the machine's own HTTPS
traffic to an API. The tell was in the data the whole time: `rport=443`. A client
connecting *to* you uses an ephemeral source port; a remote port of 443 means *you* are
the client. The fix isn't a heuristic on the port, it's the structural fact that a
loopback-only listener cannot receive a connection addressed to a public IP.

**Takeaway:** when joining two observations on an identifier, ask what else must agree
for the join to be meaningful — and prefer a structural impossibility ("this listener
cannot receive that address") over a heuristic ("that port looks like a server"), because
a heuristic can be evaded and a structure cannot.

## Bracket IPv6 host:port, or the port becomes part of the address

`2607:6bc0::10:443` is ambiguous — an IPv6 address is already full of colons, so the
port merges into it and reads as a different, longer address. `[host]:port` exists
precisely to disambiguate.

**Why it came up:** the unbracketed form reached a *published* demo GIF, where the
dashboard's masking layer treated the merged string as its own address and mapped it to
a different placeholder than the same host elsewhere in the row — so one device rendered
as two, and the artifact looked broken to anyone reading carefully.

**Takeaway:** format a compound value at the point it becomes text, using the notation
its spec defines. Anything downstream that pattern-matches the text — a masker, a log
parser, a linkifier — inherits the ambiguity, and the damage surfaces far from the cause.

## Don't fake duration with repetition — encode it, then read it back

An artifact with a time dimension (a GIF, an animation, a generated video) can express
"hold this for three seconds" two ways: repeat the frame at a fixed rate, or store one
frame with an explicit duration. The first is invisible in every file listing and
unfixable without re-deriving the whole thing.

**Why it came up:** the project's demo GIF put each caption on screen for under a second
— unreadable. The recorder had been padding dwell time by capturing the *same* screenshot
8–12 times and playing at a flat 10fps: only 12 of 106 frames were distinct. Switching to
one frame per scene with a per-frame duration made it readable and made the pacing a
tunable number instead of an emergent property of two unrelated constants.

Two things that surprised me and are worth carrying: dropping 90% of the frames did **not**
shrink the file, because identical frames compress to nearly nothing — the bytes were
always the distinct frames. And the fix is one `fps=` filter away from silently reverting,
because a re-encoded GIF with flattened delays looks completely normal.

**Takeaway:** when a property is *supposed* to be explicit, store it explicitly rather than
simulating it with volume — then assert it by reading the property back out of the finished
artifact, not out of the code that generated it. Anything a later edit can flatten without
producing an error needs that read-back check.

## Stage the artifact, publish it only after the gate passes

A verification step that runs *after* the file is already in its published location has
already lost: the broken artifact is on disk, and whether it ships depends on whether
anyone reads the error.

**Why it came up:** the GIF pipeline wrote straight into `docs/` and *then* checked pacing
and privacy. Building to a staging path and moving into place only on success turned the
same checks from advisory into binding — proven by sabotaging the pipeline and confirming
the previously published GIF was left byte-identical.

**Takeaway:** for any generate-then-verify pipeline, the verification must sit between the
generation and the destination, not after both.

## Rebinding a name does not rebind the value already captured

A Python default argument is evaluated **once, at `def` time**. `def save_state(state, path
= STATE_PATH)` copies the `Path` object into `save_state.__defaults__` at import; a later
`setattr(netwatch, "STATE_PATH", tmp)` changes the module attribute and nothing else. The
no-argument call — the only one that can surprise you — keeps writing to the original file.

**Why it came up:** writing the test fixture whose entire job was to stop the suite touching
real state, a `save_state(state)` overwrote the live `netwatch.json`: 262 KB of roster, event
ring, ack decisions and run ledger. The fixture had "redirected" every constant, and the
redirect was real — it just wasn't what that call reads. Recovered from `netwatch.log.jsonl`,
the append-only archive, plus an older snapshot. The same trap covers anything captured at
definition or import time: decorator arguments, closures, class attributes, a config value
read into a module-level singleton.

**Takeaway:** to redirect a path, patch the attribute **and** every function default that
captured it (`fn.__defaults__`), including importers of the constant — then assert the
**outcome** (where a write actually lands), never the constant's new value.

## A test for a destructive behaviour must prove it is safe before performing it

The obvious way to test "an unredirected write escapes the sandbox" is to do the write and
see where it landed. That test passes honestly on correct code and is a loaded gun on broken
code.

**Why it came up:** after fixing the above, the sabotage run that proved the test bites
destroyed the live state file a *second* time — the test detected the fault by performing it.
`~/.claude/lessons.md` already says restoring the file is not restoring the world; this is the
sharper form, because here the suite's own assertion was the destructive act.

**Takeaway:** put a cheap, side-effect-free precondition first (inspect the captured default,
the resolved path, the connection string) and refuse to run the destructive step when it
fails. The failure message then names the real fault, and a sabotage run costs nothing.

## Escaping applied by position drifts; escaping applied by rule does not

`esc()` sat halfway down a 900-line script. Every renderer below it escaped every
interpolation; the four above it escaped none. Nobody decided that — the helper was written
next to the feature that needed it, and later features inherited its position rather than its
rule.

**Why it came up:** those four render plist labels, `apps.json`, `lsof` process names,
directory names, and the `name` field of any `package.json` under a scanned root. Cloning a
repo named `<img src=x onerror=…>` and clicking Scan ran script on the dashboard's own origin
— which can drive every route, including adopt-then-start, which reaches `/bin/zsh -c`.
Verified both ways against the running server: the payload fired on the old build and renders
as text on the new one.

**Takeaway:** move the helper above every consumer and pin the rule as a test that walks each
renderer's interpolations, rather than trusting review. When that test was first written it
sliced on the first `innerHTML` assignment — the empty-state line — so one renderer's slice
was 53 characters and the gate passed while inspecting nothing; anchor a content gate on a
marker unique to the region and make it refuse a slice that fails a sanity check.

## `esc()` cannot rescue a value inside an inline event handler

`onclick="act('${label}')"` puts an untrusted value inside a JS string inside an HTML
attribute. HTML-escaping it is useless: the browser decodes `&#39;` back to `'` *before* the
JS parser sees the attribute, so the quote still closes the string.

**Why it came up:** the fix for the renderers above could not simply be `esc()` everywhere —
half the sites were inline handlers. They became `data-` attributes read by one delegated
listener per static container, which is what the already-escaped watch renderer had been
doing all along.

**Takeaway:** values that drive an action belong in `data-` attributes with a delegated
listener; escaping is for text and quoted attribute positions only. A test that forbids
`on\w+="…${` in a renderer states the rule better than any amount of care.
