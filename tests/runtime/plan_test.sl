fn graphql_test_known_type(name: str) -> bool {
    return name == "User";
}

fn graphql_test_plan_ok(cache: PlanCache, query: str, operation_name: str,
                        limits: Limits) -> Plan {
    let planned = plan(cache, query, operation_name, limits, graphql_test_known_type);
    guard let p = planned else let e = err_of(planned) { panic(e); }
    return p;
}

fn test_graphql_plan_cache_hits_after_first_plan() {
    let limits = default_limits();
    let made = plan_cache_new(4, limits);
    guard let cache = made else let e = err_of(made) { panic(e); }
    let query = "query A { user { name } } query B { user { id } }";
    let first = graphql_test_plan_ok(cache, query, "A", limits);
    assert(plan_cache_misses(cache) == 1 && plan_cache_hits(cache) == 0, "first plan misses");
    let again = graphql_test_plan_ok(cache, query, "A", limits);
    assert(plan_cache_hits(cache) == 1 && plan_cache_size(cache) == 1, "same plan hits");
    assert(operation_name(again.document, again.operation) == "A" &&
           operation_name(first.document, first.operation) == "A", "operation kept");
    // Another operation of a cached document is validated once, then hits.
    let other = graphql_test_plan_ok(cache, query, "B", limits);
    assert(operation_name(other.document, other.operation) == "B", "second operation");
    assert(plan_cache_misses(cache) == 2 && plan_cache_size(cache) == 1,
           "second operation shares the document entry");
    let other_again = graphql_test_plan_ok(cache, query, "B", limits);
    assert(plan_cache_hits(cache) == 2 &&
           operation_name(other_again.document, other_again.operation) == "B",
           "second operation hits");
}

fn test_graphql_plan_cache_evicts_oldest_and_keeps_bound() {
    let limits = default_limits();
    let made = plan_cache_new(2, limits);
    guard let cache = made else let e = err_of(made) { panic(e); }
    graphql_test_plan_ok(cache, "{ a }", "", limits);
    graphql_test_plan_ok(cache, "{ b }", "", limits);
    graphql_test_plan_ok(cache, "{ c }", "", limits);
    assert(plan_cache_size(cache) == 2, "cache stays at max_entries");
    graphql_test_plan_ok(cache, "{ c }", "", limits);
    assert(plan_cache_hits(cache) == 1, "newest entry kept");
    graphql_test_plan_ok(cache, "{ a }", "", limits);
    assert(plan_cache_hits(cache) == 1 && plan_cache_misses(cache) == 4,
           "oldest entry was evicted");
    assert(plan_cache_size(cache) == 2, "eviction keeps the bound");
}

fn test_graphql_plan_cache_never_keeps_failures() {
    let limits = default_limits();
    let made = plan_cache_new(4, limits);
    guard let cache = made else let e = err_of(made) { panic(e); }
    let bad = plan(cache, "{ user {", "", limits, graphql_test_known_type);
    if let _b = bad { panic("malformed query planned"); }
    let unknown = plan(cache, "{ ... on Order { id } }", "", limits, graphql_test_known_type);
    if let _u = unknown {
        panic("unknown type condition planned");
    } else let e = err_of(unknown) {
        assert(e == "graphql validation: unknown object type Order", "type condition error: " + e);
    }
    let missing = plan(cache, "query A { a } query B { b }", "", limits, graphql_test_known_type);
    if let _m = missing { panic("ambiguous operation planned"); }
    assert(plan_cache_size(cache) == 0, "failed plans are not kept");
}

fn test_graphql_plan_cache_bypassed_for_other_limits() {
    let made = plan_cache_new(4, default_limits());
    guard let cache = made else let e = err_of(made) { panic(e); }
    let tight_result = new_limits(8, 4, 100, 10, 4, 4, 10, 1024);
    guard let tight = tight_result else let e = err_of(tight_result) { panic(e); }
    let refused = plan(cache, "{ user { name } }", "", tight, graphql_test_known_type);
    if let _r = refused { panic("query over the tighter byte limit planned"); }
    graphql_test_plan_ok(cache, "{ a }", "", tight);
    assert(plan_cache_size(cache) == 0 && plan_cache_hits(cache) == 0 &&
           plan_cache_misses(cache) == 0, "other limits never touch the cache");
}

fn test_graphql_plan_cache_rejects_bad_configuration() {
    let zero = plan_cache_new(0, default_limits());
    if let _z = zero { panic("zero-entry cache created"); }
    let huge = plan_cache_new(HARD_MAX_PLANS + 1, default_limits());
    if let _h = huge { panic("cache above the hard maximum created"); }
}

fn test_graphql_selection_names_are_precomputed() {
    let parsed = parse("{ u: user { ... on User { n: name } ...F } } fragment F on User { id }",
                       default_limits());
    guard let doc = parsed else let e = err_of(parsed) { panic(e); }
    let user = doc.operations[0].selections[0];
    assert(user.name_text == "user" && user.response_text == "u", "alias response text");
    let inline = user.children[0];
    assert(inline.kind == SELECTION_INLINE && inline.condition_text == "User",
           "inline fragment condition text");
    assert(inline.children[0].response_text == "n" && inline.children[0].name_text == "name",
           "nested alias text");
    let spread = user.children[1];
    assert(spread.kind == SELECTION_SPREAD && spread.name_text == "F", "spread name text");
    assert(doc.fragments[0].name_text == "F" && doc.fragments[0].condition_text == "User",
           "fragment texts");
}

fn test_graphql_execution_response_matches_checked_response() {
    let made = errors_new(4);
    guard let errors = made else let e = err_of(made) { panic(e); }
    let added = error_add(errors, "resolver failed");
    guard let _added = added else let e = err_of(added) { panic(e); }
    let data = b"{\"a\":[1,{\"b\":null}]}";
    let checked = response(data, errors, default_limits());
    guard let checked_bytes = checked else let e = err_of(checked) { panic(e); }
    let trusted = execution_response(data, errors, default_limits());
    guard let trusted_bytes = trusted else let e = err_of(trusted) { panic(e); }
    assert(checked_bytes == trusted_bytes, "same envelope from both paths");
    // response still refuses data that is not one JSON object.
    let refused = response(b"{\"a\":1} {}", errors, default_limits());
    if let _r = refused { panic("response accepted two values"); }
    let small_result = new_limits(1024, 8, 100, 10, 4, 4, 10, 8);
    guard let small = small_result else let e = err_of(small_result) { panic(e); }
    let over = execution_response(data, errors, small);
    if let _o = over { panic("execution response over its byte limit"); }
}
