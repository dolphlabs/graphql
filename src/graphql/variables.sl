import "builder";
import "strings";

gc struct JSONBudget {
    nodes: int,
    max_nodes: int,
    max_depth: int,
    max_breadth: int
}

pub fn parse_variables(raw: bytes, limits: Limits) -> result[Variables, str] {
    if !graphql_limits_valid(limits) {
        return err("graphql variables: invalid limits");
    }
    if len(raw) == 0 {
        return ok(Variables { source: b"", entries: [] });
    }
    if len(raw) > limits.max_query_bytes || !graphql_utf8_valid(raw) {
        return err("graphql variables: JSON exceeds the byte limit or is not UTF-8");
    }
    let i = graphql_json_ws(raw, 0);
    if i >= len(raw) || raw[i] != 123 {
        return err("graphql variables: expected a JSON object");
    }
    i = i + 1;
    let entries: [VariableValue] = [];
    let seen: map[str]bool = {};
    let budget = JSONBudget { nodes: 0, max_nodes: limits.max_nodes,
                              max_depth: limits.max_depth,
                              max_breadth: limits.max_breadth };
    i = graphql_json_ws(raw, i);
    if i < len(raw) && raw[i] == 125 {
        i = graphql_json_ws(raw, i + 1);
        if i != len(raw) { return err("graphql variables: trailing bytes after object"); }
        return ok(Variables { source: raw, entries: entries });
    }
    while i < len(raw) {
        let key_result = graphql_json_string(raw, i);
        guard let key = key_result else let e = err_of(key_result) { return err(e); }
        let name = key.value;
        if !graphql_variable_name(name) {
            return err("graphql variables: object keys must be GraphQL variable names");
        }
        if has(seen, name) {
            return err("graphql variables: duplicate key " + name);
        }
        seen[name] = true;
        i = graphql_json_ws(raw, key.end);
        if i >= len(raw) || raw[i] != 58 {
            return err("graphql variables: expected ':' after key");
        }
        i = graphql_json_ws(raw, i + 1);
        let start = i;
        let end_result = graphql_json_value_end(raw, i, budget, 0);
        guard let end = end_result else let e = err_of(end_result) { return err(e); }
        push(entries, VariableValue { name: name, start: start, end: end });
        if len(entries) > limits.max_variables {
            return err("graphql variables: variable count exceeds configured limit");
        }
        i = graphql_json_ws(raw, end);
        if i < len(raw) && raw[i] == 44 {
            i = graphql_json_ws(raw, i + 1);
            if i < len(raw) && raw[i] == 125 {
                return err("graphql variables: trailing comma is not valid JSON");
            }
            continue;
        }
        if i < len(raw) && raw[i] == 125 {
            i = graphql_json_ws(raw, i + 1);
            if i != len(raw) { return err("graphql variables: trailing bytes after object"); }
            return ok(Variables { source: raw, entries: entries });
        }
        return err("graphql variables: expected ',' or '}' after value");
    }
    return err("graphql variables: unterminated object");
}

pub fn parse_input_object(raw: bytes, limits: Limits) -> result[Variables, str] {
    let object_limits = limits;
    let field_limit = limits.max_breadth;
    if field_limit > HARD_MAX_VARIABLES { field_limit = HARD_MAX_VARIABLES; }
    if object_limits.max_variables < field_limit {
        object_limits.max_variables = field_limit;
    }
    return parse_variables(raw, object_limits);
}

pub fn validate_object_keys(object: Variables, allowed: [str]) -> result[bool, str] {
    for i in 0..len(object.entries) {
        let name = object.entries[i].name;
        let found = false;
        for j in 0..len(allowed) {
            if allowed[j] == name { found = true; break; }
        }
        if !found { return err("graphql validation: unknown input field " + name); }
    }
    return ok(true);
}

pub fn normalize_int32(raw: bytes) -> result[bytes, str] {
    if len(raw) == 0 { return err("graphql Int: expected a 32-bit integer"); }
    let end_result = graphql_json_number_end(raw, 0);
    guard let end = end_result else let e = err_of(end_result) { return err(e); }
    if end != len(raw) {
        return err("graphql Int: expected an integer, not a fraction or exponent");
    }
    let value_result = to_int(strings.from_bytes(raw, 0, len(raw)));
    guard let value = value_result else { return err("graphql Int: integer is outside the supported range"); }
    if value < -2147483648 || value > 2147483647 {
        return err("graphql Int: value is outside the signed 32-bit range");
    }
    return ok(raw);
}

