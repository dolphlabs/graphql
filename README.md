# graphql

Standalone schema-first GraphQL support for slang. `graphqlc` turns SDL into
ordinary typed structs, input normalizers, direct resolver calls, validation,
and a request executor. There is no reflection, resolver registry, closure,
or dynamic result tree. The package does not import `http`; a slang HTTP route
or Zokor adapter owns transport and request policy.

The design and current limits are recorded in [GRAPHQL_PRD.md](GRAPHQL_PRD.md).

## Install and generate

```text
pkg graphql git https://github.com/dolphlabs/graphql.git tag v0.1.0 dir src/graphql
```

Build the standalone generator with Go 1.22 or later:

```sh
cd cmd/graphqlc
go build -o ../../bin/graphqlc .
cd ../..
./bin/graphqlc -schema schema.graphql -out src/generated/schema.gen.sl
```

The generated file is committed with the app. Building the app then needs only
`slangc`; it does not need Go or the SDL compiler.

```graphql
enum Role { USER ADMIN }
input UserFilter { role: Role active: Boolean = true }
type Query { user(id: ID!): User }
type User { id: ID! name: String! role: Role! }
```

By default, generated resolvers use `graphql.Context`. Pass another named
slang type with `-context app.RequestContext` when the app owns its context.
Schema names that would collide with generated identifiers stop generation
with an error. Run the generator with `-check` in CI to detect stale output.

## Write resolvers and execute

Implement one named resolver for every object field. Query and mutation root
fields receive `graphql.Root`; nested fields receive their typed parent.
Fields without arguments receive `graphql.NoArgs`. Nullable GraphQL types map
to `opt[T]`, including each nullable level inside a list.

```slang
fn resolve_Query_user(parent: graphql.Root, args: Query_user_Args,
                      ctx: graphql.Context) -> result[opt[User], str] {
    return ok(some(User { id: args.id, name: "Ada", role: Role.USER }));
}

fn resolve_User_name(parent: User, args: graphql.NoArgs,
                     ctx: graphql.Context) -> result[str, str] {
    return ok(parent.name);
}

let response = graphql_execute(
    "query User($id: ID!) { user(id: $id) { name } }", "User",
    b"{\"id\":\"u-1\"}", graphql.context_new(), graphql.default_limits());

let prepared_result = graphql_prepare(
    "query User($id: ID!) { user(id: $id) { name } }", "User",
    graphql.default_limits());
guard let prepared = prepared_result else let e = err_of(prepared_result) { panic(e); }
let prepared_response = graphql_execute_prepared(
    prepared, b"{\"id\":\"u-1\"}", graphql.context_new());
```

`graphql_execute` parses and validates the full operation before calling any
resolver. It expands fragments within a shared selection budget, checks fields,
arguments, variables, input objects and selection shapes, then calls generated
resolver wrappers directly. Mutations execute their root fields in order.
For a persisted or frequently reused operation, call `graphql_prepare` once and
keep its `graphql_PreparedQuery` handle, then call `graphql_execute_prepared`
with each request's variables and context. Preparation bounds and parses the
query and selects its operation; execution still validates request variables,
field arguments and selections before any resolver runs. The handle retains
the parsed document until it becomes unreachable, and keeps the limits chosen
at preparation time. Use one handle per operation and treat it as read-only.
`graphql_execute` remains the convenient parse-per-request path.
When clients resend the same query text without persisting it, create one
bounded `__graphql.PlanCache` at startup (`plan_cache_new(max_entries,
limits)`) and call `graphql_execute_cached(cache, query, operation_name,
variables, context, limits)`: the first request for a query plans it as
`graphql_prepare` would, later ones reuse that plan. Only queries that parse
and select an operation are kept, the oldest is dropped when the cache is
full, and a call with other limits plans without the cache. The cache holds
up to `max_entries` query texts and their syntax trees; size it for the
operations the service serves. Field and variable validation still run on
every request.
The returned `bytes` contains the GraphQL JSON envelope. Parse and validation
failures return `data: null` with a bounded `errors` array. A resolver failure
uses the safe message `resolver failed`; its private error value is not sent to
the client. Nullable failures produce partial data, while non-null failures
bubble to the nearest nullable field.

## Performance smoke results

On the same one-worker macOS query benchmark, prepared execution returned
34,822 requests/s with 25.5 µs p50 and 138.5 µs p99; Go
`graph-gophers/graphql-go` v1.10.2 returned 47,999 requests/s with 19.3 µs
p50 and 87.1 µs p99. The parse-per-request slang API returned 14,878
requests/s. Prepared execution cuts its allocation count from 494 to 278
objects per request. These are local CPU-only smoke numbers, not server or
cloud results; the full table and method are in
[GRAPHQL_PERFORMANCE_PRD.md](GRAPHQL_PERFORMANCE_PRD.md).
`bench/execute/run.sh` reports time and allocations per request for the
consumer's larger Fetch operation through all three entry points, and
`tests/run.sh` fails above its allocation budgets.

The runtime supports query and mutation operations, aliases, variables and
defaults, nested selections, fragments and inline fragments on object types,
`@skip` and `@include`, enums, input objects and the built-in scalars `Int`,
`Float`, `String`, `Boolean` and `ID`. `Int` inputs are limited to signed
32-bit values, and integer `ID` inputs are coerced to strings. `__typename` is
supported. Duplicate response names are rejected to avoid ambiguous output.

Subscriptions, schema introspection, federation, interfaces, unions, custom
scalars, custom directives and block strings are outside v1. SDL names must
map to valid slang identifiers; code generation refuses collisions rather
than renaming schema fields silently.

## Bounds and batching

Defaults cap a query at 64 KiB, AST nodes at 10,000, depth at 32, breadth at
1,000, aliases at 1,000, fragments at 128, variables at 256 and output at
4 MiB. Hard caps are 1 MiB query bytes, 100,000 nodes, depth 64, breadth
10,000, 10,000 aliases, 1,024 fragments, 4,096 variables and 64 MiB output.
Use `graphql.new_limits(...)` to lower or raise defaults within those hard
caps. Variable JSON and response JSON reject malformed UTF-8, duplicate keys,
invalid number syntax and unpaired Unicode surrogates.

`graphql.batch_new`, `batch_queue` and `batch_flush` provide an explicit,
caller-owned, request-local batching primitive. Set its key cap for the
resolver's workload; there is no hidden cache or database dependency.

## Tests and package contents

```sh
SLANGC=slangc sh tests/run.sh
```

The runner checks generator goldens and determinism, compiles and runs a
generated consumer, exercises query/mutation execution and hostile inputs,
runs generated requests and runtime tests under minor-GC verification, and
keeps tests outside the installed source directory. The Go generator, tests
and benchmark files are excluded from dependency downloads; only
`src/graphql` is installed. A multi-operation HTTP server benchmark, retained
AST RSS measurement and cloud comparison remain to be collected.
