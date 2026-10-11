# graphql package PRD

Status: v1 implementation is complete locally; cloud performance comparison is
still pending. No performance claim is made until that comparison is measured.
Date: 2026-10-11

## Goal

Build a standalone `graphql` slang package and a separate Go schema compiler.
The compiler reads GraphQL SDL and emits ordinary slang structs, typed input
codecs, deterministic field dispatchers, and named resolver-call wrappers.
The runtime parses bounded GraphQL operations and executes generated dispatch
code without reflection, closures, or compiler changes. An optional Zokor
adapter can later map HTTP requests and application context to this core API.

The public schema and resolver surface should be concise for agents: one SDL
file, generated types, and named `resolve_<Type>_<field>` functions. Generated
code is committed by the consuming application; `graphql` package downloads do
not require Go or a code generator at runtime.

## V1 scope

- Schema-first GraphQL SDL and generated typed object, input, enum, and scalar
  declarations. Built-in scalars are `Int`, `Float`, `String`, `Boolean`, and
  `ID`; custom scalars require explicit generated codecs and are never guessed.
- Query and mutation operations, variables/defaults, named operation selection,
  aliases, arguments, nested selection sets, fragment definitions/spreads,
  inline fragments on supported object types, and standard `@skip`/`@include`
  directives.
- A bounded parser and validator that rejects unknown fields/arguments,
  invalid selections, variable/type mismatches, duplicate definitions,
  ambiguous operations, and unsupported syntax before calling resolvers.
- Generated direct dispatch for root and nested fields. Resolver functions are
  ordinary named slang functions with generated typed parent/argument types;
  no captured state or global dynamic registry is required.
- Schema-aware validation and execution for nested objects, input coercion,
  defaults, aliases, fragments, directives, `__typename`, and nullable error
  propagation. Unknown input fields and incompatible output shapes fail before
  returning ambiguous JSON.
- Built-in scalar coercion follows the GraphQL input boundary: `Int` values
  must fit signed 32-bit range, and integer `ID` inputs become string values.
- JSON response construction through a builder. Resolve and encode each field
  as it is visited instead of building a second full dynamic result tree.
  Return `data`, a bounded `errors` array, and optional request-local partial
  data according to the GraphQL execution rules supported below.
- A small explicit batching primitive for resolver code, with a caller-owned
  bounded key list and one batch fetch per flush. No hidden per-request global
  cache and no implicit database access.

## Generated API and execution model

- `graphqlc` is a Go executable under `cmd/graphqlc/`; it parses SDL and emits
  one deterministic slang source file. `graphql.project` records source paths
  and output path; generator behavior is covered by golden tests.
- SDL names map to ordinary slang identifiers. Name collisions and unsupported
  constructs stop generation with a source location and actionable message.
- Every generated object field gets a named typed resolver signature. A
  resolver receives the parent value, typed arguments, and a caller-owned
  context type through an application-supplied resolver function convention.
  Generated dispatch calls that function directly.
- Runtime query AST nodes hold offsets into the original query bytes where
  practical; decoded names and values allocate only when necessary. Variables
  are decoded into generated operation input structs, not an untyped JSON tree.
- The runtime provides parse, validate, execute, and serialize phases so apps
  can validate or reject operations before opening database work. Persisted
  query caches remain an application or Zokor policy.

## Bounds and security

- Default query size: 64 KiB; default maximum depth: 32; maximum AST nodes:
  10,000; maximum aliases: 1,000; maximum fragments: 128; maximum variables:
  256; maximum response bytes: 4 MiB. All have validated lowerable limits,
  with hard caps documented by the package.
- Count depth, nodes, aliases, and fragment expansion during parsing/validation;
  reject before resolver execution. Detect fragment cycles and cap total
  expansion to prevent exponential work.
- Parse UTF-8 and GraphQL string escapes strictly. Reject duplicate object
  fields/arguments/variables and malformed numeric literals rather than
  accepting ambiguous input.
- Apply resolver field authorization in application code; schema visibility is
  not an authorization boundary. Never log query variables or resolver values
  by default.
- Resolver errors expose bounded safe messages; internal errors remain in
  application logs controlled by the caller. Do not return database error text
  automatically.

## Performance and validation

- Golden generator tests cover SDL type mapping, nullability, enums, input
  fields, nested objects, unions/interfaces only if code generation can emit
  exhaustive direct dispatch, and errors for unsupported constructs.
- Runtime tests cover operation syntax, aliases, variables/defaults, fragments
  and cycles, directives, validation, depth/node/size caps, resolver errors,
  partial results, UTF-8, output escaping, `Int` range checks, and `ID`
  integer coercion. Generated consumer coverage checks list-item nullability
  when an output value exceeds its byte bound.
- Consumer compile/run test uses generated code and named resolvers; no dynamic
  reflection or compiler feature is allowed.
- The standalone package runner builds, vets, tests and exercises the Go
  generator, compares deterministic generated output, runs a generated
  consumer, and executes runtime and consumer coverage under minor-GC
  verification. Tests live outside `src/graphql`, which is the installable
  package source.
- Compare parser/validation/response throughput, p50/p99 latency, allocations,
  and peak RSS against a Go GraphQL implementation using the same schema and
  operations. Run performance comparisons on the configured cloud benchmark
  environment with randomized ABBA order; this remains outstanding, and local
  runs are smoke tests only.
- Run full slang tests, generated-C warning sweep, generator determinism, and
  GC-minor verification for request parsing/execution allocations before tag.

## Non-goals for v1

Subscriptions and WebSockets; GraphQL introspection; schema federation;
automatic database batching; remote schema fetching; reflection; arbitrary
custom scalars without generated codecs; hidden global caches; new slang syntax
or compiler/runtime changes. The standalone package may be wrapped by Zokor
without coupling the language standard library to GraphQL.

## Release boundary

The runtime package is source-only under `src/graphql`. The Go schema compiler
and benchmark data are excluded from package downloads. Generated schema code
is part of an application repository. A future `graphql-zokor` adapter may
supply HTTP route integration and request context, but the core remains
framework-independent.