pub fn normalize_id(raw: bytes) -> result[bytes, str] {
    if len(raw) == 0 { return err("graphql ID: expected a string or integer"); }
    if raw[0] == 34 {
        let string_result = graphql_json_string(raw, 0);
        guard let parsed = string_result else let e = err_of(string_result) { return err(e); }
        if parsed.end != len(raw) { return err("graphql ID: invalid string value"); }
        return ok(raw);
    }
    let end_result = graphql_json_number_end(raw, 0);
    guard let end = end_result else { return err("graphql ID: expected a string or integer"); }
    if end != len(raw) {
        return err("graphql ID: expected an integer, not a fraction or exponent");
    }
    for i in 0..end {
        if raw[i] == 46 || raw[i] == 69 || raw[i] == 101 {
            return err("graphql ID: expected an integer, not a fraction or exponent");
        }
    }
    let out = builder.new_bytes();
    out.write_byte(34);
    out.write(raw);
    out.write_byte(34);
    return ok(out.finish());
}

pub fn json_array_values(raw: bytes, limits: Limits) -> result[[bytes], str] {
    if !graphql_limits_valid(limits) || len(raw) > limits.max_query_bytes ||
       !graphql_utf8_valid(raw) {
        return err("graphql JSON: array exceeds the configured byte limit or is not UTF-8");
    }
    let values: [bytes] = [];
    let i = graphql_json_ws(raw, 0);
    if i >= len(raw) || raw[i] != 91 {
        return err("graphql JSON: expected an array");
    }
    i = graphql_json_ws(raw, i + 1);
    let budget = JSONBudget { nodes: 0, max_nodes: limits.max_nodes,
                              max_depth: limits.max_depth,
                              max_breadth: limits.max_breadth };
    if i < len(raw) && raw[i] == 93 {
        i = graphql_json_ws(raw, i + 1);
        if i != len(raw) { return err("graphql JSON: trailing bytes after array"); }
        return ok(values);
    }
    while i < len(raw) {
        let start = i;
        let end_result = graphql_json_value_end(raw, i, budget, 0);
        guard let end = end_result else let e = err_of(end_result) { return err(e); }
        push(values, raw[start..end]);
        if len(values) > limits.max_breadth {
            return err("graphql JSON: array exceeds configured breadth");
        }
        i = graphql_json_ws(raw, end);
        if i < len(raw) && raw[i] == 44 {
            i = graphql_json_ws(raw, i + 1);
            continue;
        }
        if i < len(raw) && raw[i] == 93 {
            i = graphql_json_ws(raw, i + 1);
            if i != len(raw) { return err("graphql JSON: trailing bytes after array"); }
            return ok(values);
        }
        return err("graphql JSON: expected ',' or ']' after array item");
    }
    return err("graphql JSON: unterminated array");
}

