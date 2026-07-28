#!/usr/bin/env bash
#
# One definition of the port a run starts on.
#
# Every suite stands up its own throwaway cluster, so every suite needs a port,
# and each one used to carry a different fixed default: 54321 for smoke, 54322
# for phase2, and so on. Distinct within a run, which is what made the matrix
# work, and identical across runs, which made two runs on one machine contend by
# construction rather than by accident.
#
# #184 fixed that for lib.sh and for the matrix runner, and explained the cost
# better than this comment can: the collision surfaces as a wall of
# `database "regress" already exists` with no named check failing, which reads
# exactly like a real failure and was twice misread as one. It did not reach the
# ten suites that carry their own harness instead of using lib.sh, which is what
# this file is for -- they were still starting on 54321 through 54327.
#
# The retry in lib.sh stays. The point is that a default should not guarantee the
# collision it then has to recover from.
#
# run_all_versions.sh keeps its own copy of this arithmetic rather than sourcing
# this file, and that is deliberate. It re-executes itself from a private copy in
# /tmp so that editing the driver cannot corrupt a run in progress (#184), and at
# that point it is detached from the tree: a tree-relative source would be
# exactly the fragility the re-exec exists to remove. Two copies of one
# expression is the smaller cost. If the range here changes, change it there.
#
# Written fresh for pgColumnar.

# The port this run starts on. Derived from the pid, matching #184's derivation
# in lib.sh and run_all_versions.sh exactly, so there is one range and not two.
# PGC_RUN_OWNER is set by the matrix runner when it re-executes itself, so a
# re-executed driver keeps the port block its parent picked rather than drawing
# a second one.
#
# The range stops well short of 65535 on purpose: the matrix walks upward from
# its base once per suite per major, several hundred ports, and a base above the
# ceiling once made every cluster fail with `invalid port number: "66009"`,
# which presents as a broken tree rather than as a bad constant.
pgc_pick_port() {
	printf '%s\n' "$(( 40000 + (${PGC_RUN_OWNER:-$$} % 20000) ))"
}
