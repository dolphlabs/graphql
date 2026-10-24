// Planning is everything about a request that depends only on its query
// text: parsing, the schema check of type conditions, and picking and
// validating the operation. It was about a quarter of a small request's
// time, and clients send the same few queries again and again, so a
// PlanCache keeps the results. The cache is explicit and bounded: the
// caller creates it, sizes it and passes it to graphql_execute_cached;
// nothing is cached behind a caller's back. A planned document is never
// changed after parsing, so requests on different tasks share it safely.

pub let HARD_MAX_PLANS = 65536;

pub gc struct Plan {
    document: Document,
    operation: Operation
}

// One parsed document, with each operation name validated against it so far.
gc struct PlanEntry {
    document: Document,
    operations: map[str]Operation
}

pub gc struct PlanCache {
    limits: Limits,
    max_entries: int,
    entries: map[str]PlanEntry,
    // Insertion order for eviction: a ring of the cached query texts, the
    // oldest at `next` once it is full.
    ring: [str],
    next: int,
    lock: mutex,
    hits: int,
    misses: int
}

// A cache of at most max_entries documents, for requests parsed under
// `limits`. It holds up to max_entries * limits.max_query_bytes of query text
// plus each document's syntax tree; size it for the operations a service
// actually serves.
pub fn plan_cache_new(max_entries: int, limits: Limits) -> result[PlanCache, str] {
    if max_entries < 1 || max_entries > HARD_MAX_PLANS {
        return err("graphql plan cache: max_entries must be 1..65536");
    }
    if !graphql_limits_valid(limits) {
        return err("graphql plan cache: invalid limits");
    }
    return ok(PlanCache {
        limits: limits,
        max_entries: max_entries,
        entries: {},
        ring: [],
        next: 0,
        lock: make_mutex(),
        hits: 0,
        misses: 0
    });
}

// Plans without a cache: parse, check every type condition with known_type
// (the generated schema's graphql_schema_has_object_type), then select and
// validate the operation.
pub fn plan_uncached(query: str, operation_name: str, limits: Limits,
                     known_type: fn(str) -> bool) -> result[Plan, str] {
    let parsed = parse(query, limits);
    guard let doc = parsed else let e = err_of(parsed) { return err(e); }
    let conditions_result = type_conditions(doc, limits);
    guard let conditions = conditions_result else let e = err_of(conditions_result) {
        return err(e);
    }
    for i in 0..len(conditions) {
        if !known_type(conditions[i]) {
            return err("graphql validation: unknown object type " + conditions[i]);
        }
    }
    let validated = validate_document(doc, operation_name);
    guard let op = validated else let e = err_of(validated) { return err(e); }
    return ok(Plan { document: doc, operation: op });
}

// The cached plan for (query, operation_name), planning and keeping it on a
// miss. Only plans that succeed are kept, so invalid queries cannot fill the
// cache, and a full cache drops its oldest document. Called with limits
// other than the cache's, it plans without the cache: a document parsed
// under looser limits must not be reused under tighter ones.
pub fn plan(cache: PlanCache, query: str, operation_name: str, limits: Limits,
            known_type: fn(str) -> bool) -> result[Plan, str] {
    if !graphql_limits_equal(cache.limits, limits) {
        return plan_uncached(query, operation_name, limits, known_type);
    }
    mutex_lock(cache.lock);
    let cached = has(cache.entries, query);
    let entry_found = cached && has(cache.entries[query].operations, operation_name);
    if entry_found {
        let entry = cache.entries[query];
        let found = Plan { document: entry.document,
                           operation: entry.operations[operation_name] };
        cache.hits = cache.hits + 1;
        mutex_unlock(cache.lock);
        return ok(found);
    }
    cache.misses = cache.misses + 1;
    mutex_unlock(cache.lock);

    // Parse and validate without holding the lock; two tasks missing on the
    // same query both plan it, and the first to finish is kept.
    let planned = plan_uncached(query, operation_name, limits, known_type);
    guard let made = planned else let e = err_of(planned) { return err(e); }
    mutex_lock(cache.lock);
    if has(cache.entries, query) {
        let entry = cache.entries[query];
        if !has(entry.operations, operation_name) {
            entry.operations[operation_name] = made.operation;
        }
    } else {
        if len(cache.ring) < cache.max_entries {
            push(cache.ring, query);
        } else {
            del(cache.entries, cache.ring[cache.next]);
            cache.ring[cache.next] = query;
            cache.next = (cache.next + 1) % cache.max_entries;
        }
        let operations: map[str]Operation = {};
        operations[operation_name] = made.operation;
        cache.entries[query] = PlanEntry { document: made.document,
                                           operations: operations };
    }
    mutex_unlock(cache.lock);
    return ok(made);
}

pub fn plan_cache_size(cache: PlanCache) -> int {
    mutex_lock(cache.lock);
    let n = len(cache.entries);
    mutex_unlock(cache.lock);
    return n;
}

pub fn plan_cache_hits(cache: PlanCache) -> int {
    mutex_lock(cache.lock);
    let n = cache.hits;
    mutex_unlock(cache.lock);
    return n;
}

pub fn plan_cache_misses(cache: PlanCache) -> int {
    mutex_lock(cache.lock);
    let n = cache.misses;
    mutex_unlock(cache.lock);
    return n;
}

fn graphql_limits_equal(a: Limits, b: Limits) -> bool {
    return a.max_query_bytes == b.max_query_bytes && a.max_depth == b.max_depth &&
           a.max_nodes == b.max_nodes && a.max_aliases == b.max_aliases &&
           a.max_fragments == b.max_fragments && a.max_variables == b.max_variables &&
           a.max_breadth == b.max_breadth && a.max_response_bytes == b.max_response_bytes;
}
