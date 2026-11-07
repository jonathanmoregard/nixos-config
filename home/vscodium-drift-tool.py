"""VSCodium settings drift: the pre-merge recorder and the hourly report.

Both halves live here, sharing ONE leaf-diff, because the recorder and the
report must never disagree about what counts as drift. Two copies of this
comparison would let the hourly report call a key clean that the merge had
just discarded, which is the "looks observed, isn't" failure this repo
keeps naming.

WHY A RECORDER EXISTS

home-manager's `programs.vscodium.profiles.<p>.mutableUserSettings` merges
declared settings over whatever is live. The merge is `$dynamic * $static`,
so DECLARED WINS: a setting changed in the Settings UI that is ALSO
declared in home/vscodium.nix is silently reverted on the next deploy with
no trace anywhere. That is the same silent-loss class as the `force = true`
this change replaced. jq's `*` is worse than it looks for arrays — it
replaces them wholesale, so one added `textMateRules` entry discards the
declared list's siblings and then loses the addition too.

The evidence only exists BEFORE the merge runs, so this records it there.
Afterwards live == declared for every overlapping key and the hourly probe
can see nothing.

Keys live but NOT declared are the opposite case: the merge preserves them
across reboot and deploy, which is the whole point of the mutable layer.
They are reported as the promotion queue.

WHAT THIS TOOL NEVER DOES

It never moves, rewrites or deletes the live settings file. An earlier
draft quarantined a file it could not parse, so that home-manager's
`exit 1` could not poison the deploy SHA. That is the wrong trade twice
over: the deploy is protected at the activation-entry level instead (see
home/vscodium.nix), and quarantining a file mid-edit during an unattended
webhook deploy is itself silent loss. An unparseable file is recorded and
left exactly where it is.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys

try:
    import json5
except ModuleNotFoundError:  # pragma: no cover - packaging error only
    json5 = None

# Bounded so a user who edits settings in the UI for years cannot grow
# this without limit; oldest first_seen is dropped.
MAX_RECORDED_OVERRIDES = 200

# Leaf paths whose declared value is a /nix/store path, or which an
# extension rewrites on its own schedule. Reporting these would fire on
# every rebuild without anything having drifted.
IGNORED_PREFIXES = (
    # Only the one claudeCode key whose declared value is a store path, NOT
    # the subtree. `claudeCode.` used to be ignored wholesale, which hid the
    # extension's own permission settings -- a live
    # `claudeCode.allowDangerouslySkipPermissions: true` or
    # `claudeCode.initialPermissionMode: "bypassPermissions"` is undeclared,
    # so the merge PRESERVES it, so it would have outlasted every deploy
    # while never appearing in a report. Found in review.
    "claudeCode.claudeProcessWrapper",
    "rust-analyzer.server.path",
    "nix.serverPath",
)

# Leaf paths where a wrong value silently removes a guard instead of
# changing an appearance: what is allowed to run, and what gets verified.
#
# Every one of these is declared in home/vscodium.nix, so the merge reverts
# a live edit to it. This list is for the keys that are NOT -- a sibling
# setting, a new one from an editor upgrade, one an extension introduces.
# Those are preserved by the merge and outlast reboot and deploy, exactly
# like a cosmetic key, which is why they are reported apart from it:
# "undeclared colour theme" and "undeclared workspace-trust switch" are
# the same shape on disk and nothing like the same finding.
#
# Prefix-matched, so `security.` covers a key that does not exist yet. Erring
# wide is the right error: `security.` and `telemetry.` also sweep in a few
# cosmetic toggles (`security.workspace.trust.banner`,
# `telemetry.feedback.enabled`), which costs one over-escalated line in a
# report, while a missed prefix costs a guard nobody is told about.
SENSITIVE_PREFIXES = (
    "security.",
    "task.allowAutomaticTasks",
    "extensions.autoUpdate",
    "extensions.autoCheckUpdates",
    "extensions.supportUntrustedWorkspaces",
    "git.allowNoVerifyCommit",
    "git.confirmNoVerifyCommit",
    "git.allowForcePush",
    "git.confirmForcePush",
    "http.proxy",
    "telemetry.",
    # Auto-approving an agent's tool calls from the editor's own settings.
    # The whole `chat.tools.` subtree, not a single key: the editor spells
    # these `chat.tools.global.autoApprove`,
    # `chat.tools.terminal.autoApprove`, `chat.tools.edits.autoApprove` and
    # `chat.tools.terminal.enableAutoApprove` (verified against the deployed
    # 1.143 build), and the set has been renamed at least once already.
    "chat.tools.",
    # The Claude Code extension's own permission settings. `bypassPermissions`
    # is one of initialPermissionMode's enum values, and
    # allowDangerouslySkipPermissions is the switch that admits it.
    # environmentVariables is listed because it sets the env of the spawned
    # claude process.
    "claudeCode.allowDangerouslySkipPermissions",
    "claudeCode.initialPermissionMode",
    "claudeCode.environmentVariables",
)


class SettingsUnparseable(Exception):
    """The live file's CONTENT is bad.

    Distinct from every other failure — a missing json5 in our own
    closure, an unreadable path, a bug in here — because the remedy is
    opposite. A bad file is the user's to fix and must be reported as
    such; our own fault must not be dressed up as theirs. An earlier draft
    conflated them and reported a perfectly valid settings.json as broken.
    """


def render_path(parts: list[str]) -> str:
    """Render a leaf path for humans.

    VS Code setting keys contain dots of their own (`editor.formatOnSave`),
    so joining with "." would be ambiguous the moment a language block
    nests one. Arrow-joined components stay unambiguous:
    `[html] -> editor.formatOnSave`.
    """
    return " -> ".join(parts)


def canonical(path: str) -> str:
    """A rendered path as VS Code's own dotted key.

    `render_path` arrow-joins components so a nested key stays unambiguous
    for a human reader, but every prefix in the two lists below is spelled
    the way VS Code spells a setting — with dots. Matching the rendered form
    against them silently fails for anything nested: VS Code's config parser
    honours `{"security": {"workspace.trust.enabled": false}}`, which renders
    as `security -> workspace.trust.enabled`, and that does not start with
    `security.`. Both prefix checks therefore match on this form instead.
    """
    return path.replace(" -> ", ".")


def is_ignored(parts: list[str]) -> bool:
    return canonical(render_path(parts)).startswith(IGNORED_PREFIXES)


def is_ignored_path(path: str) -> bool:
    """is_ignored for an already-rendered leaf path."""
    return canonical(path).startswith(IGNORED_PREFIXES)


def is_sensitive(path: str) -> bool:
    """Whether a rendered leaf path names a guard rather than an appearance."""
    return canonical(path).startswith(SENSITIVE_PREFIXES)


def flatten_leaves(value, parts: list[str] | None = None) -> dict:
    """Every leaf of a settings object, keyed by its rendered path.

    Not expressible as `diff(value, {})`: an absent counterpart stops that
    walk at the first level and hands back whole subtrees, so a nested
    promotion would never retire its override record.
    """
    parts = parts or []
    if isinstance(value, dict) and value:
        out: dict = {}
        for key, child in value.items():
            out.update(flatten_leaves(child, parts + [key]))
        return out
    return {render_path(parts): value}


def diff(live: dict, declared: dict, parts: list[str] | None = None) -> list[dict]:
    """Classify every leaf where live and declared disagree.

    Mirrors the merge's deep-merge semantics: a dict on both sides
    recurses, so a user's extra nested key under `"[html]"` is reported on
    its own rather than dragging its declared siblings in with it. Arrays
    are leaves, which matches jq `*` replacing them wholesale.

    kind:
      undeclared — live has it, declared does not. Survives the merge.
      overridden — both have it and they differ. About to be reverted.

    KNOWN LIMITATION, deliberate: a declared key the user DELETES in the UI
    is not detected. Absent-from-live and never-written-to-live are the
    same state on disk, so reporting deletions would need a snapshot of the
    last merged file, and without one every declared key floods in as a
    deletion the first time the live file is sparse — which is exactly what
    VSCodium leaves after a settings reset. The flood is worse than the
    missing signal: a declared key cannot be removed from the UI anyway,
    since the merge re-asserts it, so removing it from home/vscodium.nix is
    the only path that works and it is a PR either way.
    """
    parts = parts or []
    out: list[dict] = []

    for key, live_value in live.items():
        here = parts + [key]
        if is_ignored(here):
            continue
        if key not in declared:
            out.append({"path": render_path(here), "kind": "undeclared",
                        "value": live_value, "parts": here})
            continue
        declared_value = declared[key]
        if isinstance(live_value, dict) and isinstance(declared_value, dict):
            out.extend(diff(live_value, declared_value, here))
        elif live_value != declared_value:
            out.append({"path": render_path(here), "kind": "overridden",
                        "value": live_value, "declared": declared_value})

    return out


def load_declared(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def load_live(path: str) -> dict:
    """Parse the live file as JSON5.

    VSCodium's own writes are valid JSON, but the Settings UI preserves
    JSONC comments once a hand-edit introduces them. An empty or
    whitespace-only file is `{}` — what VSCodium leaves after a reset, and
    not a parse error.
    """
    if json5 is None:
        raise RuntimeError("json5 module missing from the tool's closure")
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if not text.strip():
        return {}
    try:
        parsed = json5.loads(text)
    except Exception as exc:  # noqa: BLE001 - json5 raises several types
        raise SettingsUnparseable(str(exc)) from exc
    if not isinstance(parsed, dict):
        raise SettingsUnparseable("settings.json did not parse to an object")
    return parsed


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec="seconds"
    )


def state_paths(state_dir: str) -> dict[str, str]:
    return {
        "overridden": os.path.join(state_dir, "overridden.json"),
        "unparseable": os.path.join(state_dir, "unparseable.json"),
        "internal_error": os.path.join(state_dir, "internal-error.json"),
        # Written by the activation entry, not by this tool: the merge
        # itself failing is a condition only its caller observes.
        "merge_failed": os.path.join(state_dir, "merge-failed.json"),
    }


def read_json_dict(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_json(path: str, payload) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def drop_marker(path: str) -> None:
    if os.path.exists(path):
        os.remove(path)


def cmd_record(args) -> int:
    """Never fails. Activation runs this, and on this host a failed
    home-manager activation poisons the deploy SHA — so our own bugs are
    recorded for the hourly report to surface, not raised."""
    paths = state_paths(args.state_dir)
    try:
        rc = _record(args, paths)
    except Exception as exc:  # noqa: BLE001 - deliberately total
        try:
            write_json(paths["internal_error"], {
                "failed_at": now(),
                "error": f"{type(exc).__name__}: {exc}",
            })
        except OSError:
            pass
        print(
            f"vscodium-drift: recorder failed ({type(exc).__name__}: {exc}); "
            f"{args.live} left untouched.",
            file=sys.stderr,
        )
        return 0
    drop_marker(paths["internal_error"])
    return rc


def _record(args, paths) -> int:
    if not os.path.exists(args.live):
        # Nothing live yet: the merge writes the declared set itself.
        drop_marker(paths["unparseable"])
        return 0

    declared = load_declared(args.declared)

    try:
        live = load_live(args.live)
    except SettingsUnparseable as exc:
        write_json(paths["unparseable"], {
            "seen_at": now(),
            "path": args.live,
            "reason": str(exc),
        })
        print(
            f"vscodium-drift: {args.live} does not parse ({exc}); left in "
            "place, nothing recorded this activation.",
            file=sys.stderr,
        )
        return 0

    drop_marker(paths["unparseable"])

    recorded = read_json_dict(paths["overridden"])
    stamp = now()

    for entry in diff(live, declared):
        if entry["kind"] == "undeclared":
            continue
        path = entry["path"]
        discarded = entry.get("value", "<absent>")
        existing = recorded.get(path)
        if existing and existing.get("discarded") == discarded:
            existing["last_seen"] = stamp
            existing["count"] = existing.get("count", 1) + 1
        else:
            recorded[path] = {
                "first_seen": stamp,
                "last_seen": stamp,
                "count": 1,
                "kind": entry["kind"],
                "discarded": discarded,
            }

    # Retirement, which is what closes the loop: once the declared value
    # equals what was discarded, the setting was promoted into
    # home/vscodium.nix and the record has done its job.
    flat_declared = flatten_leaves(declared)
    for path in list(recorded):
        if path in flat_declared and flat_declared[path] == recorded[path]["discarded"]:
            del recorded[path]

    if len(recorded) > MAX_RECORDED_OVERRIDES:
        oldest = sorted(recorded, key=lambda k: recorded[k]["first_seen"])
        for path in oldest[: len(recorded) - MAX_RECORDED_OVERRIDES]:
            del recorded[path]

    write_json(paths["overridden"], recorded)
    return 0


def finding(heading: str, details: str) -> str:
    return f"## {heading}\n\n~~~text\n{details}\n~~~\n\n"


def cmd_report(args) -> int:
    paths = state_paths(args.state_dir)
    findings: list[str] = []

    merge_failed = read_json_dict(paths["merge_failed"])
    if merge_failed:
        findings.append(finding(
            "VSCodium settings merge failed at activation",
            f"at:    {merge_failed.get('failed_at', '?')}\n"
            f"status: {merge_failed.get('status', '?')}\n\n"
            "Declared settings were NOT applied and the live file was left "
            "as it was. Inspect: journalctl --user -u "
            "home-manager-$USER.service",
        ))

    unparseable = read_json_dict(paths["unparseable"])
    if unparseable:
        findings.append(finding(
            "VSCodium settings file does not parse",
            f"path:   {unparseable.get('path', '?')}\n"
            f"at:     {unparseable.get('seen_at', '?')}\n"
            f"reason: {unparseable.get('reason', '?')}\n\n"
            "The file was left in place. Fix the syntax; until then no "
            "override is recorded and the merge cannot apply.",
        ))

    internal = read_json_dict(paths["internal_error"])
    if internal:
        findings.append(finding(
            "VSCodium drift recorder failed during activation",
            f"at:    {internal.get('failed_at', '?')}\n"
            f"error: {internal.get('error', '?')}\n\n"
            "Settings were left untouched, so nothing was lost — but no "
            "override was recorded this activation.",
        ))

    if os.path.exists(args.live) and os.path.exists(args.declared):
        try:
            live = load_live(args.live)
            declared = load_declared(args.declared)
        except SettingsUnparseable as exc:
            # NOT "already reported above, or will be next activation". The
            # marker is written by `record`, which only runs at activation,
            # and this reporter is the only thing that runs between deploys
            # (hourly, from home/drift-analyzer.nix). A file broken after the
            # last deploy therefore has no marker, and trusting one printed
            # zero findings while being unable to read the file at all --
            # the one output shape that reads as "nothing to see here".
            #
            # Deduplicated against the marker rather than emitted
            # unconditionally: when activation DID see it, the marker and
            # this failed read are two sightings of one broken file, and a
            # doubled heading would read as two separate problems. Reporting
            # stays read-only -- recording state is `record`'s job, and the
            # hourly probe writing activation markers would invert that.
            if not unparseable:
                findings.append(finding(
                    "VSCodium settings file does not parse",
                    f"path:   {args.live}\n"
                    f"at:     {now()}\n"
                    f"reason: {exc}\n\n"
                    "Seen by the hourly check, not at activation: the file "
                    "parsed when it was last deployed and does not now. The "
                    "file was left in place. Fix the syntax; until then no "
                    "override is recorded and the merge cannot apply.",
                ))
        except Exception as exc:  # noqa: BLE001
            findings.append(finding(
                "VSCodium settings could not be compared",
                f"{args.live}: {type(exc).__name__}: {exc}",
            ))
        else:
            # A whole undeclared SUBTREE arrives as one entry holding a dict
            # (diff only recurses where both sides have the key), so it is
            # expanded to leaves here before anything classifies it. VS Code's
            # config parser honours the nested spelling, and `security` does
            # not start with `security.` -- so a live file written as
            # {"security": {"workspace.trust.enabled": false}} would otherwise
            # be filed as one cosmetic promotion candidate named `security`.
            # Found in review.
            undeclared: list[str] = []
            for entry in diff(live, declared):
                if entry["kind"] != "undeclared":
                    continue
                value = entry["value"]
                if isinstance(value, dict) and value:
                    undeclared.extend(
                        leaf for leaf in flatten_leaves(value, entry["parts"])
                        if not is_ignored_path(leaf)
                    )
                else:
                    undeclared.append(entry["path"])
            sensitive = sorted(p for p in undeclared if is_sensitive(p))
            ordinary = sorted(p for p in undeclared if not is_sensitive(p))
            if sensitive:
                findings.append(finding(
                    "VSCodium security settings live but not declared",
                    "\n".join(sensitive)
                    + "\n\nSet live, and the merge PRESERVES them, so they "
                    "outlast reboot and deploy. Keys under these prefixes "
                    "decide what is allowed to run or what gets verified, not "
                    "how the editor looks. Declare them in home/vscodium.nix "
                    "so the declared value wins every deploy, or clear them "
                    "in the UI.",
                ))
            if ordinary:
                findings.append(finding(
                    "VSCodium settings live but not declared",
                    "\n".join(ordinary)
                    + "\n\nThese survive reboot and deploy but not a fresh "
                    "install. Promote by adding to home/vscodium.nix in "
                    "nixos-config; the finding clears once declared.",
                ))

    recorded = read_json_dict(paths["overridden"])
    if recorded:
        lines = [
            f"{path}  ({entry.get('kind', '?')}, discarded "
            f"{entry.get('count', 1)}x, first {entry.get('first_seen', '?')})"
            for path, entry in sorted(recorded.items())
        ]
        findings.append(finding(
            "VSCodium settings overwritten by the declared config",
            "\n".join(lines)
            + "\n\nChanged live and reverted at activation because "
            "home/vscodium.nix declares them and declared wins. Change the "
            "declaration in nixos-config, or stop editing them in the UI.",
        ))

    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write("".join(findings))

    print(len(findings))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="vscodium-drift-tool")
    sub = parser.add_subparsers(dest="command", required=True)

    for name, handler in (("record", cmd_record), ("report", cmd_report)):
        child = sub.add_parser(name)
        child.add_argument("--live", required=True)
        child.add_argument("--declared", required=True)
        child.add_argument("--state-dir", required=True)
        if name == "report":
            child.add_argument("--out")
        child.set_defaults(handler=handler)

    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
