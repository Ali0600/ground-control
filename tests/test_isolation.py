"""The redirect in conftest.py is a safety belt; these prove it is buckled.

Written after a `save_state(state)` in a draft of that fixture overwrote the live
`netwatch.json` — the fixture had rebound the module constant, which a
default-argument call never reads. So every assertion here is about WHERE A WRITE
LANDS, never about the value of a constant: setting the constant is the proxy, the
file appearing in the sandbox is the outcome.
"""

from __future__ import annotations

import ast
import inspect
from pathlib import Path

import app as app_pkg
from app import netwatch
from tests.conftest import PATCHED_MODULES, READ_ONLY, REDIRECTED

REPO = Path(__file__).resolve().parent.parent
REAL_LAUNCH_AGENTS = Path.home() / "Library" / "LaunchAgents"


def _defaults_are_redirected() -> bool:
    """Cheap, side-effect-free check that `save_state`'s captured default no longer
    points at a real file."""
    default = netwatch.save_state.__defaults__[0]
    return REPO not in Path(default).parents


def test_a_default_argument_write_lands_in_the_sandbox():
    """`save_state(state)` with no path — the exact call that destroyed the live
    roster on 2026-09-05.

    The guard below is not ceremony. An earlier version of this test detected the
    fault by PERFORMING the write and then checking where it landed — so running the
    suite against a broken fixture destroyed the real file a second time, while
    'proving' the test worked. A test for a destructive behaviour must refuse to run
    the destructive step until it has established, by inspection, that it is safe.
    Restoring the file is not restoring the world."""
    assert _defaults_are_redirected(), (
        "save_state's default still points into the repo — the fixture is not "
        "redirecting function defaults, so this test will NOT perform the write"
    )

    real = REPO / "netwatch.json"
    before = real.read_bytes() if real.exists() else None

    netwatch.save_state({"seeded_at": "2026-01-01T00:00:00+00:00"})

    written = Path(netwatch.STATE_PATH)
    assert written.exists(), "the no-argument write vanished — defaults are not patched"
    assert REPO not in written.parents, f"a default write escaped to {written}"
    written.unlink()

    after = real.read_bytes() if real.exists() else None
    assert after == before, "the suite modified the real netwatch.json"


def test_no_function_default_still_points_at_a_real_path():
    """The trap itself: a path captured in `__defaults__` at def time is invisible to
    `setattr(module, CONST, tmp)`. No default in any patched module may still hold a
    path under the repo or the real LaunchAgents dir."""
    offenders = []
    for mod in PATCHED_MODULES:
        for name, fn in vars(mod).items():
            if not inspect.isfunction(fn) or not fn.__defaults__:
                continue
            for d in fn.__defaults__:
                if not isinstance(d, Path):
                    continue
                if REPO in d.parents or d == REAL_LAUNCH_AGENTS or REAL_LAUNCH_AGENTS in d.parents:
                    offenders.append(f"{mod.__name__}.{name}() default {d}")
    assert not offenders, "unredirected path defaults: " + "; ".join(offenders)


def _app_modules():
    """Every module in the `app` package — derived by walking the package directory,
    NOT a hand-written list. The hand list is what forgets: the first version of this
    test named four modules and missed `launchd.AGENT_DIRS`, which points at the real
    ~/Library/LaunchAgents. A driver that copes with whatever it finds beats a list
    whose newest member is always the one left off."""
    import importlib

    mods = []
    for path in sorted(Path(app_pkg.__file__).parent.glob("*.py")):
        if path.stem == "__init__":
            continue
        mods.append(importlib.import_module(f"app.{path.stem}"))
    return mods


def test_every_path_constant_is_classified():
    """A new module-level `X = Path(...)` (or a list of them) must be either redirected
    — a surface a test can reach — or named in READ_ONLY with a reason. Membership is
    computed from the source and compared WHOLE, so this fails in both directions: an
    unclassified constant AND a stale READ_ONLY entry."""
    covered = {(mod.__name__, attr) for mod, attr in REDIRECTED}
    found = set()
    for mod in _app_modules():
        source = Path(mod.__file__).read_text()
        for node in ast.parse(source).body:  # module scope only
            if not isinstance(node, ast.Assign):
                continue
            target = node.targets[0]
            if not isinstance(target, ast.Name) or not target.id.isupper():
                continue
            if "Path" not in ast.dump(node.value):
                continue
            found.add((mod.__name__, target.id))

    unclassified = found - covered - READ_ONLY
    assert not unclassified, (
        f"path constants neither redirected nor in READ_ONLY: {sorted(unclassified)} — "
        "decide which it is and say why"
    )
    stale = READ_ONLY - found
    assert not stale, f"READ_ONLY names constants that no longer exist: {sorted(stale)}"


def test_agent_discovery_cannot_see_the_real_launchagents():
    """`discover_plists()` with no argument must find nothing: the machine's own jobs
    are not test fixtures, and a route test that forgot to stub would otherwise render
    the user's real agent list."""
    from app import launchd

    assert launchd.discover_plists() == []
