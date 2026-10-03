"""The entry point of scripts/loop-authority (task-graph-v1 Phase A, 0a.2).

Run only by that wrapper, as `python3 -I -B <real scripts dir>/loop-authority.py
<args>`. Nothing is written before tools.establish_scratch() has created the
process scratch directory with O_NOFOLLOW on every component (refusing a
symlinked cache path, exit 9); only argument errors and row submissions,
which need no file, are answered before it.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys

EXIT_USAGE = 2
EXIT_ENV = 9
os.umask(0o077)


def fail(code: str, message: str, status: int) -> None:
    print(f"error: {code}: {message}", file=sys.stderr)
    raise SystemExit(status)


def load_loopauth() -> dict:
    """Import lib/loopauth from the lib/ directory beside this file's real
    scripts/ directory. A symlinked or missing lib/, package directory, or
    package entry is refused; nothing else on sys.path can shadow it."""
    real = os.path.realpath(__file__)
    lib = os.path.join(os.path.dirname(os.path.dirname(real)), "lib")
    package = os.path.join(lib, "loopauth")
    for path in (lib, package):
        try:
            info = os.lstat(path)
        except OSError:
            fail("library", f"shared library directory is missing: {path}", EXIT_ENV)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail("library", f"refusing shared library path (symlink or not a directory): {path}",
                 EXIT_ENV)
    for entry in os.scandir(package):
        if entry.is_symlink():
            fail("library", f"refusing shared library path (symlink): {entry.path}", EXIT_ENV)
    sys.dont_write_bytecode = True
    sys.path.insert(0, lib)
    import importlib

    module = importlib.import_module("loopauth")
    if os.path.dirname(os.path.realpath(str(module.__file__))) != package:
        fail("library", f"loopauth resolved outside {package}", EXIT_ENV)
    return {name: importlib.import_module(f"loopauth.{name}")
            for name in ("canonical", "tools", "store", "registry", "recover", "ceremony", "refs")}


def emit(value: dict) -> None:
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))


def exit_for(store, recover, plan, *, verify=False) -> int:
    """0 for a committed store (current_authorization in the JSON says
    whether it authorizes anything: a test lineage never does)."""
    cursor_only = plan.row == "recovery-tidy" and plan.params.get("intent") is None
    if plan.state == "committed" and (plan.row is None or cursor_only):
        return store.EXIT_OK
    if plan.state == "none":
        return store.EXIT_INVALID if verify else store.EXIT_OK
    if plan.state in recover.TERMINAL_STATES:
        return store.EXIT_TERMINAL
    if "pending" in plan.state:
        return store.EXIT_PENDING
    if "quarantined" in plan.state:
        return store.EXIT_QUARANTINED
    if plan.state == "needs-recovery":
        return store.EXIT_PENDING
    return store.EXIT_INVALID


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="loop-authority")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("verify")
    sub.add_parser("recover")
    ceremony_parser = sub.add_parser("ceremony")
    ceremony_parser.add_argument("kind", choices=("genesis", "rotate", "revoke", "regenesis"))
    ceremony_parser.add_argument("--remote")
    ceremony_parser.add_argument("--epoch", type=int)
    submit_parser = sub.add_parser("submit")
    submit_parser.add_argument("row")
    refs_parser = sub.add_parser("refs")
    refs_parser.add_argument("--workspace", required=True)
    refs_parser.add_argument("--run", required=True)
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        return EXIT_USAGE if error.code else 0
    mods = load_loopauth()
    store, tools, registry, recover, ceremony, refs = (mods["store"], mods["tools"], mods["registry"],
                                                       mods["recover"], mods["ceremony"], mods["refs"])
    if args.command == "submit":
        # Admission comes first: a dormant row or approval.consume is refused
        # before anything is created, read, or written.
        try:
            spec = registry.admit(args.row)
        except registry.RowRefused as error:
            status = store.EXIT_CONSUME if error.code == "approval-consume-refused" else (
                store.EXIT_DORMANT if error.dormant else store.EXIT_REFUSED)
            fail(error.code, error.message, status)
        if spec["entry"] == "ceremony":
            fail("exclusion-X6", f"{args.row} is admitted only by `loop-authority ceremony`",
                 store.EXIT_REFUSED)
        fail("exclusion-X7", f"{args.row} has no external entry point", store.EXIT_REFUSED)
    if args.command == "ceremony":
        if args.kind == "genesis" and not args.remote:
            fail("usage", "genesis needs --remote <url>", EXIT_USAGE)
        if args.kind != "genesis" and args.remote is not None:
            fail("usage", "only genesis takes --remote; the remote never changes", EXIT_USAGE)
        if args.kind != "revoke" and args.epoch is not None:
            fail("usage", "only revoke takes --epoch", EXIT_USAGE)
    try:
        if args.command == "refs":
            if os.environ.get("LOOP_AUTHORITY_CRASH_AT") is not None and tools.test_mode():
                fail("crash-point", "refs has no crash points", store.EXIT_REFUSED)
            # Refuse invalid journals/claims before creating scratch directories.
            prepared = refs.prepare_report(args.workspace, args.run)
            tools.establish_scratch()
            result = refs.observe_report(prepared)
            try:
                data = mods["canonical"].canonical(result)
            except mods["canonical"].CanonicalError as error:
                raise refs.RefsError("output", f"the report has no canonical encoding: {error}") from error
            sys.stdout.buffer.write(data + b"\n")
            return store.EXIT_OK
        tools.establish_scratch()
        if args.command == "ceremony":
            result = ceremony.run(args.kind, {"remote": args.remote, "epoch": args.epoch})
            os.write(1, b"\n")
            emit(result)
            return store.EXIT_OK
        if args.command == "recover":
            store.configure_crash("recover")
            with store.WriterLock():
                plan = recover.recover()
            emit(plan.summary())
            return exit_for(store, recover, plan)
        if os.environ.get("LOOP_AUTHORITY_CRASH_AT") is not None and tools.test_mode():
            fail("crash-point", f"{args.command} has no crash points", store.EXIT_REFUSED)
        with store.ReaderLock():
            plan = recover.classify()
        emit(plan.summary())
        if args.command == "status":
            return store.EXIT_OK
        return exit_for(store, recover, plan, verify=True)
    except store.AuthorityError as error:
        print(f"error: {error.code}: {error.message}", file=sys.stderr)
        return error.exit_code
    except registry.RowRefused as error:
        print(f"error: {error.code}: {error.message}", file=sys.stderr)
        return store.EXIT_REFUSED
    except refs.RefsError as error:
        print(f"error: {error.code}: {error.message}", file=sys.stderr)
        return EXIT_USAGE if error.usage else store.EXIT_INVALID
    except tools.ToolError as error:
        print(f"error: {error.code}: {error.message}", file=sys.stderr)
        return EXIT_ENV
    except store.anchor.Unreachable as error:
        print(f"error: pending: {error}", file=sys.stderr)
        return store.EXIT_PENDING
    except store.anchor.AnchorError as error:
        print(f"error: {error.code}: {error.message}", file=sys.stderr)
        return store.EXIT_REFUSED
    except OSError as error:
        print(f"error: environment: {error}", file=sys.stderr)
        return EXIT_ENV
    finally:
        tools.cleanup()


sys.exit(main(sys.argv[1:]))
