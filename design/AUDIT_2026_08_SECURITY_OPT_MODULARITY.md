# Aggressive audit — security · optimization · modularity (2026-08-17)

Base: `main` @ 08d1d62 (post #693). Discipline: **prove-don't-trust** (every
finding empirically reproduced by me on the bench before it is believed) and
**TDD** (RED fixture/probe first, then GREEN fix, then removal proof) for every
confirmed defect. Fixes go out as PRs under jdatcmd for ChronicallyJD review;
no self-merge, merge on full green.

## Method

1. Parallel read-only "find" fan-out across three dimensions (security /
   optimization / modularity), each dimension decomposed into focused
   sub-agents over the highest-risk files. Agents statically trace + design a
   concrete repro/measurement; they do NOT build (avoids build-lane collision
   and keeps the proof in my hands).
2. I adversarially **verify** each top candidate on the bench (container
   `pgcolumnar-dev`, lane `pg18_nc`; ASAN lane `pg18_san` for memory-safety
   claims) — a finding is only real if I reproduce its bad outcome and watch it
   go away under the fix.
3. Confirmed findings become TDD tickets, ranked by severity × confidence.

## Status: fan-out running; awaiting agent reports

## Candidate findings (unverified — populated as agents report)

_(table filled in on arrival; VERIFIED column set only after my bench repro)_

| # | Dim | File:line | Claim | Severity | Confidence | VERIFIED |
|---|-----|-----------|-------|----------|------------|----------|
| S-F1 | sec | columnar_objstore.c:79-92 | `PgColumnarRejectNonRegularFile` does stat()-then-open (TOCTOU); FIFO swap re-opens the #644/#692 cancel-resistant-block DoS. Race-free O_NONBLOCK+fstat twin already exists at columnar_parallel_copy.c:125. Sibling-divergence. | med-low | trace (racy CONFIRMED; exploitability SPEC) | ⬜ |
| S-F2 | sec | columnar_vacuum.c:2102,2137 | `pgcolumnar_debug_advance_reserved_offset` / `_set_metapage_version` mutate metadata with NO owner check. Unbound in catalog → latent footgun only. | low | trace | ⬜ |
| S-F3 | sec | columnar_tableam.c:2817 | objstore_s3_addressing GUC is USERSET; traced — bucket always suffixed w/ endpoint authority, no allow-list escape. No change. | info | trace (not exploitable) | ✅ n/a |

