import "builder";
import "strings";

pub gc struct Errors {
    items: [str],
    max_errors: int
}

pub gc struct Context {
    marker: bool
}

pub struct Root {
    marker: bool
}

pub struct NoArgs {
    marker: bool
}

pub gc struct ArgSpec {
    name: str,
    type_ref: str,
    required: bool,
    has_default: bool,
    default_json: bytes
}

pub fn context_new() -> Context {
    return Context { marker: false };
}

pub fn root_new() -> Root {
    return Root { marker: false };
}

pub fn no_args() -> NoArgs {
    return NoArgs { marker: false };
}

pub fn errors_new(max_errors: int) -> result[Errors, str] {
    if max_errors < 0 || max_errors > 1000 {
        return err("graphql errors: max_errors must be 0..1000");
    }
    return ok(Errors { items: [], max_errors: max_errors });
}

pub fn error_add(errors: Errors, message: str) -> result[bool, str] {
    if len(errors.items) >= errors.max_errors {
        return err("graphql execution: error count exceeds configured limit");
    }
    if len(message) > 4096 {
        return err("graphql execution: resolver error exceeds 4096 bytes");
    }
    push(errors.items, message);
    return ok(true);
}

pub fn write_json_string(out: builder.Bytes, value: str) -> result[bool, str] {
    return write_json_string_bounded(out, value, HARD_MAX_RESPONSE_BYTES);
}

pub fn write_json_string_bounded(out: builder.Bytes, value: str, max_bytes: int)
                                -> result[bool, str] {
    if max_bytes < 2 || max_bytes > HARD_MAX_RESPONSE_BYTES {
        return err("graphql JSON: string byte limit is outside its hard bound");
    }
    let raw = to_bytes(value);
    if !graphql_utf8_valid(raw) {
        return err("graphql JSON: string is not valid UTF-8");
    }
    out.write_byte(34);
    if out.size() > max_bytes { return err("graphql JSON: encoded string exceeds byte limit"); }
    let hex = to_bytes("0123456789abcdef");
    for i in 0..len(raw) {
        let c = raw[i];
        if c == 34 || c == 92 {
            out.write_byte(92);
            out.write_byte(c);
        } else if c == 8 { out.write(b"\\b"); }
        else if c == 9 { out.write(b"\\t"); }
        else if c == 10 { out.write(b"\\n"); }
        else if c == 12 { out.write(b"\\f"); }
        else if c == 13 { out.write(b"\\r"); }
        else if c < 32 {
            out.write(b"\\u00");
            out.write_byte(hex[c >> 4]);
            out.write_byte(hex[c & 15]);
        } else {
            out.write_byte(c);
        }
        if out.size() > max_bytes {
            return err("graphql JSON: encoded string exceeds byte limit");
        }
    }
    out.write_byte(34);
    if out.size() > max_bytes { return err("graphql JSON: encoded string exceeds byte limit"); }
    return ok(true);
}

pub fn response(data: bytes, errors: Errors, limits: Limits)
                -> result[bytes, str] {
    if !graphql_response_data_valid(data, limits) {
        return err("graphql response: data must be one bounded JSON object or null");
    }
    return graphql_write_response(data, errors, limits);
}

// For generated executors only: `data` is their own emitter's output, an
// object or null written field by field from typed values, so it is not
// parsed again here -- that re-parse was most of a small response's cost.
// Data from anywhere else goes through response, which checks it.
pub fn execution_response(data: bytes, errors: Errors, limits: Limits)
                          -> result[bytes, str] {
    return graphql_write_response(data, errors, limits);
}

fn graphql_write_response(data: bytes, errors: Errors, limits: Limits)
                          -> result[bytes, str] {
    if len(data) > limits.max_response_bytes {
        return err("graphql response: data exceeds configured byte limit");
    }
    let out = builder.new_bytes();
    out.write(b"{\"data\":");
    out.write(data);
    if len(errors.items) > 0 {
        out.write(b",\"errors\":[");
        for i in 0..len(errors.items) {
            if i > 0 { out.write_byte(44); }
            out.write(b"{\"message\":");
            let escaped = write_json_string_bounded(out, errors.items[i], limits.max_response_bytes);
            guard let _ok = escaped else let e = err_of(escaped) { return err(e); }
            out.write_byte(125);
            if out.size() > limits.max_response_bytes {
                return err("graphql response exceeds configured byte limit");
            }
        }
        out.write_byte(93);
    }
    out.write_byte(125);
    if out.size() > limits.max_response_bytes {
        return err("graphql response exceeds configured byte limit");
    }
    return ok(out.take());
}

