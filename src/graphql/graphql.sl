import "builder";
import "strings";

pub let VALUE_NULL = 0;
pub let VALUE_BOOL = 1;
pub let VALUE_INT = 2;
pub let VALUE_FLOAT = 3;
pub let VALUE_STRING = 4;
pub let VALUE_ENUM = 5;
pub let VALUE_VARIABLE = 6;
pub let VALUE_LIST = 7;
pub let VALUE_OBJECT = 8;

pub let SELECTION_FIELD = 1;
pub let SELECTION_SPREAD = 2;
pub let SELECTION_INLINE = 3;

pub let OP_QUERY = 1;
pub let OP_MUTATION = 2;

pub let DEFAULT_MAX_QUERY_BYTES = 65536;
pub let DEFAULT_MAX_DEPTH = 32;
pub let DEFAULT_MAX_NODES = 10000;
pub let DEFAULT_MAX_ALIASES = 1000;
pub let DEFAULT_MAX_FRAGMENTS = 128;
pub let DEFAULT_MAX_VARIABLES = 256;
pub let DEFAULT_MAX_BREADTH = 1000;
pub let DEFAULT_MAX_RESPONSE_BYTES = 4194304;

pub let HARD_MAX_QUERY_BYTES = 1048576;
pub let HARD_MAX_DEPTH = 64;
pub let HARD_MAX_NODES = 100000;
pub let HARD_MAX_ALIASES = 10000;
pub let HARD_MAX_FRAGMENTS = 1024;
pub let HARD_MAX_VARIABLES = 4096;
pub let HARD_MAX_BREADTH = 10000;
pub let HARD_MAX_RESPONSE_BYTES = 67108864;

pub gc struct Limits {
    max_query_bytes: int,
    max_depth: int,
    max_nodes: int,
    max_aliases: int,
    max_fragments: int,
    max_variables: int,
    max_breadth: int,
    max_response_bytes: int
}

pub struct Span {
    start: int,
    end: int
}

pub gc struct Value {
    kind: int,
    source: Span,
    name: Span,
    items: [Value],
    fields: [Argument]
}

pub gc struct Argument {
    name: Span,
    value: Value
}

pub gc struct Directive {
    name: Span,
    arguments: [Argument]
}

pub gc struct VariableDef {
    name: Span,
    type_ref: Span,
    has_default: bool,
    default_value: Value
}

pub gc struct Selection {
    kind: int,
    name: Span,
    alias: Span,
    type_condition: Span,
    arguments: [Argument],
    directives: [Directive],
    children: [Selection]
}

pub gc struct Operation {
    kind: int,
    name: Span,
    variables: [VariableDef],
    directives: [Directive],
    selections: [Selection]
}

pub gc struct Fragment {
    name: Span,
    type_condition: Span,
    directives: [Directive],
    selections: [Selection]
}

pub gc struct Document {
    source: bytes,
    operations: [Operation],
    fragments: [Fragment],
    node_count: int,
    alias_count: int,
    variable_count: int
}

pub gc struct VariableValue {
    name: str,
    start: int,
    end: int
}

pub gc struct Variables {
    source: bytes,
    entries: [VariableValue]
}

pub fn default_limits() -> Limits {
    return Limits {
        max_query_bytes: DEFAULT_MAX_QUERY_BYTES,
        max_depth: DEFAULT_MAX_DEPTH,
        max_nodes: DEFAULT_MAX_NODES,
        max_aliases: DEFAULT_MAX_ALIASES,
        max_fragments: DEFAULT_MAX_FRAGMENTS,
        max_variables: DEFAULT_MAX_VARIABLES,
        max_breadth: DEFAULT_MAX_BREADTH,
        max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES
    };
}

