#!/usr/bin/env python3
#
# Deterministic byte-level mutator for the Arrow IPC decode fuzzer (issue #214).
# The sibling of test/parquet_mutate.py, aimed at what a hand-rolled FlatBuffers
# and Arrow IPC reader gets wrong rather than at uniform byte coverage.
#
# Every mutant is a pure function of (seed file, seed integer), so a crash
# reproduces exactly from the two values printed with it. Nothing is random at
# run time.
#
# An Arrow IPC stream is a sequence of messages, each framed as a 0xFFFFFFFF
# continuation, a 4-byte little-endian metadata length, a FlatBuffers metadata
# block, then a body. The reader trusts that length to find the FlatBuffer, and
# trusts offsets, vector lengths and RecordBatch buffer offset/length pairs inside
# it; those are the fields with leverage. The generic byte mutations are shared in
# spirit with the Parquet mutator; the Thrift, PAR1-footer and deep-Thrift-chain
# mutations do not apply here and are replaced by the two IPC-framing ones.
#
# Usage:  python3 test/arrow_mutate.py SEEDFILE SEED OUTFILE
#
import os
import random
import struct
import sys

# Values that break arithmetic on a field the reader treats as a size, count or
# offset: zero, the negatives, the signed and unsigned ceilings, and the ones
# that overflow a 32-bit multiply by a small element width.
EXTREMES = [
    0, 1, -1, 2, -2,
    0x7F, 0x80, 0xFF,
    0x7FFF, 0x8000, 0xFFFF,
    0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
    0x40000000, 0x20000000, 0x10000000,
]

CONT = b"\xff\xff\xff\xff"


def _flip_bits(b, rnd):
    """Classic bit flips: the only mutation that reaches deep into a value buffer
    where structure is opaque to us."""
    n = rnd.randint(1, 16)
    for _ in range(n):
        i = rnd.randrange(len(b))
        b[i] ^= 1 << rnd.randrange(8)


def _extreme_int(b, rnd):
    """Overwrite a 4- or 8-byte little-endian window with a boundary value.
    FlatBuffers offsets and vector lengths are 4 bytes and RecordBatch buffer
    offset/length pairs are 8, so an unaligned scattershot hits all three."""
    width = rnd.choice((4, 4, 4, 8))
    if len(b) < width:
        return
    i = rnd.randrange(len(b) - width + 1)
    v = rnd.choice(EXTREMES)
    b[i:i + width] = struct.pack("<q" if width == 8 else "<i",
                                 v if v < 0x80000000 or width == 8 else v - 0x100000000)


def _meta_len(b, rnd):
    """Overwrite the 4-byte metadata length that follows a 0xFFFFFFFF
    continuation. The reader seeks by it to find the FlatBuffer and to skip to the
    body, so it is the Arrow analogue of the Parquet footer length: the single
    field with the most leverage over where parsing lands."""
    starts = []
    i = b.find(CONT)
    while i != -1:
        starts.append(i)
        i = b.find(CONT, i + 1)
    if not starts:
        return
    at = rnd.choice(starts) + 4
    if at + 4 > len(b):
        return
    v = rnd.choice(EXTREMES + [len(b), len(b) - at, len(b) * 2])
    b[at:at + 4] = struct.pack("<I", v & 0xFFFFFFFF)


def _continuation(b, rnd):
    """Corrupt a continuation marker itself, or the end-of-stream that is a
    0xFFFFFFFF followed by a zero length. Proves the read loop checks the framing
    rather than trusting the stream to be well formed to its end."""
    starts = []
    i = b.find(CONT)
    while i != -1:
        starts.append(i)
        i = b.find(CONT, i + 1)
    if not starts:
        return
    at = rnd.choice(starts)
    b[at:at + 4] = bytes(rnd.randrange(256) for _ in range(4))


def _truncate(b, rnd):
    """A short read is the commonest malformed file in the wild, and every bound
    in the reader has to hold when the bytes simply stop."""
    if len(b) < 16:
        return
    keep = rnd.randrange(4, len(b))
    del b[keep:]


def _splice(b, rnd):
    """Duplicate a byte range in place. Across message framing this can repeat a
    metadata or body region, so counts and offsets that were consistent no longer
    are."""
    if len(b) < 32:
        return
    start = rnd.randrange(len(b) - 16)
    end = min(len(b), start + rnd.randrange(4, 256))
    chunk = bytes(b[start:end])
    reps = rnd.choice((2, 4, 8, 32, 128))
    at = rnd.randrange(len(b))
    b[at:at] = chunk * reps
    del b[64 * 1024 * 1024:]        # keep a runaway splice from eating the box


def _delete(b, rnd):
    """Remove a run, shifting every later byte. Offsets and lengths stored earlier
    then point past where their data now is, which a pure overwrite never
    produces."""
    if len(b) < 64:
        return
    start = rnd.randrange(len(b) - 32)
    end = min(len(b), start + rnd.randrange(1, 64))
    del b[start:end]


MUTATIONS = [
    (_flip_bits, 3),
    (_extreme_int, 5),
    (_meta_len, 4),
    (_continuation, 2),
    (_truncate, 2),
    (_splice, 3),
    (_delete, 2),
]


def mutate(data, seed):
    rnd = random.Random(seed)
    b = bytearray(data)
    pool = []
    for fn, weight in MUTATIONS:
        pool.extend([fn] * weight)
    for _ in range(rnd.randint(1, 3)):
        rnd.choice(pool)(b, rnd)
    return bytes(b)


def main():
    src, seed, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    with open(src, "rb") as f:
        data = f.read()
    out = mutate(data, seed)
    with open(dst, "wb") as f:
        f.write(out)
    os.chmod(dst, 0o644)


if __name__ == "__main__":
    main()
