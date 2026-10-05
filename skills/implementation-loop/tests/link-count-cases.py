#!/usr/bin/env python3
"""Link-count cases for the validate_regular copies in the loop scripts.

Usage: link-count-cases.py SCRIPT CASE

SCRIPT is loop-journal, loop-calibration, or loop-console. Its Python body is
loaded without running main, and validate_regular is called directly. Exit 0
means the case held; anything else prints the reason on stderr.

lstat of a path that another process is replacing by rename can report
st_nlink == 0. Whether a given run of the real race hits that window is up to
the kernel, so every case but live-replace substitutes os.lstat to make the
zero count happen on chosen looks. live-replace runs against the real kernel.

Cases:
  replaced-once            zero on the first look, then the real file: accepted
  replaced-repeatedly      zero on the first five looks: accepted
  never-settles            zero on every look: refused after a bounded number
                           of looks, and not as a hard link
  hard-link                a real second link: refused as a hard link
  hard-link-after-replace  zero on the first look, then a real second link:
                           still refused as a hard link
  removed-after-replace    zero on the first look, then no file: missing
  live-replace             another process replaces the file in a tight loop
                           while this one validates it: never refused
"""
import os
import sys
import tempfile
import time

LIVE_SECONDS = 0.5
REAL_LSTAT = os.lstat


def load(script):
    lines = open(script, encoding="utf-8").read().split("\n")
    start = next(i for i, line in enumerate(lines) if line.endswith("<<'PY'")) + 1
    end = max(i for i, line in enumerate(lines) if line == "PY")
    namespace = {"__name__": "loop_script_under_test"}
    exec(compile("\n".join(lines[start:end]) + "\n", script, "exec"), namespace)
    return namespace


class ZeroLinks:
    """A stat result whose link count reads 0."""

    st_nlink = 0

    def __init__(self, real):
        self._real = real

    def __getattr__(self, name):
        return getattr(self._real, name)


class Looks:
    """os.lstat for one path: zero link count on the first `zeros` looks."""

    def __init__(self, path, zeros, after=None):
        self.path = path
        self.zeros = zeros
        self.after = after
        self.count = 0

    def __call__(self, path, *args, **kwargs):
        if path != self.path:
            return REAL_LSTAT(path, *args, **kwargs)
        self.count += 1
        if self.count <= self.zeros:
            return ZeroLinks(REAL_LSTAT(path, *args, **kwargs))
        if self.count == self.zeros + 1 and self.after is not None:
            self.after()
        return REAL_LSTAT(path, *args, **kwargs)


def refusal(validate, path, **kwargs):
    try:
        validate(path, **kwargs)
    except Exception as error:  # the script's own error class
        return str(error), getattr(error, "code", None)
    return None, None


def expect(condition, message):
    if not condition:
        raise SystemExit(message)


def live_replace(validate, directory, target):
    stop_at = time.monotonic() + LIVE_SECONDS
    child = os.fork()
    if child == 0:
        try:
            n = 0
            while time.monotonic() < stop_at:
                temporary = os.path.join(directory, ".tmp-live-%d" % n)
                descriptor = os.open(
                    temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
                )
                os.write(descriptor, b"x\n")
                os.close(descriptor)
                os.replace(temporary, target)
                n += 1
        finally:
            os._exit(0)
    zeros = 0

    def counting(path, *args, **kwargs):
        nonlocal zeros
        info = REAL_LSTAT(path, *args, **kwargs)
        if path == target and info.st_nlink == 0:
            zeros += 1
        return info

    os.lstat = counting
    validations = 0
    try:
        while time.monotonic() < stop_at:
            message, _ = refusal(validate, target)
            expect(
                message is None,
                "refused a file that was being replaced, after %d validations: %s"
                % (validations, message),
            )
            validations += 1
    finally:
        os.lstat = REAL_LSTAT
        os.waitpid(child, 0)
    print("validations=%d zero_link_counts_seen=%d" % (validations, zeros))


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__)
    script, case = argv
    namespace = load(script)
    validate = namespace["validate_regular"]
    attempts = namespace["RESTAT_ATTEMPTS"]
    d4a = namespace["EXIT_D4A"]
    directory = tempfile.mkdtemp(prefix="link-count-")
    target = os.path.join(directory, "target")
    alias = os.path.join(directory, "alias")
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    try:
        if case in {"replaced-once", "replaced-repeatedly"}:
            zeros = 1 if case == "replaced-once" else 5
            expect(zeros < attempts, "case needs more zeros than the bound allows")
            os.lstat = looks = Looks(target, zeros)
            info = validate(target)
            expect(info is not None and info.st_nlink == 1, "did not return the live file")
            expect(looks.count == zeros + 1, "looked %d times" % looks.count)
        elif case == "never-settles":
            os.lstat = looks = Looks(target, 10 ** 9)
            message, code = refusal(validate, target)
            expect(message is not None, "accepted a link count of 0")
            expect(code == d4a, "exit code %r" % code)
            expect("link count stayed at 0" in message, "message: %s" % message)
            expect("hard link" not in message, "reported as a hard link: %s" % message)
            expect(looks.count == attempts, "looked %d times" % looks.count)
        elif case in {"hard-link", "hard-link-after-replace"}:
            os.link(target, alias)
            if case == "hard-link-after-replace":
                os.lstat = Looks(target, 1)
            message, code = refusal(validate, target)
            expect(message is not None, "accepted a hard-linked file")
            expect(code == d4a, "exit code %r" % code)
            expect("multiple hard links" in message, "message: %s" % message)
        elif case == "removed-after-replace":
            os.lstat = Looks(target, 1, after=lambda: os.unlink(target))
            message, code = refusal(validate, target)
            expect(message is not None, "accepted a removed file")
            expect(code == d4a, "exit code %r" % code)
            expect("file is missing" in message, "message: %s" % message)
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
            os.lstat = Looks(target, 1, after=lambda: os.unlink(target))
            expect(
                validate(target, allow_missing=True) is None,
                "allow_missing did not return None",
            )
        elif case == "live-replace":
            live_replace(validate, directory, target)
        else:
            raise SystemExit("unknown case: %s" % case)
    finally:
        os.lstat = REAL_LSTAT
        for name in os.listdir(directory):
            os.unlink(os.path.join(directory, name))
        os.rmdir(directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