**SQL-surface sweep verdict:** no priv-esc, no SSRF-to-metadata, no secret leak, no path-containment escape. Allow-list fail-closed+SUSET, single os_connect choke w/ link-local+CRLF guards, realpath-based Iceberg containment, server-file gate ordering (pg_read_server_files → aclcheck → RLS → open) all confirmed correct.
| O-2 | opt | columnar_metadata.c:1305,547,1357; caller reader.c:2853 | delete_vector reads use systable_beginscan(InvalidOid,indexOK=false) → FULL seqscan of whole delete_vector catalog, once per row group → O(G·D)≈O(G²). delete_vector_pkey(storage_id,group_number) EXISTS, unused. Caveat: SnapshotDirty caller :465 needs phantom-xact reset. | high-value, cheap | complexity (BUFFERS-provable) | ⬜ |
| O-1 | opt | reader.c:1286,1560; vector.c:2773; metadata.c:2481,2273 | Zone-map read materializes+memcpy min/max for ALL natts columns/group; scan uses only predicate/agg cols. Bloom already narrowed (466/504 buffers); zone-map has no per-column probe. | high-value | complexity (2 agents) | ⬜ |
| O-4 | opt | customscan.c:433-446 | Parameterized quals (col op $n) build NO scankey (require Const) → prepared/PL-pgSQL/extended-proto lose ALL zone-map skipping. ParamListInfo is available at Begin. ~5× on selective scans (#391 82% group removal vanishes). | high-value | complexity (EXPLAIN-provable) | ⬜ |
| O-3 | opt | vector.c:4324-4371 | Grouped (GROUP BY) agg is fully row-at-a-time; ungrouped has batch_fold, grouped has no equivalent. High effort. | med | complexity | ⬜ |
| O-5 | opt | encoding.c:640-660 br_get | Gorilla float decode reads bitstream 1 bit at a time; #501 did the word-at-a-time rewrite for int bitunpack (measured 19-21%) but never applied to Gorilla. | med | complexity | ⬜ |
| O-6 | opt | customscan.c:420-421 | IN-list / =ANY (ScalarArrayOpExpr) get zero pushdown; a [min,max] range key would prune (executor rechecks, same as LIKE-prefix). | med | complexity | ⬜ |
| O-7 | opt | reader.c:3348-3359 | Index/bitmap fetch re-reads full row-group list + linear O(G) search per row → O(K·G). Binary search (sorted by firstRowNumber) or cache. | med | complexity | ⬜ |
| M-CASE | ~~BUG?~~ CLEARED | columnar_iceberg.c:2149,2526,2929 | Agent claimed spec-compliant PARQUET manifest falsely rejected. FALSE: code compares vs UPPERCASE "PARQUET" which matches the Iceberg spec's uppercase enum. Residual = strict(strcmp) vs lenient(strcasecmp) style nit only; strict is more spec-faithful. NO CHANGE. | none | ✅ verified not-a-bug | ✅ n/a |
| M-BITS | mod/latent | columnar_parquet_reader.c:863; columnar_parquet.c:510 | bits_for signed `1<<b` UB only at maxval≥2^30 (>1B entries/unit) — unreachable with real row-group sizing; read-path bit width comes from file header not bits_for. Latent portability nit. Trivial `1u<<b` fix. | low | ✅ assessed | ⬜ (defensive) |
| M-5 | mod/sec | columnar_objstore_module.c:1691-1715 | userinfo `@` guard present in os_open(read)+http_request but MISSING in os_write_handle(write/delete/list). Traced fail-closed for SSRF; divergent diagnostic + userinfo bytes in h->url. Sibling-divergence. | low | trace | ⬜ |
| M-1 | mod | reader.c:2023,2854,3391 + 6 bit-test sites | Delete-vector mask-fold triplicated + per-row bit test open-coded 6×. A fix to one path silently diverges MVCC visibility across seqscan/index-fetch/liveness-cache. #644/#692 guard-in-one-twin shape on correctness path. Seam: PgColumnarMergeDeleteVectors + dv_row_deleted. | refactor (high risk-reduction) | trace | ⬜ |
| M-2 | mod | write_state.c:1142,1307,1382; reader.c:825,2113 | On-disk encoding-descriptor ABI hand-packed on write / hand-parsed on read (twice); shared ENCDESC consts used only read-side. Field add/reorder → silent stride mismatch, version byte unmoved. Seam: columnar_encdesc.h codec, ENTRY_LEN from sizeof. | refactor | trace | ⬜ |
| M-3 | mod | encoding.c:2146,2536,2563,2328,2356,2403; decode_rle:348, decode_gorilla:741 | 9 encoding codes enumerated 6× independently; internal length guard in decode_for/delta/dod but NOT decode_rle/gorilla (safe only via central pre-dispatch switch). Seam: encoders[] table + validate_fixed_width in all 5 decoders. | refactor (defensive) | trace | ⬜ |

| D-1 | sec/BUG | columnar_thrift.c:117-192 (loop 169) | **HIGH, reachable now.** PgColumnarThriftSkip has check_stack_depth but NO CHECK_FOR_INTERRUPTS; TC_BOOL/default consume 0 bytes. Parquet footer w/ unknown TC_LIST<bool> size 0xFFFFFFFF → ~4.3B uncancellable no-ops → uninterruptible hang. Reachable via read_parquet(path). #686-class DoS. | HIGH | trace — **VERIFY+FIX** | ⬜ |
| D-2 | sec/BUG | columnar_avro.c:326-447 (loops 409,437,368) | **MED, reachable now.** av_skip CHECK_FOR_INTERRUPTS is per-BLOCK not per-element; AV_NULL consumes 0 bytes; array<null> block count 50M → uncancellable stall. Reachable via read_manifest/iceberg_scan. | MED | trace — **VERIFY+FIX** | ⬜ |
| D-3 | sec/classB | columnar_reader.c:322,355,3162 | varlena VARSIZE len prefix in decoded native stream never bounded vs rawBuf end → OOB read/TOAST-ptr deref. Class B (corrupt native stripe, not file-author). Defense-in-depth. | HIGH-prim/low-reach | trace | ⬜ (DiD) |
| D-4 | sec/classB | columnar_reader.c:813,883 | encTotal uint64→uint32 truncation on compressed codec → OOB read. Class B (native descriptor). | HIGH-prim/low-reach | trace | ⬜ (DiD) |
| D-5 | sec/classB | columnar_reader.c:2188 | all-columns decode omits chunk-offset containment check the projected path enforces (:1714-1723) → OOB read. Class B (catalog). | MED/low-reach | trace | ⬜ (DiD) |
| D-6 | sec/classB | columnar_reader.c:2209,3590 | pageLength-validityBytes uint underflow → ~4GB len; mostly caught downstream. Class B. Assert pageLength>=validityBytes. | low | trace | ⬜ (DiD) |
| D-7 | sec | columnar_iceberg.c:1809-1812 | ice_name_mapping palloc(ne) before per-name cap; bounded by 64MB metadata slurp. Optional cap. | low | trace | ⬜ |
| D-8 | sec | columnar_encoding.c:2072 | decode_fsst_shared lacks COLUMNAR_DECODE_INTERRUPT (bounded by encLen). Minor. | low | trace | ⬜ |

**Decoder sweep verdict:** attacker-authored-FILE parsers (Parquet reader+codec incl. decompression-bomb caps, Avro primitives w/ #644/#691 fixes, Iceberg JSON/REST, Puffin DV, Arrow IPC import #214, objstore HTTP/XML) all well-hardened. Only the two interrupt-discipline gaps (D-1/D-2) are in-model + reachable.

## Owner decision (2026-08-17): drive ALL tiers

User selected every tier. Execution order: (1) quick wins O-2 + S-F1; (2) DiD
bundle D-3..D-6; (3) bigger opt O-1, O-4; (4) modularity M-1..M-3. One TDD PR per
logical fix, ChronicallyJD review, merge on full green.

- ✅ D-1 + D-2 shipped: PR #694 (in review).
- ✅ O-2 delete_vector index shipped: PR #695 (verified seq_scan=20→index, removal-proven).
- ✅ S-F1 stat-before-open TOCTOU shipped: PR #696 (5 openers unified through race-free helper; shape-proven + FIFO functional).
- 🔬 D-3..D-6 DiD bundle — VERIFIED, mostly DISSOLVED (prove-don't-trust):
    - D-5 FALSE POSITIVE: reader.c:1718 containment (`pageOffset<fileOffset || pageOffset+pageLength>groupEnd`) runs for ALL scans incl SELECT * (empirically: corrupt page_offset → clean "chunk lies outside row group" error, backend alive). The base at :2188 is already protected.
      **ERRATUM 2026-08-24: this dissolution was WRONG and the original finding (D-5 row above) was right.** The :1718 containment lives only in the projected read's range computation; `SELECT *` reaches it only because the executor passes a full column bitmap. The whole-group read (`pgcolumnar.enable_column_projection=off`, USERSET; `allColumnsWanted` → one-span read) derives `base` unchecked and SIGSEGVs on a corrupt `page_offset` — found by ChronicallyJD, fixed in PR #716, and the crash was reproduced independently on a second lane (PG17 assert) before approval. The dissolving probe had asserted the error message without asserting the execution path: the "SELECT *" arm ran through the projected reader, so it exercised the guard the finding never doubted and not the path the finding named. A dissolution needs the same assert-the-execution-path discipline as a fix.
    - D-6 caught downstream (empirically: page_length=1 → decompressor errors cleanly, alive).
    - D-4 needs >4GB encLen sum — impractical; valuesLen/decompress checks cover it.
    - D-3 (varlena VARSIZE per-value bound) is a REAL Class-B gap but reachable only via direct relation-file byte surgery (no catalog path; hardening.sh corrupts catalog byteas only) and needs an end-bound threaded through 3 fns + callers. Deferred to a dedicated ASAN-fixture hardening PR; not shipping a guard with no removal proof.
    - Outcome: 0 shippable DiD guards (adding D-4/5/6 would be dead code failing "can I delete and stay green"). Prove-don't-trust prevented 4 redundant guards.
- ✅ O-4 parameterized-qual pushdown shipped: PR #697 (verified 20→1 group read, correlated-PARAM_EXEC safe, removal-proven).
- ✅ O-1 zone-map per-column narrowing shipped: PR #698 (verified 1200→30 fetches, width-independent, removal-proven; group + per-vector).
- 🔬 M-3 decode-guard sub-part VERIFIED REDUNDANT: the central pre-dispatch switch (encoding.c:2536) already validates attlen∈{1,2,4,8} AND n*attlen==rawLen for RLE/FOR/DELTA/GORILLA/DOD before any decoder runs, so a guard inside decode_rle/decode_gorilla can't go RED (dead guard, like DiD). Not shipping.
- ✅ M-1 delete-visibility seam SHIPPED: PR #699 (fold + bit-test single-sourced across 5 paths; mutation-proven load-bearing; behavior-preserving).
- 🔬 M-3 encoders[] table — EXAMINED, DEFERRED: the 6 sites are heterogeneous (encode/decode fns have different signatures — attlen vs att vs neither; applicability is type-conditional integer/float/varlena with nested ladder logic). A uniform table needs ~16 signature-normalizing wrappers + type predicates = a large dispatch rewrite where a mis-wired entry = SILENT DATA CORRUPTION, for maintainability-only value. Not the clean consolidation the summary implied. (M-3 decode-guard sub-part separately verified redundant.)
- 🔬 M-2 encdesc ABI codec — DEFERRED: on-disk descriptor format; a stride/offset bug = silent corruption. Highest-risk refactor, maintainability-only.
- RECOMMENDATION: M-2 and M-3 need careful INDIVIDUAL PRs on clean main after #694-699 merge, NOT a rushed marathon session on top of 6 in-flight PRs. M-1 was shipped because it was cleanly tractable (single shared inline, clean mutation proof); M-2/M-3 are structural rewrites of format/encode-decode-critical code and rushing them is the wrong risk tradeoff (decide-for-correctness). ORIGINAL re-scope note follows: these are LARGE behavior-preserving MAINTAINABILITY refactors (MVCC-visibility seam, on-disk descriptor ABI codec, encoders[] table), NOT bug fixes. No RED→GREEN proof (proven by full suite + characterization tests). High correctness risk (MVCC/format/dispatch). Recommend individual carefully-reviewed PRs on clean main AFTER #694-698 merge — rushing 3 format/MVCC-critical refactors on top of 5 in-flight PRs is the wrong risk tradeoff. Large behavior-preserving refactors touching MVCC visibility (M-1), on-disk descriptor ABI (M-2), encoding enum tables (M-3). They overlap the files of in-flight PRs #695/#697/#698 (metadata.c, reader.c, customscan.c, encoding.c). Recommend sequencing AFTER those merge to avoid conflicts + review overload.

## Session tally: 6 PRs shipped (#694-699), DiD tier verified-dissolved.
- #694 D-1/D-2 Thrift+Avro skip DoS (HIGH+MED, reachable) — RED→GREEN+removal.
- #695 O-2 delete_vector index O(G²) — measured seq_scan=20→index.
- #696 S-F1 stat-before-open TOCTOU — 5 openers unified, shape+FIFO proven.
- #697 O-4 param pushdown — 20→1 group read, correlated-PARAM_EXEC safe.
- #698 O-1 zonemap per-column — 1200→30 fetches, width-independent.
- #699 M-1 delete-visibility seam — fold+bit-test single-sourced across 5 paths; mutation-proven.
- DiD D-3..D-6: 3 verified already-defended (false positives), D-3 real-but-Class-B deferred. No dead guards shipped.

## Verification / fix priority (locked)

**Tier 1 — reachable-now defects, TDD RED→GREEN, PR under jdatcmd:**
1. **D-1** Thrift skip interrupt hang (HIGH) — Parquet footer DoS.
2. **D-2** Avro skip interrupt hang (MED) — manifest DoS. (Same fix class as D-1; bundle or sibling PR.)
3. **S-F1** stat-then-open TOCTOU (MED-LOW) — route openers through fstat-after-open twin.

**Tier 2 — high-value cheap optimization, measured RED→GREEN:**
4. **O-2** delete_vector unindexed catalog scan (O(G²)) — pass delete_vector_pkey / hoist to one read.

**Tier 3 — defense-in-depth hardening (Class B, bundle):** D-3..D-6 bounds/asserts, D-8 interrupt, D-7 cap.

**Tier 4 — modularity refactors (characterization-test-gated, separate PRs):** M-1 delete-visibility seam, M-2 encdesc codec, M-3 encoders[] table + missing decode guards, M-5 userinfo write-path guard.

## Verified findings → action

### ✅ D-1 + D-2 — skip-loop interrupt hangs — FIXED (branch fix/decode-skip-interruptible)
- **D-1 reproduced**: crafted Parquet footer (struct holding 256 × `TC_LIST<bool>` size 0xFFFFFFFF, ~1.8 KB) → `parquet_schema()` spun uninterruptibly, killed by the wrapper at 25.0s; `statement_timeout=2s` did NOT fire. Fix = `CHECK_FOR_INTERRUPTS()` at top of `PgColumnarThriftSkip`. After fix: cancels cleanly (57014). Removal proof: revert → test reads `HANG` + shape `0`. Functional + shape arms, both load-bearing.
- **D-2 fixed**: `av_skip` per-block → per-element `CHECK_FOR_INTERRUPTS`. Guarded by a *placement-sensitive* shape assertion (check must precede the `switch`; reads 0 on pre-fix code even though 2 per-block checks remain — removal-proven). Functional Avro repro deliberately omitted: 50M-cap window ~low-seconds is the sub-100ms-floor unreliability `decode_interrupts.sh` documents; class behaviour proven functionally by D-1 (same skip mechanism).
- **Prove-don't-trust catches on my own instruments**: (a) coreutils `timeout` returns 124 on expiry, not 137 — my first probe misread the hang as empty; (b) PL/pgSQL `WHEN OTHERS` does NOT trap `QUERY_CANCELED`, so I had to catch `query_canceled` by name to observe 57014.
- No regression: native_parquet_stack, avro_manifest, decode_interrupts, native_read_parquet, docs_style, harness_selftest all green on pg18_nc.
- New suite `decode_skip_interrupts` registered in run_all_versions SUITES; CHANGELOG updated.

_(remaining tiers below — promoted here as reproduced)_
