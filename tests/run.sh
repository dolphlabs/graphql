#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
slangc=${SLANGC:-slangc}
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/graphql-test.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT HUP INT TERM

(cd "$repo/cmd/graphqlc" && go test ./... && go vet ./... && go build -o "$run_dir/graphqlc" .)
"$run_dir/graphqlc" -schema "$repo/tests/schema/schema.graphql" \
    -out "$run_dir/schema.gen.sl"
cmp "$repo/tests/consumer/schema.gen.sl" "$run_dir/schema.gen.sl"
"$run_dir/graphqlc" -schema "$repo/tests/schema/schema.graphql" \
    -out "$repo/tests/consumer/schema.gen.sl" -check

mkdir "$run_dir/consumer"
cp "$repo/tests/consumer/main.sl" "$repo/tests/consumer/schema.gen.sl" \
    "$run_dir/consumer/"
ln -s "$repo/src/graphql" "$run_dir/consumer/graphql"
actual=$(cd "$run_dir/consumer" && "$slangc" main.sl --run)
expected=$(cat "$repo/tests/consumer/expected.txt")
if [ "$actual" != "$expected" ]; then
    printf '%s\n' "GraphQL generated consumer output mismatch" >&2
    printf '%s\n' "--- expected ---" "$expected" "--- actual ---" "$actual" >&2
    exit 1
fi
printf '%s\n' "$actual"

gc_actual=$(cd "$run_dir/consumer" && SLANG_GC_VERIFY_MINOR=1 \
    SLANG_GC_NURSERY_KB=16 "$slangc" main.sl --run)
if [ "$gc_actual" != "$expected" ]; then
    printf '%s\n' "GraphQL generated consumer output changed under minor-GC verification" >&2
    exit 1
fi

mkdir "$run_dir/runtime-tests"
cp "$repo"/src/graphql/*.sl "$repo"/tests/runtime/*.sl "$run_dir/runtime-tests/"
(cd "$run_dir/runtime-tests" && "$slangc" test . -v)
(cd "$run_dir/runtime-tests" && SLANG_GC_VERIFY_MINOR=1 \
    SLANG_GC_NURSERY_KB=16 "$slangc" test . -v)
