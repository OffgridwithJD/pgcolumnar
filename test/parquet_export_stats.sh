#!/usr/bin/env bash
#
# Statistics in the files WE export (#850).
#
# pgcolumnar.export_parquet() wrote no per-row-group statistics, so a file we
# exported could never drive the Parquet FDW's row-group skipping: every
# documented condition in docs/limitations.md's "Row-group skipping" section
# could hold and "Row Groups Skipped" would still be 0, because the reader had
# no min/max to test. The native chunk-group skip on the same data was, and is,
# unaffected -- the fault was entirely on the write side.
#
# What this suite pins, in the bytes rather than in a reader's opinion of them:
#   * every column chunk of a skippable physical type carries min_value and
#     max_value, and the values are CORRECT per row group, not merely present;
#   * null_count is written always, and counts nulls -- including values that
#     have no Parquet representation and are folded to null (date and timestamp
#     infinity), which must not reach a bound;
#   * the float rules parquet.thrift states for TYPE_ORDER: NaN excluded from
#     the bounds, nan_count always written, no bounds at all when every non-null
#     value is NaN, a zero maximum written as +0.0 and a zero minimum as -0.0;
#   * FileMetaData.column_orders, which the spec makes mandatory once
#     min_value/max_value are written and without which Arrow discards them;
#   * and the payoff: the FDW skips row groups on a file we exported, and the
#     rows it returns still match an oracle exactly.
#
# The instrument is test/parquet_stats.py, which reads the footer with no
# Parquet library. That is deliberate. A suite whose instrument is an optional
# import reports SKIP when the import is missing, and a skip is not coverage;
# and column_orders is invisible through pyarrow's statistics API, so a
# third-party reader cannot tell us whether we wrote it.
#
# Usage:  test/parquet_export_stats.sh [PG_CONFIG]
# Written fresh for pgColumnar.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pgc_setup "${1:-/usr/local/pg17/bin/pg_config}"

STATS_PY="$(dirname "${BASH_SOURCE[0]}")/parquet_stats.py"
PARQ="$PGC_WORKDIR/export_stats.parquet"
S="$PGC_WORKDIR/stats.txt"

# 196609 = 3*65536 + 1, so the export writes 4 row groups and the last holds a
# single row. The one-row group is the min==max edge and costs nothing.
ROWS=196609
RGSIZE=65536
NGROUPS=4

COLS="id int4, i2 int2, i8 int8, f4 float4, d date, ts timestamp,
      nul int4, alln int4, t text, b bool"

# ---- fixture ---------------------------------------------------------------
#
# Every column earns its place:
#   id    ascending, so the four groups hold disjoint ranges: without that a
#         correct writer and a writer that stamps one file-wide min/max onto
#         every chunk are indistinguishable.
#   i2    a PG int2 stored as a Parquet INT32, so a statistic written at the
#         PostgreSQL width rather than the physical one is visible.
#   f4    exact halves, so the float text comparison is not a rounding argument.
#   d,ts  ascending AND carrying infinities, which have no Parquet
#         representation and are folded to null: they must not reach a bound.
#   nul   nulls, with every non-null value above 1000000, so a null admitted
#         into the accumulator as 0 lands outside the true range.
#   alln  all null: the column that must carry no bounds at all.
#   t,b   a BYTE_ARRAY and a BOOLEAN, whose bounds this change does not write.
psql_run "CREATE EXTENSION IF NOT EXISTS pgcolumnar;"
psql_run "CREATE TABLE es_h ($COLS);"
psql_run "INSERT INTO es_h
          SELECT g - 1,
                 (g % 20000) + 1,
                 g::bigint * 1000000,
                 g * 0.5,
                 CASE WHEN g % $RGSIZE = 3 THEN 'infinity'::date
                      WHEN g % $RGSIZE = 4 THEN '-infinity'::date
                      ELSE DATE '2000-01-01' + (g / 8) END,
                 CASE WHEN g % $RGSIZE = 5 THEN 'infinity'::timestamp
                      ELSE TIMESTAMP '2000-01-01' + (g || ' sec')::interval END,
                 CASE WHEN g % 5 = 0 THEN NULL ELSE g + 1000000 END,
                 NULL,
                 'r' || g,
                 (g % 2 = 0)
          FROM generate_series(1, $ROWS) g;"