fn graphql_json_value_end(raw: bytes, start: int, budget: JSONBudget,
                          depth: int) -> result[int, str] {
    if depth > budget.max_depth {
        return err("graphql variables: JSON nesting exceeds configured depth");
    }
    budget.nodes = budget.nodes + 1;
    if budget.nodes > budget.max_nodes {
        return err("graphql variables: JSON node count exceeds configured limit");
    }
    if start >= len(raw) { return err("graphql variables: missing JSON value"); }
    let c = raw[start];
    if c == 34 {
        let string_result = graphql_json_string(raw, start);
        guard let s = string_result else let e = err_of(string_result) { return err(e); }
        return ok(s.end);
    }
    if c == 123 {
        let i = graphql_json_ws(raw, start + 1);
        let seen: map[str]bool = {};
        let fields = 0;
        if i < len(raw) && raw[i] == 125 { return ok(i + 1); }
        while i < len(raw) {
            let key_result = graphql_json_string(raw, i);
            guard let key = key_result else let e = err_of(key_result) { return err(e); }
            if has(seen, key.value) {
                return err("graphql variables: duplicate nested object key " + key.value);
            }
            seen[key.value] = true;
            i = graphql_json_ws(raw, key.end);
            if i >= len(raw) || raw[i] != 58 {
                return err("graphql variables: expected ':' in nested object");
            }
            i = graphql_json_ws(raw, i + 1);
            let end_result = graphql_json_value_end(raw, i, budget, depth + 1);
            guard let end = end_result else let e = err_of(end_result) { return err(e); }
            i = graphql_json_ws(raw, end);
            fields = fields + 1;
            if fields > budget.max_breadth {
                return err("graphql variables: object breadth exceeds configured limit");
            }
            if i < len(raw) && raw[i] == 44 {
                i = graphql_json_ws(raw, i + 1);
                if i < len(raw) && raw[i] == 125 {
                    return err("graphql variables: trailing comma is not valid JSON");
                }
                continue;
            }
            if i < len(raw) && raw[i] == 125 { return ok(i + 1); }
            return err("graphql variables: expected ',' or '}' in object");
        }
        return err("graphql variables: unterminated nested object");
    }
    if c == 91 {
        let i = graphql_json_ws(raw, start + 1);
        let count = 0;
        if i < len(raw) && raw[i] == 93 { return ok(i + 1); }
        while i < len(raw) {
            let end_result = graphql_json_value_end(raw, i, budget, depth + 1);
            guard let end = end_result else let e = err_of(end_result) { return err(e); }
            i = graphql_json_ws(raw, end);
            count = count + 1;
            if count > budget.max_breadth {
                return err("graphql variables: array breadth exceeds configured limit");
            }
            if i < len(raw) && raw[i] == 44 {
                i = graphql_json_ws(raw, i + 1);
                continue;
            }
            if i < len(raw) && raw[i] == 93 { return ok(i + 1); }
            return err("graphql variables: expected ',' or ']' in array");
        }
        return err("graphql variables: unterminated array");
    }
    if c == 116 { return graphql_json_keyword(raw, start, "true"); }
    if c == 102 { return graphql_json_keyword(raw, start, "false"); }
    if c == 110 { return graphql_json_keyword(raw, start, "null"); }
    if c == 45 || (c >= 48 && c <= 57) {
        return graphql_json_number_end(raw, start);
    }
    return err("graphql variables: invalid JSON value at byte " + to_str(start));
}

fn graphql_json_string(raw: bytes, start: int) -> result[JSONString, str] {
    if start >= len(raw) || raw[start] != 34 {
        return err("graphql variables: expected a JSON string key");
    }
    let i = start + 1;
    let out = builder.new_bytes();
    while i < len(raw) {
        let c = raw[i];
        if c == 34 {
            let decoded_bytes = out.finish();
            if !graphql_utf8_valid(decoded_bytes) || graphql_has_nul(decoded_bytes) {
                return err("graphql variables: string key is not representable text");
            }
            return ok(JSONString { value: strings.from_bytes(decoded_bytes, 0, len(decoded_bytes)),
                                   end: i + 1 });
        }
        if c < 32 { return err("graphql variables: unescaped control in JSON string"); }
        if c != 92 {
            out.write_byte(c);
            i = i + 1;
            continue;
        }
        i = i + 1;
        if i >= len(raw) { return err("graphql variables: truncated JSON escape"); }
        let esc = raw[i];
        if esc == 34 || esc == 92 || esc == 47 {
            out.write_byte(esc);
            i = i + 1;
        } else if esc == 98 { out.write_byte(8); i = i + 1; }
        else if esc == 102 { out.write_byte(12); i = i + 1; }
        else if esc == 110 { out.write_byte(10); i = i + 1; }
        else if esc == 114 { out.write_byte(13); i = i + 1; }
        else if esc == 116 { out.write_byte(9); i = i + 1; }
        else if esc == 117 {
            let first = graphql_json_hex4(raw, i + 1);
            guard let code = first else let e = err_of(first) { return err(e); }
            i = i + 5;
            let scalar = code;
            if code >= 55296 && code <= 56319 {
                if i + 5 >= len(raw) || raw[i] != 92 || raw[i + 1] != 117 {
                    return err("graphql variables: high surrogate lacks a low surrogate");
                }
                let second = graphql_json_hex4(raw, i + 2);
                guard let low = second else let e = err_of(second) { return err(e); }
                if low < 56320 || low > 57343 {
                    return err("graphql variables: invalid low surrogate");
                }
                scalar = 65536 + ((code - 55296) << 10) + (low - 56320);
                i = i + 6;
            } else if code >= 56320 && code <= 57343 {
                return err("graphql variables: unpaired low surrogate");
            }
            graphql_json_write_rune(out, scalar);
        } else {
            return err("graphql variables: invalid JSON escape");
        }
    }
    return err("graphql variables: unterminated JSON string");
}