pub fn new_limits(query_bytes: int, depth: int, nodes: int, aliases: int,
                  fragments: int, variables: int, breadth: int,
                  response_bytes: int) -> result[Limits, str] {
    if query_bytes < 1 || query_bytes > HARD_MAX_QUERY_BYTES ||
       depth < 1 || depth > HARD_MAX_DEPTH ||
       nodes < 1 || nodes > HARD_MAX_NODES ||
       aliases < 0 || aliases > HARD_MAX_ALIASES ||
       fragments < 0 || fragments > HARD_MAX_FRAGMENTS ||
       variables < 0 || variables > HARD_MAX_VARIABLES ||
       breadth < 1 || breadth > HARD_MAX_BREADTH ||
       response_bytes < 1 || response_bytes > HARD_MAX_RESPONSE_BYTES {
        return err("graphql limits: value is outside its documented hard bound");
    }
    return ok(Limits {
        max_query_bytes: query_bytes,
        max_depth: depth,
        max_nodes: nodes,
        max_aliases: aliases,
        max_fragments: fragments,
        max_variables: variables,
        max_breadth: breadth,
        max_response_bytes: response_bytes
    });
}

pub fn span_text(source: bytes, span: Span) -> str {
    return strings.from_bytes(source, span.start, span.end);
}

pub fn variables_get(variables: Variables, name: str) -> opt[bytes] {
    for i in 0..len(variables.entries) {
        let entry = variables.entries[i];
        if entry.name == name {
            return some(variables.source[entry.start..entry.end]);
        }
    }
    return none;
}

pub fn variable_missing(doc: Document, value: Value, variables: Variables,
                        operation: Operation) -> bool {
    if value.kind != VALUE_VARIABLE { return false; }
    let name = span_text(doc.source, value.name);
    if let _present = variables_get(variables, name) { return false; }
    for i in 0..len(operation.variables) {
        let definition = operation.variables[i];
        if span_text(doc.source, definition.name) == name {
            return !definition.has_default;
        }
    }
    return true;
}

pub fn value_json(doc: Document, value: Value, variables: Variables,
                  operation: Operation, limits: Limits)
                  -> result[bytes, str] {
    return graphql_value_json(doc.source, value, variables, operation, limits, 0);
}

fn graphql_value_json(source: bytes, value: Value, variables: Variables,
                      operation: Operation, limits: Limits, depth: int)
                      -> result[bytes, str] {
    if depth > limits.max_depth {
        return err("graphql value exceeds the configured depth limit");
    }
    if value.kind == VALUE_VARIABLE {
        let name = span_text(source, value.name);
        let external = variables_get(variables, name);
        guard let raw = external else {
            for i in 0..len(operation.variables) {
                let definition = operation.variables[i];
                if span_text(source, definition.name) == name &&
                   definition.has_default {
                    return graphql_value_json(source, definition.default_value,
                                              variables, operation, limits,
                                              depth + 1);
                }
            }
            return err("graphql variable $" + name + " has no value or default");
        }
        return ok(raw);
    }
    if value.kind == VALUE_STRING || value.kind == VALUE_NULL ||
       value.kind == VALUE_BOOL || value.kind == VALUE_INT ||
       value.kind == VALUE_FLOAT {
        return ok(source[value.source.start..value.source.end]);
    }
    let out = builder.new_bytes();
    if value.kind == VALUE_ENUM {
        out.write_byte(34);
        out.write(source[value.name.start..value.name.end]);
        out.write_byte(34);
        return ok(out.finish());
    }
    if value.kind == VALUE_LIST {
        out.write_byte(91);
        for i in 0..len(value.items) {
            if i > 0 { out.write_byte(44); }
            let part = graphql_value_json(source, value.items[i], variables,
                                          operation, limits, depth + 1);
            guard let encoded = part else let e = err_of(part) { return err(e); }
            out.write(encoded);
            if out.size() > limits.max_response_bytes {
                return err("graphql argument value exceeds the byte limit");
            }
        }
        out.write_byte(93);
        return ok(out.finish());
    }
    if value.kind == VALUE_OBJECT {
        out.write_byte(123);
        for i in 0..len(value.fields) {
            if i > 0 { out.write_byte(44); }
            let field = value.fields[i];
            out.write_byte(34);
            out.write(source[field.name.start..field.name.end]);
            out.write(b"\":");
            let part = graphql_value_json(source, field.value, variables,
                                          operation, limits, depth + 1);
            guard let encoded = part else let e = err_of(part) { return err(e); }
            out.write(encoded);
            if out.size() > limits.max_response_bytes {
                return err("graphql argument value exceeds the byte limit");
            }
        }
        out.write_byte(125);
        return ok(out.finish());
    }
    return err("graphql value has an unsupported kind");
}
