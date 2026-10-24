// Appended to the consumer's resolvers by run.sh. Executes the consumer's
// Fetch operation (an input-object argument, a fragment, a directive and
// __typename) N times through one entry point and prints the time per
// request.
import "proc";
import "time";

let query = "query Fetch($id: ID!, $who: String = \"agent\", $showRole: Boolean = true, $filter: UserFilter!) { " +
    "hello(who: $who, filter: $filter) user(id: $id) { ...UserFields __typename } __typename } " +
    "fragment UserFields on User { name role @include(if: $showRole) }";
let variables = b"{\"id\":\"7\",\"filter\":{\"tenantId\":\"tenant-1\",\"scopes\":{\"id\":\"scope-1\"}}}";
let limits = __graphql.default_limits();
let args = proc.args();
if len(args) != 3 || (args[1] != "execute" && args[1] != "prepared" && args[1] != "cached") {
    println("usage: execute execute|prepared|cached <iterations>");
    exit(2);
}
let mode = args[1];
let n = to_int(args[2]) ?? 0;
if n < 1 {
    println("iterations must be a positive integer");
    exit(2);
}
let prepared_result = graphql_prepare(query, "Fetch", limits);
guard let prepared = prepared_result else let e = err_of(prepared_result) { panic(e); }
let cache_result = __graphql.plan_cache_new(16, limits);
guard let cache = cache_result else let e = err_of(cache_result) { panic(e); }
let total = 0;
let started = time.mono() as int;
for i in 0..n {
    let r: result[bytes, str] = err("no mode ran");
    if mode == "execute" {
        r = graphql_execute(query, "Fetch", variables, __graphql.context_new(), limits);
    } else if mode == "prepared" {
        r = graphql_execute_prepared(prepared, variables, __graphql.context_new());
    } else {
        r = graphql_execute_cached(cache, query, "Fetch", variables, __graphql.context_new(), limits);
    }
    guard let out = r else let e = err_of(r) { panic(e); }
    total += len(out);
}
let elapsed = (time.mono() as int) - started;
println(mode + " ns/op " + to_str(elapsed / n) + " bytes " + to_str(total / n));