pub fn failure(message: str, limits: Limits) -> result[bytes, str] {
    let created = errors_new(1);
    guard let errors = created else let e = err_of(created) { return err(e); }
    let safe = message;
    if len(safe) > 4096 { safe = strings.slice(safe, 0, 4096); }
    let added = error_add(errors, safe);
    guard let _ok = added else let e = err_of(added) { return err(e); }
    return response(b"null", errors, limits);
}

fn graphql_response_data_valid(data: bytes, limits: Limits) -> bool {
    let start = graphql_json_ws(data, 0);
    if start >= len(data) || (data[start] != 123 && data[start] != 110) {
        return false;
    }
    let budget = JSONBudget { nodes: 0, max_nodes: limits.max_nodes,
                              max_depth: limits.max_depth,
                              max_breadth: limits.max_breadth };
    let parsed = graphql_json_value_end(data, start, budget, 0);
    guard let end = parsed else { return false; }
    return graphql_json_ws(data, end) == len(data);
}

pub fn find_argument(doc: Document, selection: Selection, name: str)
                    -> opt[Argument] {
    for i in 0..len(selection.arguments) {
        if span_text(doc.source, selection.arguments[i].name) == name {
            return some(selection.arguments[i]);
        }
    }
    return none;
}

pub fn arguments_json(doc: Document, selection: Selection, variables: Variables,
                      operation: Operation, limits: Limits, specs: [ArgSpec])
                      -> result[bytes, str] {
    for i in 0..len(selection.arguments) {
        let actual = span_text(doc.source, selection.arguments[i].name);
        let known = false;
        for j in 0..len(specs) {
            if specs[j].name == actual { known = true; break; }
        }
        if !known { return err("graphql validation: unknown argument " + actual); }
    }
    let out = builder.new_bytes();
    out.write_byte(123);
    let written = 0;
    for i in 0..len(specs) {
        let spec = specs[i];
        let found = find_argument(doc, selection, spec.name);
        if let _ = found {
            guard let argument = found else { return err("graphql validation: argument lookup failed"); }
            let checked = validate_variable_type(doc, operation, argument.value,
                                                 spec.type_ref, spec.has_default);
            guard let _ok = checked else let e = err_of(checked) { return err(e); }
            if variable_missing(doc, argument.value, variables, operation) {
                if spec.has_default {
                    if written > 0 { out.write_byte(44); }
                    out.write_byte(34);
                    out.write(to_bytes(spec.name));
                    out.write(b"\":");
                    out.write(spec.default_json);
                    written = written + 1;
                    continue;
                }
                if spec.required {
                    return err("graphql validation: required variable for argument " + spec.name + " is missing");
                }
                continue;
            }
            let json_value = value_json(doc, argument.value, variables,
                                        operation, limits);
            guard let value = json_value else let e = err_of(json_value) { return err(e); }
            if written > 0 { out.write_byte(44); }
            out.write_byte(34);
            out.write(to_bytes(spec.name));
            out.write(b"\":");
            out.write(value);
            written = written + 1;
        } else if spec.has_default {
            if written > 0 { out.write_byte(44); }
            out.write_byte(34);
            out.write(to_bytes(spec.name));
            out.write(b"\":");
            out.write(spec.default_json);
            written = written + 1;
        } else if spec.required {
            return err("graphql validation: required argument " + spec.name + " is missing");
        }
        if out.size() > limits.max_response_bytes {
            return err("graphql arguments: encoded values exceed configured byte limit");
        }
    }
    out.write_byte(125);
    return ok(out.finish());
}

pub fn validate_variable_type(doc: Document, operation: Operation,
                              value: Value, expected_type: str,
                              argument_has_default: bool)
                              -> result[bool, str] {
    if value.kind != VALUE_VARIABLE { return ok(true); }
    let variable_name = span_text(doc.source, value.name);
    for i in 0..len(operation.variables) {
        let definition = operation.variables[i];
        if span_text(doc.source, definition.name) != variable_name { continue; }
        let actual = span_text(doc.source, definition.type_ref);
        let expected_nonnull = strings.has_suffix(expected_type, "!");
        let actual_nonnull = strings.has_suffix(actual, "!");
        let expected_shape = expected_type;
        let actual_shape = actual;
        if expected_nonnull { expected_shape = strings.slice(expected_type, 0, len(expected_type) - 1); }
        if actual_nonnull { actual_shape = strings.slice(actual, 0, len(actual) - 1); }
        if actual_shape != expected_shape &&
           !(actual_shape == "Int" && expected_shape == "Float") {
            return err("graphql validation: variable $" + variable_name +
                       " has type " + actual + ", expected " + expected_type);
        }
        if expected_nonnull && !actual_nonnull && !definition.has_default &&
           !argument_has_default {
            return err("graphql validation: nullable variable $" + variable_name +
                       " cannot be used for non-null " + expected_type);
        }
        return ok(true);
    }
    return err("graphql validation: variable $" + variable_name + " is undefined");
}