psql_run "CREATE TABLE es_c ($COLS) USING pgcolumnar;"
psql_run "INSERT INTO es_c SELECT * FROM es_h;"
psql_run "SELECT pgcolumnar.export_parquet('es_c', '$PARQ');"

if ! python3 "$STATS_PY" "$PARQ" > "$S" 2>"$PGC_WORKDIR/stats.err"; then
	echo "FAIL  the footer parser could not read the exported file:"
	sed 's/^/      /' "$PGC_WORKDIR/stats.err"
	PGC_FAIL=1
	PGC_CHECKS=$((PGC_CHECKS + 1))
	pgc_summary
fi

# ---- accessors over the parser's output ------------------------------------

fileval() {  # fileval KEY
	awk -v k="$1=" '$1=="FILE"{for(i=2;i<=NF;i++) if(index($i,k)==1)
		{print substr($i,length(k)+1); exit}}' "$S"
}
leafof() {  # leafof PATH -> the leaf index carrying that column
	awk -v p="path=$1" '$1=="CHUNK" && $0 ~ ("(^| )" p "( |$)"){
		for(i=2;i<=NF;i++) if(index($i,"leaf=")==1)
			{print substr($i,6); exit}}' "$S"
}
cf() {  # cf RG LEAF KEY -> that chunk's value for KEY
	awk -v rg="rg=$1" -v lf="leaf=$2" -v k="$3=" '
		$1=="CHUNK" && $2==rg && $3==lf {
			for(i=4;i<=NF;i++) if(index($i,k)==1)
				{print substr($i,length(k)+1); exit}}' "$S"
}
# Count CHUNK lines whose KEY equals VAL, restricted to a set of leaf indexes.
countchunks() {  # countchunks "LEAFSET" KEY VAL
	awk -v leaves="$1" -v k="$2=" -v want="$3" '
		BEGIN{n=split(leaves,a," "); for(i=1;i<=n;i++) keep[a[i]]=1}
		$1=="CHUNK" {
			lf=""; v="";
			for(i=2;i<=NF;i++){
				if(index($i,"leaf=")==1) lf=substr($i,6);
				if(index($i,k)==1) v=substr($i,length(k)+1);
			}
			if(lf in keep && v==want) c++
		} END{print c+0}' "$S"
}

# Leaf indexes, resolved from the file rather than assumed from column order.
L_ID="$(leafof id)";   L_I2="$(leafof i2)";  L_I8="$(leafof i8)"
L_F4="$(leafof f4)";   L_D="$(leafof d)";    L_TS="$(leafof ts)"
L_NUL="$(leafof nul)"; L_ALLN="$(leafof alln)"
L_T="$(leafof t)";     L_B="$(leafof b)"
# The seven skippable-type columns that hold at least one value, and alln,
# which is skippable by type and holds none.
SKIPPABLE="$L_ID $L_I2 $L_I8 $L_F4 $L_D $L_TS $L_NUL"
SKIPTYPE="$SKIPPABLE $L_ALLN"

# ---- premises: the instrument reached the data ------------------------------
#
# Every red below is ambiguous without these. They separate "no statistics were
# written" from "the parser stopped early", "we measured someone else's file",
# and "the exported data is wrong".

check "premise: leaf indexes resolved for all ten columns" \
	"$(printf '%s\n' "$L_ID" "$L_I2" "$L_I8" "$L_F4" "$L_D" "$L_TS" \
		"$L_NUL" "$L_ALLN" "$L_T" "$L_B" | grep -c '^[0-9]\+$')" "10"
check "premise: the file under test is one we wrote" "$(fileval created_by)" "pgColumnar"
check_num "premise: the footer declares $NGROUPS row groups" \
	"$(fileval row_groups)" "$NGROUPS"
