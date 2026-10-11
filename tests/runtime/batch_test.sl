fn load_test_users(ids: [int]) -> result[map[int]str, str] {
    let users: map[int]str = {};
    for id in ids { users[id] = "user-" + to_str(id); }
    return ok(users);
}

fn test_graphql_explicit_bounded_batch() {
    let created = batch_new(2, load_test_users);
    guard let batch = created else let e = err_of(created) { panic(e); }
    let first = batch_queue(batch, 7);
    guard let _first = first else let e = err_of(first) { panic(e); }
    let duplicate = batch_queue(batch, 7);
    guard let added = duplicate else let e = err_of(duplicate) { panic(e); }
    assert(!added, "duplicate key queued once");
    let second = batch_queue(batch, 8);
    guard let _second = second else let e = err_of(second) { panic(e); }
    assert(is_err(batch_queue(batch, 9)), "key cap enforced before flush");
    assert(len(batch_pending(batch)) == 2, "pending keys remain caller-visible");
    let flushed = batch_flush(batch);
    guard let count = flushed else let e = err_of(flushed) { panic(e); }
    assert(count == 2, "one batch fetch returns both values");
    guard let user = batch_get(batch, 8) else { panic("batch result missing"); }
    assert(user == "user-8", "fetched value is cached request-locally");
    assert(len(batch_pending(batch)) == 0, "flush clears queued keys");
}
