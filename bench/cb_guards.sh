#!/usr/bin/env bash
#
# Guards for the ClickBench harness (#465).
#
# Separate from run_clickbench.sh so they can be sourced and tested without the
# 15 GB download and the tuned cluster the benchmark needs. test/bench_guards.sh
# runs them in the ordinary matrix; the benchmark itself cannot.
#
# Sourced, not executed. Nothing here touches a database or the filesystem.
# Written fresh for pgColumnar.

# cb_prepared_xacts_ok <current> <workers>
#
# pgcolumnar.parallel_copy prepares one transaction per worker, so the cluster
# needs at least that many slots. The stock max_prepared_transactions is 0, which
# means every parallel arm errors out on its first worker.
#
# This must be asked BEFORE any arm is loaded, because the setting is
# PGC_POSTMASTER: raising it needs a restart, and discovering it mid-run wastes
# the whole run.
#
# A serial arm asks for 0 workers and needs no slots, so it is never blocked by a
# setting it does not use.
cb_prepared_xacts_ok() {
	local current="${1:-}" workers="${2:-}"
	case "$current" in '' | *[!0-9]*) return 1 ;; esac
	case "$workers" in '' | *[!0-9]*) return 1 ;; esac
	[ "$current" -ge "$workers" ]
}

# cb_prepared_xacts_message <current> <workers>
#
# The message is the deliverable. Without it the operator meets a per-worker
# error in a load log and has to work back to the cause; with it they are told
# the setting, the value, and that it costs a restart.
cb_prepared_xacts_message() {
	local current="${1:-}" workers="${2:-}"
	printf '%s\n' \
		"max_prepared_transactions is ${current:-unset}, and a ${workers}-worker parallel arm needs ${workers}." \
		"pgcolumnar.parallel_copy prepares one transaction per worker, so every arm would fail at once." \
		"Set max_prepared_transactions = ${workers} (or more) and restart the postmaster; it cannot be changed in a session."
}

# cb_rows_ok <got> <want>
#
# A load that lost rows is a failure and not a fast result. An errored parallel
# arm leaves an EMPTY table and returns in about no time, which reads as perfect
# scaling; #465 records a harness that published exactly that.
#
# Both sides must be numbers. A psql that failed yields an empty string, and
# comparing "" with "" passes while measuring nothing, which is the trap #418
# exists to forbid.
cb_rows_ok() {
	local got="${1:-}" want="${2:-}"
	case "$got" in '' | *[!0-9]*) return 1 ;; esac
	case "$want" in '' | *[!0-9]*) return 1 ;; esac
	[ "$got" = "$want" ]
}

# cb_cold_tag <drop_how>
#
# The protocol tag the report carries, decided from what the page-cache probe
# actually achieved: "direct" or "sudo" if the drop was performed, anything else
# if it was not.
#
# This exists as a guard rather than as an if/else in the report because the
# claim is the thing worth testing and the drop is not: whether a given kernel
# permits the drop cannot be decided by a matrix suite, while whether the report
# is honest about what happened is pure arithmetic. #506 records the harness
# printing the cold tag unconditionally, including on hosts where both drop
# mechanisms had failed.
#
# Unknown and empty fall to the warm tag deliberately. A tag that cannot be
# justified must not be the cold one, because the cold one is the claim that
# gets quoted.
cb_cold_tag() {
	case "${1:-}" in
		direct | sudo)
			printf '%s\n' \
				"tag: lukewarm-cold-run (page cache dropped, server not restarted per query)"
			;;
		*)
			printf '%s\n' \
				"tag: WARM-RUN (page cache could NOT be dropped on this host; the first-try" \
				"     column is not a cold number and must not be quoted as one)"
			;;
	esac
}