check_num "premise: the footer declares 10 leaf columns" "$(fileval leaves)" "10"
check_num "premise: the parser reaches ColumnMetaData (num_values sums to the table)" \
	"$(awk -v lf="leaf=$L_ID" '$1=="CHUNK" && $3==lf {
		for(i=4;i<=NF;i++) if(index($i,"num_values=")==1) s+=substr($i,12)
	} END{print s+0}' "$S")" \
	"$(q "SELECT count(*) FROM es_c")"

# The oracle. read_parquet decodes DATA PAGES -- a different code path from the
# footer under test -- so a bound is compared against the values themselves.
# Materialized once: re-decoding the file per check would be slow enough to
# discourage checking.
psql_run "CREATE TABLE oracle AS
          SELECT (row_number() OVER () - 1) / $RGSIZE AS grp, *
          FROM pgcolumnar.read_parquet('$PARQ') AS t($COLS);"
# The bucket mapping is what every per-group value check rests on. These two
# assert it against the fixture's ascending id rather than assuming that
# read_parquet returned the file in order.
check "premise: the oracle's buckets are the file's row groups" \
	"$(q "SELECT string_agg(c::text, ',' ORDER BY grp)
	      FROM (SELECT grp, count(*) c FROM oracle GROUP BY grp) s")" \
	"$RGSIZE,$RGSIZE,$RGSIZE,1"
check "premise: each bucket holds its own contiguous id range" \
	"$(q "SELECT bool_and(mn = grp * $RGSIZE AND mx = grp * $RGSIZE + c - 1)
	      FROM (SELECT grp, min(id) mn, max(id) mx, count(*) c
	            FROM oracle GROUP BY grp) s")" "t"
check_num "premise: the oracle holds every exported row" \
	"$(q "SELECT count(*) FROM oracle")" "$ROWS"
check "premise: the exported data equals the heap on the columns nothing folds" \
	"$(pgc_set_hash "SELECT id,i2,i8,f4,nul,alln,t,b FROM oracle")" \
	"$(pgc_set_hash "SELECT id,i2,i8,f4,nul,alln,t,b FROM es_h")"

# ---- (a) presence, with the buckets accounting for every chunk -------------

