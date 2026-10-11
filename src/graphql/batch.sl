// Explicit request-local batching. The caller chooses when to queue keys,
// when to flush, and how the one fetch is performed; there is no hidden
// cache, scheduler hook, or database dependency.
pub gc struct Batch[K, V] {
    pending: [K],
    values: map[K]V,
    max_keys: int,
    load: fn([K]) -> result[map[K]V, str]
}

pub fn batch_new[K, V](max_keys: int,
                       load: fn([K]) -> result[map[K]V, str])
                       -> result[Batch[K, V], str] {
    if max_keys < 1 || max_keys > 100000 {
        return err("graphql batch: max_keys must be 1..100000");
    }
    let pending: [K] = [];
    let values: map[K]V = {};
    return ok(Batch[K, V] {
        pending: pending,
        values: values,
        max_keys: max_keys,
        load: load
    });
}

pub fn batch_queue[K, V](batch: Batch[K, V], key: K) -> result[bool, str] {
    if has(batch.values, key) || graphql_batch_has(batch.pending, key) {
        return ok(false);
    }
    if len(batch.pending) >= batch.max_keys {
        return err("graphql batch: key limit reached; flush before queueing more");
    }
    push(batch.pending, key);
    return ok(true);
}

pub fn batch_pending[K, V](batch: Batch[K, V]) -> [K] {
    return batch.pending;
}

pub fn batch_get[K, V](batch: Batch[K, V], key: K) -> opt[V] {
    if has(batch.values, key) { return some(batch.values[key]); }
    return none;
}

pub fn batch_flush[K, V](batch: Batch[K, V]) -> result[int, str] {
    if len(batch.pending) == 0 { return ok(0); }
    let loaded_result = batch.load(batch.pending);
    guard let loaded = loaded_result else let e = err_of(loaded_result) { return err(e); }
    let accepted = 0;
    for key, value in loaded {
        if graphql_batch_has(batch.pending, key) {
            batch.values[key] = value;
            accepted = accepted + 1;
        }
    }
    batch.pending = [];
    return ok(accepted);
}

fn graphql_batch_has[K](keys: [K], needle: K) -> bool {
    for i in 0..len(keys) {
        if keys[i] == needle { return true; }
    }
    return false;
}
