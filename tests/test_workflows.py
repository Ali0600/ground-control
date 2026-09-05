"""Guards on the CI workflow itself.

These exist because a workflow edit can disable a gate while every code test stays
green — the failure is invisible until a PR cannot merge, or worse, until a broken one
can. Each test below is a rule that bit once.
"""

from __future__ import annotations

from pathlib import Path

import yaml

CI = Path(__file__).resolve().parent.parent / ".github" / "workflows" / "ci.yml"

# The context the `main: require green PR` ruleset requires. Changing this string means
# changing the ruleset in the GitHub UI too — which is exactly the coupling this pins.
REQUIRED_CHECK = "Lint + test"


def workflow() -> dict:
    return yaml.safe_load(CI.read_text())


def test_a_job_still_carries_the_required_check_name():
    """The branch ruleset requires a status check named exactly "Lint + test". A job
    name is a string that refactors freely, and the coupling lives in the GitHub UI
    where no diff shows it: adding the 3.9/3.12 matrix renamed the only job to
    "Lint + test (py3.9)", so the required check could never report again and every
    PR became unmergeable with nothing red to explain why."""
    names = {job.get("name") for job in workflow()["jobs"].values()}
    assert REQUIRED_CHECK in names, (
        f"no job is named {REQUIRED_CHECK!r} — the branch ruleset requires that exact "
        f"context, so merges would block forever. Jobs present: {sorted(n for n in names if n)}"
    )


def test_the_required_check_fails_closed_when_the_matrix_fails():
    """The gate aggregates the matrix, so it must (a) depend on it, (b) run even when
    the matrix fails, and (c) assert success rather than merely existing.

    Without `if: always()` a failed matrix leaves the gate SKIPPED — and a skipped
    required check does not block a merge, so the gate would pass a red build through.
    """
    gate = next(j for j in workflow()["jobs"].values() if j.get("name") == REQUIRED_CHECK)
    assert gate.get("needs"), "the gate must depend on the matrix job"
    assert gate.get("if") == "always()", (
        "without if: always() a failed matrix SKIPS the gate, and a skipped required "
        "check does not block the merge"
    )
    body = " ".join(step.get("run", "") for step in gate["steps"])
    assert "success" in body, "the gate must assert the matrix result, not just run"


def test_the_matrix_still_runs_the_lowest_supported_python():
    """run.sh builds the dev venv from macOS's system python3 (3.9) and ruff targets
    py39, but for a long time CI ran only 3.12 — so 3.10+ syntax that ruff's selected
    rules do not reject could merge green and break the dev machine on next run."""
    versions = {str(v) for v in workflow()["jobs"]["test"]["strategy"]["matrix"]["python-version"]}
    ruff_target = (CI.parent.parent.parent / "ruff.toml").read_text()
    assert "3.9" in versions, f"CI must exercise 3.9, not just lint for it (has {versions})"
    assert 'target-version = "py39"' in ruff_target, (
        "ruff's target and the CI matrix floor must agree — if the floor moved, move both"
    )


def test_node_is_installed_rather_than_assumed():
    """tests/test_page.py EXECUTES the demo-mode scrub block under node and asserts node
    is present instead of skipping (a skip would silently disarm a privacy gate). It
    passed for months only because the runner image happens to ship node."""
    steps = workflow()["jobs"]["test"]["steps"]
    assert any("setup-node" in str(s.get("uses", "")) for s in steps), (
        "test_page.py hard-requires node; install it rather than relying on the image"
    )


def test_third_party_actions_are_sha_pinned():
    """A tag is mutable: whoever controls it controls what runs in CI, with no review in
    the loop. Checked across EVERY workflow, not just ci.yml — the rule used to be
    applied to this file alone, and preflight.yml sat on `@main` for a third-party action
    holding `pull-requests: write` and `security-events: write`.

    First-party `actions/*` are pinned too, since Dependabot bumps the SHAs anyway."""
    unpinned = []
    for path in sorted(CI.parent.glob("*.yml")):
        wf = yaml.safe_load(path.read_text())
        for job in wf.get("jobs", {}).values():
            for step in job.get("steps", []):
                uses = step.get("uses")
                if uses and "@" in uses:
                    ref = uses.split("@", 1)[1]
                    if not (len(ref) == 40 and all(c in "0123456789abcdef" for c in ref)):
                        unpinned.append(f"{path.name}: {uses}")
    assert unpinned == [], f"actions pinned to a mutable ref: {unpinned}"


def test_every_workflow_declares_least_privilege_permissions():
    """Without an explicit block a workflow inherits the repository default, which can be
    write-all. Each workflow states what it needs."""
    for path in sorted(CI.parent.glob("*.yml")):
        wf = yaml.safe_load(path.read_text())
        job_perms = [j.get("permissions") for j in wf.get("jobs", {}).values()]
        assert wf.get("permissions") or all(job_perms), (
            f"{path.name} declares no permissions: block"
        )


def test_no_workflow_interpolates_event_data_into_a_run_step():
    """`${{ github.event.* }}` inside `run:` is a shell injection: the value is pasted
    into the script before bash sees it. Assign it to an `env:` var and quote it."""
    import re

    offenders = []
    for path in sorted(CI.parent.glob("*.yml")):
        wf = yaml.safe_load(path.read_text())
        for job in wf.get("jobs", {}).values():
            for step in job.get("steps", []):
                body = step.get("run")
                if body and re.search(r"\$\{\{\s*github\.event\.", body):
                    offenders.append(f"{path.name}: {step.get('name') or body[:40]}")
    assert not offenders, f"event data interpolated into run: {offenders}"


# --------------------------------------------------------------------------- #
# Dependabot
# --------------------------------------------------------------------------- #
DEPENDABOT = CI.parent.parent / "dependabot.yml"


def test_dependabot_is_security_updates_only():
    """A deliberate policy: routine version bumps are off, so a Dependabot PR means a CVE
    and nothing else. `open-pull-requests-limit: 0` is GitHub's documented switch —
    security updates come from the repo's alerts, not from this file, so they survive."""
    cfg = yaml.safe_load(DEPENDABOT.read_text())
    for entry in cfg["updates"]:
        assert entry.get("open-pull-requests-limit") == 0, (
            f"{entry['package-ecosystem']}: routine version bumps are on — "
            "set open-pull-requests-limit: 0"
        )


def test_no_dependabot_entry_sets_target_branch():
    """`target-branch` SILENTLY disables security updates for that ecosystem — the one
    change here that turns the whole thing off while still looking configured."""
    cfg = yaml.safe_load(DEPENDABOT.read_text())
    for entry in cfg["updates"]:
        assert "target-branch" not in entry, (
            f"{entry['package-ecosystem']}: target-branch disables security updates"
        )