BOTH="$(countchunks "$SKIPPABLE" has_min 1)"
BOTHMAX="$(countchunks "$SKIPPABLE" has_max 1)"
NEITHER="$(countchunks "$L_ALLN" has_min 0)"
TOTSKIP="$(countchunks "$SKIPTYPE" rg 0)"
ONESIDED=$(( $(countchunks "$SKIPTYPE" has_min 1) + $(countchunks "$SKIPTYPE" has_max 1)
	     - 2 * $(awk -v leaves="$SKIPTYPE" '
		BEGIN{n=split(leaves,a," "); for(i=1;i<=n;i++) keep[a[i]]=1}
		$1=="CHUNK"{lf="";mn="";mx="";
			for(i=2;i<=NF;i++){
				if(index($i,"leaf=")==1) lf=substr($i,6);
				if(index($i,"has_min=")==1) mn=substr($i,9);
				if(index($i,"has_max=")==1) mx=substr($i,9);
			}
			if((lf in keep) && mn=="1" && mx=="1") c++
		} END{print c+0}' "$S") ))
echo "-- chunks of a skippable physical type: $(( NGROUPS * 8 )) expected;" \
     "with both bounds $BOTH, with neither $NEITHER, one-sided $ONESIDED"
check_num "every value-bearing skippable chunk carries a minimum" \
	"$BOTH" "$(( NGROUPS * 7 ))"
check_num "every value-bearing skippable chunk carries a maximum" \
	"$BOTHMAX" "$(( NGROUPS * 7 ))"
check_num "no chunk carries exactly one bound" "$ONESIDED" "0"
check_num "buckets account for every skippable-type chunk" \
	"$(( BOTH + NEITHER + ONESIDED ))" "$(( NGROUPS * 8 ))"
check_num "the all-null column carries no bounds" \
	"$(countchunks "$L_ALLN" has_min 1)" "0"

# A statistic must be written at the PHYSICAL width: a PG int2 is a Parquet
# INT32 and its bound is 4 bytes, not 2.
check_num "every bound is its physical width" \
	"$(awk '$1=="CHUNK"{pt="";mnl="";mxl="";
		for(i=2;i<=NF;i++){
			if(index($i,"ptype=")==1) pt=substr($i,7);
			if(index($i,"minlen=")==1) mnl=substr($i,8);
			if(index($i,"maxlen=")==1) mxl=substr($i,8);
		}
		w=0; if(pt=="1"||pt=="4") w=4; else if(pt=="2"||pt=="5") w=8;
		if(w>0){ if(mnl!="-" && mnl+0!=w) bad++; if(mxl!="-" && mxl+0!=w) bad++ }
	} END{print bad+0}' "$S")" "0"

# ---- (b) the values are right, per row group -------------------------------

# A float bound and its oracle are the same number written two ways: the parser
# prints Python's repr (32768.0) and PostgreSQL prints its own text form (32768).
# Comparing them as strings fails on the presentation, so compare them as
# numbers -- while keeping check_num's refusal to compare a measurement nobody
# took, which is the whole reason the value checks are trustworthy.
check_float() {  # check_float NAME GOT WANT
	local name="$1" got="$2" want="$3"
	if ! pgc_is_number "$got" || ! pgc_is_number "$want"; then
		PGC_CHECKS=$((PGC_CHECKS + 1))
		PGC_FAIL=1
		echo "FAIL  $name: not a measurement, so nothing was compared:" \
			"got [$got] want [$want]"
		return 1
	fi
	check "$name" \
		"$(awk -v v="$got" 'BEGIN{printf "%.9g", v+0}')" \
		"$(awk -v v="$want" 'BEGIN{printf "%.9g", v+0}')"
}

# Physical-space oracle per column: what the bound must decode to.
ora() {  # ora COL GRP min|max
	case "$1" in
		d)  q "SELECT ($3(d) - DATE '1970-01-01')::text FROM oracle WHERE grp = $2" ;;
		ts) q "SELECT (EXTRACT(EPOCH FROM ($3(ts) - TIMESTAMP '1970-01-01'))
		               * 1000000)::bigint::text FROM oracle WHERE grp = $2" ;;
		f4) q "SELECT $3(f4)::float8::text FROM oracle WHERE grp = $2" ;;
		*)  q "SELECT $3($1)::text FROM oracle WHERE grp = $2" ;;
	esac
}
for spec in "id $L_ID" "i2 $L_I2" "i8 $L_I8" "f4 $L_F4" "d $L_D" "ts $L_TS" "nul $L_NUL"; do
	set -- $spec
	col="$1"; lf="$2"
	# f4's bound is a float on one side and PostgreSQL's float text on the
	# other; every other column here is an integer in physical space.
	cmp=check_num
	[ "$col" = f4 ] && cmp=check_float
	for g in $(seq 0 $((NGROUPS - 1))); do
		$cmp "group $g min($col) equals the oracle" \
			"$(cf "$g" "$lf" min)" "$(ora "$col" "$g" min)"
		$cmp "group $g max($col) equals the oracle" \
			"$(cf "$g" "$lf" max)" "$(ora "$col" "$g" max)"
	done
done

# A writer that computed one min/max for the whole file would satisfy every
# presence check above and still make skipping impossible.
check_num "the four groups report four distinct id minima" \
	"$(awk -v lf="leaf=$L_ID" '$1=="CHUNK" && $3==lf {
		for(i=4;i<=NF;i++) if(index($i,"min=")==1) print substr($i,5)
	}' "$S" | sort -u | wc -l)" "$NGROUPS"
check_num "min <= max in every chunk carrying both" \
	"$(awk '$1=="CHUNK"{mn="";mx="";
		for(i=2;i<=NF;i++){
			if(index($i,"min=")==1 && index($i,"minhex=")!=1 && index($i,"minlen=")!=1)
				mn=substr($i,5);
			if(index($i,"max=")==1 && index($i,"maxhex=")!=1 && index($i,"maxlen=")!=1)
				mx=substr($i,5);
		}
		if(mn!="-" && mx!="-" && mn!="" && mx!="" && mn+0>mx+0) bad++
	} END{print bad+0}' "$S")" "0"

