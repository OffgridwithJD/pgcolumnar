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

# cb_worker_slots_needed <workers>
#
# An N-worker parallel_copy needs N + 2 worker slots: one background worker per
# loader, one coordinator, and one already held by the logical replication
# launcher. A serial arm registers nothing and needs none.
#
# N + 2 is measured rather than reasoned. Sweeping max_worker_processes against
# three worker counts, the smallest value that loaded every row was 4 for 2
# workers, 6 for 4, and 10 for 8. One below each failed on the LAST loader and
# left the table empty.
cb_worker_slots_needed() {
	local workers="${1:-}"
	case "$workers" in '' | *[!0-9]*) printf '0\n'; return 1 ;; esac
	if [ "$workers" -eq 0 ]; then printf '0\n'; else printf '%s\n' "$((workers + 2))"; fi
}

# cb_worker_slots_ok <current> <workers>
#
# The same shape as cb_prepared_xacts_ok and for the same reason: raising
# max_worker_processes costs a postmaster restart, so it must be asked before any
# arm is loaded rather than discovered in a load log.
#
# The stock default is 8. An 8-worker arm therefore fails on the stock setting,
# at "could not register pgcolumnar parallel_copy loader 7 of 8", and leaves an
# EMPTY table -- which returns fast and reads as excellent scaling. That is the
# #465 failure with a different cause.
cb_worker_slots_ok() {
	local current="${1:-}" workers="${2:-}" need
	case "$current" in '' | *[!0-9]*) return 1 ;; esac
	case "$workers" in '' | *[!0-9]*) return 1 ;; esac
	need="$(cb_worker_slots_needed "$workers")" || return 1
	[ "$current" -ge "$need" ]
}

# cb_worker_slots_message <current> <workers>
#
# Names the value to set, not merely the worker count: N + 2 is not a number the
# operator can be expected to derive from a per-loader error message.
cb_worker_slots_message() {
	local current="${1:-}" workers="${2:-}" need
	need="$(cb_worker_slots_needed "$workers")"
	printf '%s\n' \
		"max_worker_processes is ${current:-unset}, and a ${workers}-worker parallel arm needs ${need}." \
		"parallel_copy registers one worker per loader plus a coordinator, and the logical replication launcher holds one slot." \
		"Set max_worker_processes = ${need} (or more) and restart the postmaster; it cannot be changed in a session." \
		"Below that the arm fails on its last loader and leaves an empty table, which reads as a very fast load."
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
