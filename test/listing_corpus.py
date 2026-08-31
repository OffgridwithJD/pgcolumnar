#!/usr/bin/env python3
#
# Deterministic ListObjectsV2 corpus + mutator for test/fuzz_listing.sh (#619).
# Every mutant is a pure function of a single integer seed, so a finding
# reproduces exactly:  python3 test/listing_corpus.py <seed> <out.xml>
#
# Seed -1 (or "valid") emits SEEDS[0] unmutated: the harness uses that as the
# control that proves the parser is actually reached.
import sys
import hashlib

# Valid ListObjectsV2 bodies of varying shape: single key; truncated with a
# continuation token carrying reserved bytes; and XML-escaped and numeric
# entities in a key. Each is what the C parser must handle without over-reading.
SEEDS = [
    b'<?xml version="1.0" encoding="UTF-8"?>'
    b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
    b'<Name>pgc-bucket</Name><Prefix>lst/</Prefix><KeyCount>1</KeyCount>'
    b'<IsTruncated>false</IsTruncated>'
    b'<Contents><Key>lst/real.parquet</Key><Size>0</Size></Contents>'
    b'</ListBucketResult>',

    b'<?xml version="1.0"?><ListBucketResult>'
    b'<IsTruncated>true</IsTruncated>'
    b'<NextContinuationToken>1/tok+ab==/cd</NextContinuationToken>'
    b'<Contents><Key>lst/a.parquet</Key></Contents>'
    b'<Contents><Key>lst/b.parquet</Key></Contents>'
    b'</ListBucketResult>',

    b'<?xml version="1.0"?><ListBucketResult>'
    b'<IsTruncated>false</IsTruncated>'
    b'<Contents><Key>lst/real.parquet</Key></Contents>'
    b'<Contents><Key>lst/a&amp;b&#x2f;c&#46;parquet</Key></Contents>'
    b'</ListBucketResult>',
]


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
            b[pos:pos] = bytes([(r >> 16) & 0xFF]) * (1 + (r % 48))
        elif op == 3:                    # delete a run
            del b[pos:pos + 1 + (r % 16)]
        else:                            # duplicate a nearby region
            b[pos:pos] = bytes(b[max(0, pos - 12):pos])
    return bytes(b)


def main():
    arg = sys.argv[1]
    out = sys.argv[2]
    if arg in ("-1", "valid"):
        open(out, "wb").write(SEEDS[0])
        return
    seed = int(arg)
    open(out, "wb").write(mutate(SEEDS[seed % len(SEEDS)], seed))


main()