# ---- (c) null_count --------------------------------------------------------

check_num "null_count is written for every chunk, including where it is zero" \
	"$(awk '$1=="CHUNK"{for(i=2;i<=NF;i++) if(index($i,"null_count=")==1 &&
		substr($i,12)=="-") n++} END{print n+0}' "$S")" "0"
for spec in "nul $L_NUL" "d $L_D" "ts $L_TS" "alln $L_ALLN" "id $L_ID"; do
	set -- $spec
	col="$1"; lf="$2"
	for g in $(seq 0 $((NGROUPS - 1))); do
		check_num "group $g null_count($col) equals the oracle" \
			"$(cf "$g" "$lf" null_count)" \
			"$(q "SELECT (count(*) - count($col))::text FROM oracle WHERE grp = $g")"
	done
done

# ---- (d) values with no Parquet representation are folded, not admitted ----

check "premise: the fixture's infinite dates are more than none" \
	"$(q "SELECT count(*) > 0 FROM es_h WHERE d IN ('infinity','-infinity')")" "t"
check "premise: the fixture's infinite timestamps are more than none" \
	"$(q "SELECT count(*) > 0 FROM es_h WHERE ts = 'infinity'")" "t"
check_num "no date or timestamp bound is an infinity sentinel" \
	"$(awk -v ld="leaf=$L_D" -v lt="leaf=$L_TS" '$1=="CHUNK" && ($3==ld || $3==lt) {
		for(i=4;i<=NF;i++){
			if(index($i,"min=")==1) v=substr($i,5);
			if(index($i,"max=")==1) w=substr($i,5);
		}
		if(v=="2147483647"||v=="-2147483648"||w=="2147483647"||w=="-2147483648") bad++;
		if(v=="9223372036854775807"||w=="9223372036854775807") bad++;
		if(v=="-9223372036854775808"||w=="-9223372036854775808") bad++;
	} END{print bad+0}' "$S")" "0"

# ---- (e) the float rules ---------------------------------------------------

psql_run "CREATE TABLE nan_h (f8a float8, f8b float8, z8 float8, z9 float8);"
psql_run "INSERT INTO nan_h VALUES
            (1.0,  'NaN',  -1.0, 0.0),
            ('NaN','NaN',  -0.0, 1.0),
            (-2.0, 'NaN',  -3.0, 2.0),
            (NULL, NULL,   NULL, NULL);"
