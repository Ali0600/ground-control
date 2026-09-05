"""Test isolation: no test may touch the machine's real state.

Every module below keeps its paths in module-level constants that default to real
files — the live `netwatch.json` baseline, the user's `apps.json`, and
`~/Library/LaunchAgents`. Each function takes an explicit path argument, so the
existing tests pass one and nothing was clobbered. Nothing ENFORCED that, and on
2026-09-05 a single `save_state(state)` with no path argument overwrote a roster
built up since 2026-08-07. (Recovered from `netwatch.log.jsonl` — which is exactly
why that archive is append-only and uncapped.)

**Rebinding the module attribute is NOT enough, and that is the whole subtlety
here.** These functions capture the path as a DEFAULT ARGUMENT:

    def save_state(state: dict, path: Path = STATE_PATH) -> None:

Defaults are evaluated once, at def time, so `setattr(netwatch, "STATE_PATH", tmp)`
leaves `save_state.__defaults__` still holding the original real Path — the
no-argument call, the only dangerous one, is precisely the call that rebinding
misses. So we patch the module attribute AND every function default that captured
it, and `test_isolation.py` asserts the OUTCOME (where a write actually lands)
rather than the value of the constant.
"""

from __future__ import annotations

import inspect
from pathlib import Path

import pytest

from app import annotations, apps, discover, launchd, netwatch

# (module, attribute) for every module-scope path constant. A value may be a single
# Path or a LIST of them (launchd.AGENT_DIRS); both are redirected into the sandbox.
# `test_every_path_constant_is_classified` re-derives this from the source, so a
# constant added later fails the suite instead of quietly reaching a real file.
REDIRECTED = (
    (netwatch, "STATE_PATH"),
    (netwatch, "ARCHIVE_PATH"),
    (apps, "CONFIG_PATH"),
    (apps, "LAUNCH_AGENTS_DIR"),
    (apps, "LOG_DIR"),
    (annotations, "LABELS_PATH"),
    # The real ~/Library/LaunchAgents and /Library/LaunchAgents. Redirected rather than
    # merely allowed, so `discover_plists()` sees an empty dir instead of the machine's
    # actual jobs — that also gives route tests somewhere to drop fixture plists.
    (launchd, "AGENT_DIRS"),
)

# Modules whose function defaults may have captured one of the paths above. `discover`
# is included because it imports CONFIG_PATH from apps and defaults
# `adopt_apps(config=…)` to it — an importer captures the value just as its owner does.
PATCHED_MODULES = (annotations, apps, netwatch, discover, launchd)

# Path constants that are deliberately NOT redirected, each with the reason. These are
# READ surfaces: the risk is a slow, machine-coupled scan, not a destroyed file. Naming
# them is the point — `test_every_path_constant_is_classified` fails on a constant that
# is in neither list, so a new one must be judged rather than silently ignored, and it
# fails on a stale entry here too, so this list cannot outlive the code.
READ_ONLY = {
    # The 9 project roots discover scans. Every caller in the suite passes `roots=`
    # explicitly, and test_discover asserts this list's own contents, so redirecting it
    # would break the test that documents it. A test that calls `discover_apps()` with
    # no roots would walk the real home — slow and machine-dependent, not destructive.
    ("app.discover", "CANDIDATE_ROOTS"),
}


def _redirect_defaults(module, mapping: "dict[Path, Path]") -> list:
    """Rewrite any function default in `module` that is one of the real paths.

    Returns undo records. Functions only — no module here defines a class carrying a
    path default (a dataclass field would need the same treatment)."""
    undo = []
    for _name, fn in vars(module).items():
        if not inspect.isfunction(fn) or not fn.__defaults__:
            continue
        new = tuple(mapping.get(d, d) if isinstance(d, Path) else d for d in fn.__defaults__)
        if new != fn.__defaults__:
            undo.append((fn, fn.__defaults__))
            fn.__defaults__ = new
    return undo


@pytest.fixture(autouse=True, scope="session")
def _redirect_state(tmp_path_factory):
    """Point every real-file constant — and every default that captured one — at a
    throwaway directory, for the whole session."""
    sandbox = tmp_path_factory.mktemp("state")
    mapping: dict = {}
    saved_attrs = []
    for mod, attr in REDIRECTED:
        original = getattr(mod, attr)
        target = sandbox / mod.__name__.rsplit(".", 1)[-1] / attr.lower()
        target.parent.mkdir(parents=True, exist_ok=True)
        saved_attrs.append((mod, attr, original))
        if isinstance(original, list):
            # A search path (AGENT_DIRS): one real sandbox dir replaces every entry, and
            # each original still maps to it so a captured default is caught too.
            target.mkdir(parents=True, exist_ok=True)
            for entry in original:
                mapping[Path(entry)] = target
            setattr(mod, attr, [target])
        else:
            mapping[Path(original)] = target
            setattr(mod, attr, target)

    undo: list = []
    for mod in PATCHED_MODULES:
        undo += _redirect_defaults(mod, mapping)

    yield sandbox

    for fn, defaults in undo:
        fn.__defaults__ = defaults
    for mod, attr, original in saved_attrs:
        setattr(mod, attr, original)
