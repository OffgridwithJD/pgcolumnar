#!/usr/bin/env python3
#
# Deterministic mutator over a valid Avro manifest for test/fuzz_avro.sh (#388).
# Every mutant is a pure function of one integer seed, so a finding reproduces:
#   python3 test/avro_corpus.py <base.avro> <seed> <out.avro>
# seed -1 (or "valid") writes the base unmutated: the harness uses it as the
# control that proves the decoder is actually reached.
import sys
import hashlib


def _rng(state):
    return int(hashlib.sha256(str(state).encode()).hexdigest(), 16)


def mutate(data, seed):
    b = bytearray(data)
    r = _rng(seed)
    nops = 1 + (r % 6)
    for _ in range(nops):
        r = _rng(r)
        if not b:
            break
        op = r % 5
        pos = r % len(b)
        if op == 0:                      # flip a byte
            b[pos] ^= (r >> 8) & 0xFF
        elif op == 1:                    # truncate at pos
            del b[pos:]
        elif op == 2:                    # insert a run of one byte
            b[pos:pos] = bytes([(r >> 16) & 0xFF]) * (1 + (r % 64))
        elif op == 3:                    # delete a run
            del b[pos:pos + 1 + (r % 16)]
        else:                            # duplicate a nearby region
            b[pos:pos] = bytes(b[max(0, pos - 16):pos])
    return bytes(b)


def main():
    base = sys.argv[1]
    arg = sys.argv[2]
    out = sys.argv[3]
    data = open(base, "rb").read()
    if arg in ("-1", "valid"):
        open(out, "wb").write(data)
        return
    open(out, "wb").write(mutate(data, int(arg)))


main()