psql_run "CREATE TABLE nan_c (LIKE nan_h) USING pgcolumnar;"
psql_run "INSERT INTO nan_c SELECT * FROM nan_h;"
NANQ="$PGC_WORKDIR/nan.parquet"
psql_run "SELECT pgcolumnar.export_parquet('nan_c', '$NANQ');"
NS="$PGC_WORKDIR/nanstats.txt"
if python3 "$STATS_PY" "$NANQ" > "$NS" 2>&1; then
	nf() {  # nf LEAF KEY  (over the NaN file)
		awk -v lf="leaf=$1" -v k="$2=" '$1=="CHUNK" && $3==lf {
			for(i=4;i<=NF;i++) if(index($i,k)==1)
				{print substr($i,length(k)+1); exit}}' "$NS"
	}
	nleafof() {
		awk -v p="path=$1" '$1=="CHUNK" && $0 ~ ("(^| )" p "( |$)"){
			for(i=2;i<=NF;i++) if(index($i,"leaf=")==1)
				{print substr($i,6); exit}}' "$NS"
	}
	N_A="$(nleafof f8a)"; N_B="$(nleafof f8b)"
	N_Z8="$(nleafof z8)"; N_Z9="$(nleafof z9)"

	check_num "a float column holding a NaN still carries both bounds" \
		"$(nf "$N_A" has_min)" "1"
	check_float "min(f8a) is the smallest non-NaN value" "$(nf "$N_A" min)" "-2.0"
	check_float "max(f8a) is the largest non-NaN value" "$(nf "$N_A" max)" "1.0"
	check_num "an all-NaN column carries no minimum" "$(nf "$N_B" has_min)" "0"
	check_num "an all-NaN column carries no maximum" "$(nf "$N_B" has_max)" "0"
	check_num "nan_count is written for every float chunk" \
		"$(awk '$1=="CHUNK"{for(i=2;i<=NF;i++){
			if(index($i,"ptname=")==1) p=substr($i,8);
			if(index($i,"nan_count=")==1) n=substr($i,11);
		} if((p=="FLOAT"||p=="DOUBLE") && n=="-") bad++} END{print bad+0}' "$NS")" "0"
	check_num "nan_count counts the NaNs" "$(nf "$N_B" nan_count)" "3"
	check_num "no float bound is a NaN bit pattern" \
		"$(awk '$1=="CHUNK"{mn="";mx="";
			for(i=2;i<=NF;i++){
				if(index($i,"min=")==1 && index($i,"minhex=")!=1 && index($i,"minlen=")!=1)
					mn=substr($i,5);
				if(index($i,"max=")==1 && index($i,"maxhex=")!=1 && index($i,"maxlen=")!=1)
					mx=substr($i,5);
			}
			if(mn=="nan"||mx=="nan"||mn=="-nan"||mx=="-nan") bad++
		} END{print bad+0}' "$NS")" "0"
	# parquet.thrift, TYPE_ORDER: a computed max of zero is written +0.0 and a
	# computed min of zero is written -0.0, whichever zero was measured.
	check "a zero maximum is written as +0.0" \
		"$(nf "$N_Z8" maxhex)" "0000000000000000"
	check "a zero minimum is written as -0.0" \
		"$(nf "$N_Z9" minhex)" "0000000000000080"
else
	echo "FAIL  the footer parser could not read the NaN fixture:"
	sed 's/^/      /' "$NS"
	PGC_FAIL=1; PGC_CHECKS=$((PGC_CHECKS + 1))
fi

# ---- (f) column_orders, without which the bounds have no defined meaning ----

check_num "the footer carries one ColumnOrder per leaf column" \
	"$(fileval column_orders)" "10"
check "every ColumnOrder is TYPE_ORDER" "$(fileval order_ids)" "1"

# ---- (g) the types this change does not claim ------------------------------

check_num "no chunk carries the deprecated minimum (field 2)" \
	"$(countchunks "$L_ID $L_I2 $L_I8 $L_F4 $L_D $L_TS $L_NUL $L_ALLN $L_T $L_B" has_dep_min 1)" "0"
check_num "no chunk carries the deprecated maximum (field 1)" \
	"$(countchunks "$L_ID $L_I2 $L_I8 $L_F4 $L_D $L_TS $L_NUL $L_ALLN $L_T $L_B" has_dep_max 1)" "0"

check_num "the BYTE_ARRAY column carries no bounds" \
	"$(countchunks "$L_T" has_min 1)" "0"
check_num "the BOOLEAN column carries no bounds" \
	"$(countchunks "$L_B" has_min 1)" "0"

# ---- (h) the payoff: the FDW skips on a file we exported -------------------

psql_run "CREATE SERVER es_srv FOREIGN DATA WRAPPER pgcolumnar_parquet;"
psql_run "CREATE FOREIGN TABLE es_ft ($COLS) SERVER es_srv OPTIONS (path '$PARQ');"

explain_val() {  # explain_val LABEL WHERE
	q "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
	   SELECT count(*) FROM es_ft $2" \
		| grep "$1:" | grep -oE '[0-9]+' | head -1
}
skipped_for() { explain_val "Row Groups Skipped" "$1"; }

check_num "premise: the FDW reports $NGROUPS row groups" \
	"$(explain_val "Row Groups" "WHERE id < 10")" "$NGROUPS"
