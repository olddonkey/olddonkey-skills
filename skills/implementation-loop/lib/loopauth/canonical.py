"""Canonical JSON and the "sha256:" digest (task-graph-v1 Phase A, section 3.4).

canonical(x) is UTF-8 JSON with object keys sorted by Unicode code point and no
insignificant whitespace. Only these values are admitted: null, true, false,
integers in the interoperable range [-(2**53 - 1), 2**53 - 1], strings that
encode as UTF-8, lists, and objects whose keys are strings. Floats, NaN,
infinities, non-string keys, tuples, and every other type are refused, as is
nesting deeper than MAX_DEPTH. Depth counts nested arrays and objects: a
scalar is depth 0, [] and {} are depth 1, [[1]] is depth 2.

digest(x) = "sha256:" + hex(sha256(canonical(x))).
"""

from __future__ import annotations

import hashlib
import json
import re

MAX_INT = 2**53 - 1
MIN_INT = -(2**53 - 1)
MAX_DEPTH = 64
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


class CanonicalError(ValueError):
    """A value has no canonical encoding."""


def _check(value: object, depth: int) -> None:
    """depth is the number of arrays and objects enclosing value."""
    if value is None or value is True or value is False:
        return
    kind = type(value)
    if kind is int:
        if not MIN_INT <= value <= MAX_INT:
            raise CanonicalError(f"integer out of range: {value}")
        return
    if kind is float:
        raise CanonicalError("floats, NaN, and infinities are refused")
    if kind is str:
        try:
            value.encode("utf-8")
        except UnicodeEncodeError as error:
            raise CanonicalError("string is not encodable as UTF-8") from error
        return
    if kind is list or kind is dict:
        if depth + 1 > MAX_DEPTH:
            raise CanonicalError(f"nesting deeper than {MAX_DEPTH}")
    if kind is list:
        for item in value:
            _check(item, depth + 1)
        return
    if kind is dict:
        for key, item in value.items():
            if type(key) is not str:
                raise CanonicalError(f"non-string key: {key!r}")
            _check(key, depth + 1)
            _check(item, depth + 1)
        return
    raise CanonicalError(f"unsupported type: {kind.__name__}")


def check(value: object) -> None:
    """Raise CanonicalError unless value has a canonical encoding."""
    _check(value, 0)


def canonical(value: object) -> bytes:
    check(value)
    text = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )
    return text.encode("utf-8")


def digest(value: object) -> str:
    return "sha256:" + hashlib.sha256(canonical(value)).hexdigest()


def is_digest(value: object) -> bool:
    return type(value) is str and DIGEST_RE.fullmatch(value) is not None


def _refuse_float(raw: str) -> object:
    raise CanonicalError(f"floats are refused: {raw}")


def _refuse_constant(raw: str) -> object:
    raise CanonicalError(f"non-finite numbers are refused: {raw}")


def _unique_pairs(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, item in pairs:
        if key in result:
            raise CanonicalError(f"duplicate key: {key}")
        result[key] = item
    return result


def loads(text: str) -> object:
    """Parse JSON that has a canonical encoding: no floats, no NaN or
    infinities, no duplicate keys, integers in range. Raises CanonicalError."""
    try:
        value = json.loads(
            text,
            parse_float=_refuse_float,
            parse_constant=_refuse_constant,
            object_pairs_hook=_unique_pairs,
        )
    except CanonicalError:
        raise
    except (ValueError, RecursionError) as error:
        raise CanonicalError(f"invalid JSON: {error}") from error
    check(value)
    return value
