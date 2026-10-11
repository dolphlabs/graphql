# GraphQL execution performance PRD

Status: implemented and locally measured (2026-10-11).

## Problem

Repeated GraphQL requests reparsed the same query and allocated a fresh AST
each time. Generated validation also normalized and decoded typed resolver
arguments once during validation and again during execution. The initial local
one-worker comparison was about 3.6x slower than Go and allocated about 653
slang GC objects per request.

## Design delivered

- Generated validation stores normalized typed arguments in a bounded,
  request-local execution plan. Execution reuses them without weakening the
  validate-before-resolver rule.
- `graphql_prepare` parses a bounded query and selects its operation once.
  The caller owns the `graphql_PreparedQuery`; `graphql_execute_prepared`
  reuses its AST and selected operation for each request.
- Prepared execution still parses variables and validates fields, arguments,
  variable values, directives and selection budgets for every request before
  invoking resolvers. Query limits are captured by the handle at preparation.
- `graphql_execute` remains the parse-per-request API. It shares the internal
  parser and document executor without allocating a prepared handle.
- There is no global query cache. A prepared handle retains its AST until it
  becomes unreachable; callers should keep one handle per frequently reused
  operation and treat it as read-only.

## Validation

- Generator unit tests and `go vet` pass; the generated consumer fixture is
  deterministic and current.
- The consumer verifies direct/prepared response byte equality, repeated use,
  and identical field-validation errors.
- On the prior generator, this consumer failed to compile with
  `call to undefined function 'graphql_prepare'`; the current generator builds
  it and all response-parity checks pass.
- `tests/run.sh` passes, including its 10 runtime tests normally and under
  minor-GC verification. The consumer verifier reports 0 missed pointers.

## Local benchmark

This is a local macOS CPU smoke test, not an HTTP server or cloud result. The
same operation, variables, generated schema and resolver were used for slang
and `graph-gophers/graphql-go` v1.10.2. Throughput ran 100,000 requests;
latency sampled 10,000 requests. Three interleaved rounds produced six samples
per implementation. Values below are medians. Allocation accounting differs
between slang's GC and Go's runtime, so compare it directionally.

| Path | Throughput | p50 | p99 | Allocated bytes/request | Objects/request |
|---|---:|---:|---:|---:|---:|
| slang `graphql_execute` | 14,878 req/s | 54.5 µs | 188.5 µs | 51.8 KB | 494 |
| slang prepared | 34,822 req/s | 25.5 µs | 138.5 µs | 34.6 KB | 278 |
| Go `Schema.Exec` | 47,999 req/s | 19.3 µs | 87.1 µs | 8.7 KB | 162 |

The prepared API is 2.34x the one-shot slang throughput on this query and
reduces median p50 by 53% and p99 by 27%. It remains about 1.38x slower than Go
in throughput, with p50 1.32x and p99 1.59x higher. The one-shot path remains
about 3.23x slower than Go. These are CPU-only measurements; RSS was not
available from the sandbox's process accounting, and network/server behavior
remains unmeasured.

## Next measurement

Benchmark the prepared path under a real HTTP server with multiple persisted
operations and concurrent requests. Include retained AST RSS and server p99
before making a production performance claim.