check_num "an unrestricted scan skips nothing" "$(skipped_for "")" "0"
check_num "a predicate confined to one group skips the other three" \
	"$(skipped_for "WHERE id BETWEEN 70000 AND 71000")" "3"
check_num "a bigint predicate skips" \
	"$(skipped_for "WHERE i8 < 1000000000::bigint")" "3"
check_num "a float predicate skips" "$(skipped_for "WHERE f4 < 1.0::real")" "3"
check_num "a date predicate skips" \
	"$(skipped_for "WHERE d < DATE '2000-01-05'")" "3"
check_num "a timestamp predicate skips" \
	"$(skipped_for "WHERE ts < TIMESTAMP '2000-01-01 00:30:00'")" "3"
# Documented refusals, reachable from our own exported files for the first time.
#
# Each runs beside a predicate that differs in ONE respect and does skip. Without
# that pair the checks are worthless: every group's max(i8) exceeds 5 and every
# group's max(f4) exceeds 1.0, so `i8 > 5` and `f4 >= 1.0` are unprunable on this
# data whether the refusal exists or not, and a check that reads 0 either way is
# not evidence of a refusal.
check_num "control: the same column skips when the constant matches its type" \
	"$(skipped_for "WHERE i8 < 5::bigint")" "$NGROUPS"
check_num "a cross-type constant skips nothing, on the identical predicate" \
	"$(skipped_for "WHERE i8 < 5::int")" "0"
check_num "control: a float < predicate below every bound skips" \
	"$(skipped_for "WHERE f4 < 0.4::real")" "$NGROUPS"
# The reader refuses > and >= on a float column outright, because Parquet
# excludes NaN from the bounds while PostgreSQL sorts NaN above every value. The
# refusal does not depend on this column holding a NaN, and f4 holds none; the
# NaN rules themselves are pinned on the nan_c fixture below.
check_num "a float >= predicate above every bound still skips nothing" \
	"$(skipped_for "WHERE f4 >= 200000.0::real")" "0"

# Soundness. A skipped group emits nothing, and the executor's recheck cannot
# recover a row that never arrived, so every predicate above must return exactly
# what the oracle returns.
for pred in \
	"id BETWEEN 70000 AND 71000" \
	"id < 5000" \
	"i2 = 777" \
	"i8 < 1000000000::bigint" \
	"f4 < 1.0::real" \
	"f4 >= 1.0::real" \
	"d < DATE '2000-01-05'" \
	"d > DATE '2060-01-01'" \
	"ts < TIMESTAMP '2000-01-01 00:30:00'" \
	"nul < 1000100" \
	"alln IS NULL"
do
	check "the FDW result equals the oracle for [$pred]" \
		"$(pgc_set_hash "SELECT id,i2,i8,f4,d,ts,nul,alln,t,b FROM es_ft WHERE $pred")" \
		"$(pgc_set_hash "SELECT id,i2,i8,f4,d,ts,nul,alln,t,b FROM oracle WHERE $pred")"
done

# ---- the other direction: the instrument can report a bound that IS there ---
#
# Every absence above is evidence only if this parser is capable of reporting a
# presence. pyarrow writes statistics; if it is here, the same parser must find
# them. Gated in an if rather than a pgc_skip: this arm is a control on the
# instrument, not the coverage the suite exists for.
if python3 -c 'import pyarrow.parquet' 2>/dev/null; then
	PYQ="$PGC_WORKDIR/pyarrow.parquet"
	python3 - "$PYQ" <<'PY'
import sys, pyarrow as pa, pyarrow.parquet as pq
pq.write_table(pa.table({"id": pa.array(range(200000), pa.int64())}),
               sys.argv[1], row_group_size=50000)
PY
	check_num "control: the parser finds pyarrow's bounds" \
		"$(python3 "$STATS_PY" "$PYQ" | grep -c 'has_min=1')" "4"
	check_num "control: the parser reports the deprecated fields where they exist" \
		"$(python3 "$STATS_PY" "$PYQ" | grep -c 'has_dep_min=1')" "4"
else
	echo "note: pyarrow absent, so the parser's can-report-presence control did not run"
fi

pgc_summary