pub struct JSONString {
    value: str,
    end: int
}

fn graphql_json_hex4(raw: bytes, start: int) -> result[int, str] {
    if start + 3 >= len(raw) { return err("graphql variables: truncated Unicode escape"); }
    let value = 0;
    for i in start..start + 4 {
        let digit = graphql_hex(raw[i]);
        if digit < 0 { return err("graphql variables: invalid Unicode escape"); }
        value = (value << 4) | digit;
    }
    return ok(value);
}

fn graphql_json_write_rune(out: builder.Bytes, code: int) {
    if code <= 127 { out.write_byte(code); return; }
    if code <= 2047 {
        out.write_byte(192 | (code >> 6));
        out.write_byte(128 | (code & 63));
        return;
    }
    if code <= 65535 {
        out.write_byte(224 | (code >> 12));
        out.write_byte(128 | ((code >> 6) & 63));
        out.write_byte(128 | (code & 63));
        return;
    }
    out.write_byte(240 | (code >> 18));
    out.write_byte(128 | ((code >> 12) & 63));
    out.write_byte(128 | ((code >> 6) & 63));
    out.write_byte(128 | (code & 63));
}

fn graphql_json_number_end(raw: bytes, start: int) -> result[int, str] {
    let i = start;
    if raw[i] == 45 {
        i = i + 1;
        if i >= len(raw) { return err("graphql variables: invalid JSON number"); }
    }
    if raw[i] == 48 {
        i = i + 1;
        if i < len(raw) && raw[i] >= 48 && raw[i] <= 57 {
            return err("graphql variables: JSON number has a leading zero");
        }
    } else if raw[i] >= 49 && raw[i] <= 57 {
        while i < len(raw) && raw[i] >= 48 && raw[i] <= 57 { i = i + 1; }
    } else { return err("graphql variables: invalid JSON number"); }
    if i < len(raw) && raw[i] == 46 {
        i = i + 1;
        if i >= len(raw) || raw[i] < 48 || raw[i] > 57 {
            return err("graphql variables: invalid JSON fraction");
        }
        while i < len(raw) && raw[i] >= 48 && raw[i] <= 57 { i = i + 1; }
    }
    if i < len(raw) && (raw[i] == 69 || raw[i] == 101) {
        i = i + 1;
        if i < len(raw) && (raw[i] == 43 || raw[i] == 45) { i = i + 1; }
        if i >= len(raw) || raw[i] < 48 || raw[i] > 57 {
            return err("graphql variables: invalid JSON exponent");
        }
        while i < len(raw) && raw[i] >= 48 && raw[i] <= 57 { i = i + 1; }
    }
    return ok(i);
}

fn graphql_json_keyword(raw: bytes, start: int, word: str) -> result[int, str] {
    let text = to_bytes(word);
    if len(raw) - start < len(text) || raw[start..start + len(text)] != text {
        return err("graphql variables: invalid JSON literal");
    }
    return ok(start + len(text));
}

fn graphql_json_ws(raw: bytes, start: int) -> int {
    let i = start;
    while i < len(raw) && (raw[i] == 32 || raw[i] == 9 ||
                           raw[i] == 10 || raw[i] == 13) { i = i + 1; }
    return i;
}

fn graphql_variable_name(name: str) -> bool {
    if len(name) == 0 { return false; }
    let raw = to_bytes(name);
    if !graphql_name_start(raw[0]) { return false; }
    for i in 1..len(raw) {
        if !graphql_name_continue(raw[i]) { return false; }
    }
    return true;
}

fn graphql_has_nul(raw: bytes) -> bool {
    for i in 0..len(raw) {
        if raw[i] == 0 { return true; }
    }
    return false;
}
