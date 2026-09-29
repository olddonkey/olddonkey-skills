"""Framing of the authority log (A1.6).

A frame is  OLF1 <seq> <type> <length> <digest>\\n  + content + \\n, where
<digest> is "sha256:" + hex(sha256(b"OLF1 <seq> <type> <length>" + content))
-- the header without its digest field, then the content -- and <length> is
the content's byte count. The content is canonical({payload, sig})
(records.content_bytes); its digest is the record digest that prev, the
anchor pointer, and the write intent name.

parse_log() splits a log into its leading run of complete, terminated,
digest-valid frames and whatever follows. It never decides what the tail
means: recovery classifies it against the write intent (A1.6, A2.3).

Pure: no I/O, no subprocess.
"""

from __future__ import annotations

import hashlib
import re

MAGIC = b"OLF1"
MAX_HEADER = 160
MAX_CONTENT = 1 << 20
HEADER_RE = re.compile(
    rb"^OLF1 ([1-9][0-9]{0,15}) ([a-z][a-z0-9.-]{0,63}) (0|[1-9][0-9]{0,7}) (sha256:[0-9a-f]{64})$"
)


class FrameError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def header_prefix(seq: int, record_type: str, length: int) -> bytes:
    return f"OLF1 {seq} {record_type} {length}".encode("ascii")


def frame_digest(seq: int, record_type: str, content: bytes) -> str:
    prefix = header_prefix(seq, record_type, len(content))
    return "sha256:" + hashlib.sha256(prefix + content).hexdigest()


def encode(seq: int, record_type: str, content: bytes) -> bytes:
    if type(seq) is not int or seq < 1:
        raise FrameError("frame", "seq must be a positive integer")
    if len(content) > MAX_CONTENT:
        raise FrameError("frame", "content too large")
    if b"\n" in content:
        raise FrameError("frame", "content must not contain a raw newline")
    digest = frame_digest(seq, record_type, content)
    header = header_prefix(seq, record_type, len(content)) + b" " + digest.encode("ascii") + b"\n"
    if len(header) > MAX_HEADER:
        raise FrameError("frame", "header too long")
    if not HEADER_RE.fullmatch(header[:-1]):
        raise FrameError("frame", "header does not match the frame grammar")
    return header + content + b"\n"


class Frame:
    __slots__ = ("seq", "type", "length", "digest", "offset", "header_length", "content", "end")

    def __init__(self, seq: int, record_type: str, length: int, digest: str, offset: int,
                 header_length: int, content: bytes) -> None:
        self.seq = seq
        self.type = record_type
        self.length = length
        self.digest = digest
        self.offset = offset
        self.header_length = header_length
        self.content = content
        self.end = offset + header_length + length + 1

    @property
    def raw_length(self) -> int:
        return self.end - self.offset


def parse_header(line: bytes) -> tuple[int, str, int, str]:
    match = HEADER_RE.fullmatch(line)
    if match is None:
        raise FrameError("header", "header does not parse")
    return (int(match.group(1)), match.group(2).decode("ascii"), int(match.group(3)),
            match.group(4).decode("ascii"))


class LogParse:
    """frames: the leading complete frames (terminated, digest-valid, and
    numbered 1, 2, ...). tail_offset: where the first byte not in them sits.
    tail_error: why parsing stopped at a complete-but-invalid frame, or None
    when the tail is empty or merely short (possibly torn)."""

    __slots__ = ("frames", "tail_offset", "tail", "tail_error")

    def __init__(self) -> None:
        self.frames: list[Frame] = []
        self.tail_offset = 0
        self.tail = b""
        self.tail_error: str | None = None


def parse_log(data: bytes, first_seq: int = 1) -> LogParse:
    result = LogParse()
    offset = 0
    while offset < len(data):
        newline = data.find(b"\n", offset, offset + MAX_HEADER + 1)
        if newline < 0:
            if len(data) - offset > MAX_HEADER:
                result.tail_error = "header line too long"
            break
        line = data[offset:newline]
        try:
            seq, record_type, length, digest = parse_header(line)
        except FrameError:
            result.tail_error = "header does not parse"
            break
        header_length = newline + 1 - offset
        end = newline + 1 + length
        if end + 1 > len(data):
            break  # short: the frame is not complete (maybe unterminated)
        content = data[newline + 1:end]
        if data[end:end + 1] != b"\n":
            result.tail_error = "frame is not terminated by a newline"
            break
        if frame_digest(seq, record_type, content) != digest:
            result.tail_error = "frame digest mismatch"
            break
        if seq != first_seq + len(result.frames):
            result.tail_error = f"frame sequence {seq} out of order"
            break
        result.frames.append(Frame(seq, record_type, length, digest, offset, header_length,
                                   content))
        offset = end + 1
    result.tail_offset = offset
    result.tail = data[offset:]
    return result


def split_frame(frame_bytes: bytes, seq: int) -> Frame:
    """Parse bytes that must be exactly one complete frame numbered seq."""
    parsed = parse_log(frame_bytes, seq)
    if len(parsed.frames) != 1 or parsed.tail or parsed.tail_error:
        raise FrameError("frame", "bytes are not exactly one complete frame")
    return parsed.frames[0]
