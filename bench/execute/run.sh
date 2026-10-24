#!/bin/sh
# Time and GC allocations per request for the consumer's Fetch operation,
# through graphql_execute, graphql_execute_prepared and graphql_execute_cached.
#   bench/execute/run.sh            report
#   bench/execute/run.sh --check    also fail above the allocation budgets
# Allocations are exact and machine-independent, so they are the budget;
# time is reported only.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
slangc=${SLANGC:-slangc}
iterations=${ITERATIONS:-20000}
# Per request, this operation. Before precomputed selection names and the
# unchecked executor response: 949 / 618 (cached did not exist).
budget_execute=840
budget_prepared=495
budget_cached=500

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/graphql-execute-bench.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT HUP INT TERM
# The consumer's resolvers are everything before its first top-level `let`.
awk '/^let /{exit} {print}' "$repo/tests/consumer/main.sl" > "$run_dir/main.sl"
cat "$repo/bench/execute/bench.sl" >> "$run_dir/main.sl"
cp "$repo/tests/consumer/schema.gen.sl" "$run_dir/"
ln -s "$repo/src/graphql" "$run_dir/graphql"
(cd "$run_dir" && "$slangc" main.sl -o execute >/dev/null)

status=0
for mode in execute prepared cached; do
    out=$(cd "$run_dir" && SLANG_GC_STAT=1 ./execute "$mode" "$iterations" 2>"$run_dir/stat")
    allocs=$(grep -oE 'allocs=[0-9]+' "$run_dir/stat" | head -1 | cut -d= -f2)
    bytes=$(grep -oE 'alloc_bytes=[0-9]+' "$run_dir/stat" | head -1 | cut -d= -f2)
    per_op=$((allocs / iterations))
    printf '%s, %s allocs/op, %s bytes/op\n' "$out" "$per_op" "$((bytes / iterations))"
    if [ "${1:-}" = "--check" ]; then
        eval "budget=\$budget_$mode"
        if [ "$per_op" -gt "$budget" ]; then
            echo "FAIL $mode: $per_op allocations per request, budget $budget" >&2
            status=1
        fi
    fi
done
exit $status
