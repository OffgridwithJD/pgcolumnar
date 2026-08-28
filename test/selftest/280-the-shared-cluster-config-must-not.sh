# The shared cluster config must not set a pgcolumnar.* GUC.
#
# lib.sh builds the cluster nearly every suite runs against. A pgcolumnar.* GUC
# set in that block applies to ALL of them, so the whole tree measures something
# other than what ships, and no suite can see it: the value is correct in SHOW,
# nothing in the suite mentions it, and the divergence is a property of the
# harness rather than of the test being read.
#
# FOUND THE EXPENSIVE WAY, 2026-08-28 (#799). The block set
# pgcolumnar.unique_lock_buckets=100003 against a shipped default of 128 -- 781
# times higher -- to serve one suite. The bucket count bounds the advisory locks
# a transaction holds per unique index, so a 20,000-row insert into a columnar
# table with a PRIMARY KEY exhausted max_locks_per_transaction and failed with
#
#   ERROR:  out of shared memory
#   HINT:  You might need to increase "max_locks_per_transaction".
#
# which reads as a product defect and is not one. OffgridwithJD spent an hour
# reproducing it with clean controls -- heap+PK fine, columnar+plain-index fine,
# threshold between 10,000 and 20,000 rows -- all of which correctly implicated
# the unique-insert lock path and none of which could see the cause, because
# every control ran on the same overridden cluster. It was caught by reading
# lib.sh rather than by any measurement on the cluster it was handed.
#
# WHY THE RULE IS "NONE" RATHER THAN "NOT THAT ONE". The failure was not that
# 100003 is a bad number; it is the right number for unique_conc, which sets it
# on its own cluster. The failure is that a whole-tree default was used to
# configure one suite. PGC_EXTRA_CONF exists for the per-suite case and is
# checked below to still be reachable, since a guard that forbade the global
# without leaving the alternative open would just be reverted.
#
# SCOPE. This checks the cluster-config block in lib.sh only. A suite setting a
# GUC on its own cluster, in its own session, or through PGC_EXTRA_CONF is the
# supported shape and is not flagged. Core PostgreSQL GUCs in the block are
# deliberately allowed: they are there to make heap and columnar output
# comparable, which is the harness's job.

_cc_lib="$PGC_TESTDIR/lib.sh"

# The block is delimited by the initdb call above it and the redirection into
# postgresql.conf below it, both of which are load-bearing lines that cannot be
# renamed without someone noticing.
_cc_block() {
	awk '/^[[:space:]]*echo "port=\$PGC_PORT"/ {inb=1}
	     inb {print}
	     /postgresql.conf.\"$/ && inb {exit}' "${1:-$_cc_lib}"
}

_cc_offenders() { _cc_block "${1:-}" | grep -nE '^[[:space:]]*echo "pgcolumnar\.' ; }

_CC_LINES="$(_cc_block | wc -l)"

# The extractor must have FOUND the block. If either delimiter is renamed this
# returns nothing, every check below passes on an empty string, and the guard
# reports a clean cluster config forever. This is the fail-open half.
check "premise: the cluster-config block was located in lib.sh" \
	"$([ "${_CC_LINES:-0}" -ge 8 ] && echo "found ($_CC_LINES lines)" || echo "NOT FOUND ($_CC_LINES)")" \
	"found ($_CC_LINES lines)"
check "premise: and it is the right block (it sets the port and the preload)" \
	"$(_cc_block | grep -cE 'PGC_PORT|shared_preload_libraries')" "2"

# POSITIVE CONTROL. An empty offender list is what a working guard and a blind
# one both report, so make the detector fire on a synthetic copy carrying the
# exact line this file exists to prevent.
_cc_tmp="$(mktemp)"
_cc_block > "$_cc_tmp"
sed -i 's|^\([[:space:]]*\)echo "max_parallel_workers_per_gather=0"|\1echo "max_parallel_workers_per_gather=0"\n\1echo "pgcolumnar.unique_lock_buckets=100003"|' "$_cc_tmp"
check "premise: the detector fires on the line that caused #799" \
	"$([ -n "$(_cc_offenders "$_cc_tmp")" ] && echo fires || echo BLIND)" "fires"
rm -f "$_cc_tmp"

# PGC_EXTRA_CONF is the sanctioned alternative. If it stopped being applied,
# this guard would be forbidding the global with nothing left in its place, and
# the next person needing a non-default GUC would put it back.
# Counted on NON-COMMENT lines only: the block's own comment explains the hatch
# and would otherwise be counted as a use of it, which is the same
# assert-the-code-not-the-prose mistake this suite catches elsewhere.
check "the per-suite escape hatch PGC_EXTRA_CONF is still applied to the config" \
	"$(_cc_block | grep -v '^[[:space:]]*#' | grep -c 'PGC_EXTRA_CONF')" "1"

_CC_BAD="$(_cc_offenders)"
[ -n "$_CC_BAD" ] && printf '%s\n' "$_CC_BAD" | sed 's/^/    /'
check "the shared cluster config sets no pgcolumnar.* GUC" \
	"$([ -z "$_CC_BAD" ] && echo clean || echo "$(printf '%s\n' "$_CC_BAD" | wc -l) offender(s)")" "clean"
