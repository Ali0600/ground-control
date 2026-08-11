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
