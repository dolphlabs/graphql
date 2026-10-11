import "strings";

let TOKEN_EOF = 0;
let TOKEN_NAME = 1;
let TOKEN_INT = 2;
let TOKEN_FLOAT = 3;
let TOKEN_STRING = 4;
let TOKEN_PUNCT = 5;
let TOKEN_SPREAD = 6;

pub struct Token {
    kind: int,
    start: int,
    end: int
}

gc struct Parser {
    source: bytes,
    tokens: [Token],
    pos: int,
    nodes: int,
    aliases: int,
    variables: int,
    limits: Limits
}

pub fn parse(query: str, limits: Limits) -> result[Document, str] {
    if !graphql_limits_valid(limits) {
        return err("graphql parse: invalid limits");
    }
    if len(query) > limits.max_query_bytes {
        return err("graphql parse: query exceeds configured byte limit");
    }
    let source = to_bytes(query);
    if !graphql_utf8_valid(source) {
        return err("graphql parse: query is not valid UTF-8");
    }
    let scanned = graphql_lex(source, limits);
    guard let tokens = scanned else let e = err_of(scanned) { return err(e); }
    let p = Parser { source: source, tokens: tokens, pos: 0, nodes: 0,
                     aliases: 0, variables: 0, limits: limits };
    let operations: [Operation] = [];
    let fragments: [Fragment] = [];
    while graphql_peek(p).kind != TOKEN_EOF {
        if graphql_keyword(p, "fragment") {
            let fragment_result = graphql_parse_fragment(p);
            guard let fragment = fragment_result else let e = err_of(fragment_result) {
                return err(e);
            }
            let name = span_text(source, fragment.name);
            for i in 0..len(fragments) {
                if span_text(source, fragments[i].name) == name {
                    return err(graphql_error(p, "duplicate fragment " + name));
                }
            }
            if len(fragments) >= limits.max_fragments {
                return err(graphql_error(p, "fragment count exceeds configured limit"));
            }
            push(fragments, fragment);
        } else {
            let operation_result = graphql_parse_operation(p);
            guard let operation = operation_result else let e = err_of(operation_result) {
                return err(e);
            }
            if operation.name.end > operation.name.start {
                let name = span_text(source, operation.name);
                for i in 0..len(operations) {
                    if operations[i].name.end > operations[i].name.start &&
                       span_text(source, operations[i].name) == name {
                        return err(graphql_error(p, "duplicate operation " + name));
                    }
                }
            }
            push(operations, operation);
        }
    }
    if len(operations) == 0 {
        return err("graphql parse: document has no executable operation");
    }
    let document = Document {
        source: source,
        operations: operations,
        fragments: fragments,
        node_count: p.nodes,
        alias_count: p.aliases,
        variable_count: p.variables
    };
    let checked = graphql_validate_structure(document);
    guard let _valid = checked else let e = err_of(checked) { return err(e); }
    return ok(document);
}

pub fn operation(doc: Document, requested_name: str)
                    -> result[Operation, str] {
    if len(doc.operations) == 1 && requested_name == "" {
        return ok(doc.operations[0]);
    }
    if requested_name == "" {
        return err("graphql operation: operationName is required for a multi-operation document");
    }
    for i in 0..len(doc.operations) {
        if doc.operations[i].name.end > doc.operations[i].name.start &&
           span_text(doc.source, doc.operations[i].name) == requested_name {
            return ok(doc.operations[i]);
        }
    }
    return err("graphql operation: no operation named " + requested_name);
}

pub fn operation_name(doc: Document, operation: Operation) -> str {
    if operation.name.end <= operation.name.start { return ""; }
    return span_text(doc.source, operation.name);
}

pub fn fragment(doc: Document, name: str) -> opt[Fragment] {
    for i in 0..len(doc.fragments) {
        if span_text(doc.source, doc.fragments[i].name) == name {
            return some(doc.fragments[i]);
        }
    }
    return none;
}

pub fn selection_name(doc: Document, selection: Selection) -> str {
    return span_text(doc.source, selection.name);
}

pub fn response_name(doc: Document, selection: Selection) -> str {
    if selection.alias.end > selection.alias.start {
        return span_text(doc.source, selection.alias);
    }
    return selection_name(doc, selection);
}

fn graphql_limits_valid(lim: Limits) -> bool {
    return lim.max_query_bytes >= 1 && lim.max_query_bytes <= HARD_MAX_QUERY_BYTES &&
           lim.max_depth >= 1 && lim.max_depth <= HARD_MAX_DEPTH &&
           lim.max_nodes >= 1 && lim.max_nodes <= HARD_MAX_NODES &&
           lim.max_aliases >= 0 && lim.max_aliases <= HARD_MAX_ALIASES &&
           lim.max_fragments >= 0 && lim.max_fragments <= HARD_MAX_FRAGMENTS &&
           lim.max_variables >= 0 && lim.max_variables <= HARD_MAX_VARIABLES &&
           lim.max_breadth >= 1 && lim.max_breadth <= HARD_MAX_BREADTH &&
           lim.max_response_bytes >= 1 &&
           lim.max_response_bytes <= HARD_MAX_RESPONSE_BYTES;
}

fn graphql_lex(source: bytes, limits: Limits) -> result[[Token], str] {
    let tokens: [Token] = [];
    let i = 0;
    while i < len(source) {
        let c = source[i];
        if c == 32 || c == 9 || c == 10 || c == 13 || c == 44 {
            i = i + 1;
            continue;
        }
        if c == 35 {
            while i < len(source) && source[i] != 10 && source[i] != 13 {
                i = i + 1;
            }
            continue;
        }
        let start = i;
        if graphql_name_start(c) {
            i = i + 1;
            while i < len(source) && graphql_name_continue(source[i]) {
                i = i + 1;
            }
            push(tokens, Token { kind: TOKEN_NAME, start: start, end: i });
        } else if c == 45 || (c >= 48 && c <= 57) {
            let number = graphql_scan_number(source, i);
            guard let end = number else let e = err_of(number) { return err(e); }
            let kind = TOKEN_INT;
            for j in start..end {
                if source[j] == 46 || source[j] == 69 || source[j] == 101 {
                    kind = TOKEN_FLOAT;
                }
            }
            i = end;
            push(tokens, Token { kind: kind, start: start, end: i });
        } else if c == 34 {
            if i + 2 < len(source) && source[i + 1] == 34 && source[i + 2] == 34 {
                return err("graphql parse: block strings are not supported; use a quoted string");
            }
            let end_result = graphql_scan_string(source, i);
            guard let end = end_result else let e = err_of(end_result) { return err(e); }
            i = end;
            push(tokens, Token { kind: TOKEN_STRING, start: start, end: i });
        } else if c == 46 && i + 2 < len(source) &&
                  source[i + 1] == 46 && source[i + 2] == 46 {
            i = i + 3;
            push(tokens, Token { kind: TOKEN_SPREAD, start: start, end: i });
        } else if graphql_punct(c) {
            i = i + 1;
            push(tokens, Token { kind: TOKEN_PUNCT, start: start, end: i });
        } else {
            return err("graphql parse: invalid character at byte " + to_str(i));
        }
        if len(tokens) > limits.max_nodes * 8 + 1024 {
            return err("graphql parse: token count exceeds configured node budget");
        }
    }
    push(tokens, Token { kind: TOKEN_EOF, start: len(source), end: len(source) });
    return ok(tokens);
}

fn graphql_parse_operation(p: Parser) -> result[Operation, str] {
    if graphql_punct_is(p, "{") {
        let selections = graphql_parse_selection_set(p, 1);
        guard let body = selections else let e = err_of(selections) { return err(e); }
        return ok(Operation { kind: OP_QUERY, name: Span { start: 0, end: 0 },
                              variables: [], directives: [], selections: body });
    }
    if !graphql_keyword(p, "query") && !graphql_keyword(p, "mutation") {
        if graphql_keyword(p, "subscription") {
            return err(graphql_error(p, "subscriptions are not supported in v1"));
        }
        return err(graphql_error(p, "expected query, mutation, or a selection set"));
    }
    let operation_token = graphql_take(p);
    let kind = OP_QUERY;
    if graphql_token_text(p, operation_token) == "mutation" { kind = OP_MUTATION; }
    let name = Span { start: 0, end: 0 };
    if graphql_peek(p).kind == TOKEN_NAME {
        let token = graphql_take(p);
        name = Span { start: token.start, end: token.end };
    }
    let variables: [VariableDef] = [];
    if graphql_punct_is(p, "(") {
        let parsed = graphql_parse_variable_defs(p);
        guard let defs = parsed else let e = err_of(parsed) { return err(e); }
        variables = defs;
    }
    let directives_result = graphql_parse_directives(p, 0);
    guard let directives = directives_result else let e = err_of(directives_result) {
        return err(e);
    }
    if len(directives) > 0 {
        return err(graphql_error(p, "directives on operations are not supported in v1"));
    }
    let selections_result = graphql_parse_selection_set(p, 1);
    guard let selections = selections_result else let e = err_of(selections_result) {
        return err(e);
    }
    return ok(Operation { kind: kind, name: name, variables: variables,
                          directives: directives, selections: selections });
}

fn graphql_parse_fragment(p: Parser) -> result[Fragment, str] {
    graphql_take(p); // fragment
    if graphql_peek(p).kind != TOKEN_NAME || graphql_keyword(p, "on") {
        return err(graphql_error(p, "expected a fragment name before 'on'"));
    }
    let name_token = graphql_take(p);
    let name = Span { start: name_token.start, end: name_token.end };
    if !graphql_keyword(p, "on") {
        return err(graphql_error(p, "expected 'on' after fragment name"));
    }
    graphql_take(p);
    if graphql_peek(p).kind != TOKEN_NAME {
        return err(graphql_error(p, "expected an object type after 'on'"));
    }
    let type_token = graphql_take(p);
    let type_condition = Span { start: type_token.start, end: type_token.end };
    let directives = graphql_parse_directives(p, 0);
    guard let dirs = directives else let e = err_of(directives) { return err(e); }
    let selections_result = graphql_parse_selection_set(p, 1);
    guard let selections = selections_result else let e = err_of(selections_result) {
        return err(e);
    }
    p.nodes = p.nodes + 1;
    if p.nodes > p.limits.max_nodes {
        return err(graphql_error(p, "node count exceeds configured limit"));
    }
    return ok(Fragment { name: name, type_condition: type_condition,
                         directives: dirs, selections: selections });
}

fn graphql_parse_variable_defs(p: Parser) -> result[[VariableDef], str] {
    let defs: [VariableDef] = [];
    graphql_take(p); // (
    while !graphql_punct_is(p, ")") {
        if graphql_peek(p).kind == TOKEN_EOF {
            return err(graphql_error(p, "unterminated variable definitions"));
        }
        if !graphql_punct_is(p, "$") {
            return err(graphql_error(p, "expected '$' before variable name"));
        }
        graphql_take(p);
        if graphql_peek(p).kind != TOKEN_NAME {
            return err(graphql_error(p, "expected variable name"));
        }
        let name_token = graphql_take(p);
        let name = Span { start: name_token.start, end: name_token.end };
        for i in 0..len(defs) {
            if span_text(p.source, defs[i].name) == span_text(p.source, name) {
                return err(graphql_error(p, "duplicate variable definition"));
            }
        }
        if !graphql_punct_is(p, ":") {
            return err(graphql_error(p, "expected ':' after variable name"));
        }
        graphql_take(p);
        let type_span_result = graphql_parse_type_ref(p, 0);
        guard let type_ref = type_span_result else let e = err_of(type_span_result) {
            return err(e);
        }
        let has_default = false;
        let default_value = Value { kind: VALUE_NULL, source: Span { start: 0, end: 0 },
                                    name: Span { start: 0, end: 0 },
                                    items: [], fields: [] };
        if graphql_punct_is(p, "=") {
            graphql_take(p);
            let value_result = graphql_parse_value(p, 0);
            guard let value = value_result else let e = err_of(value_result) {
                return err(e);
            }
            has_default = true;
            default_value = value;
        }
        if graphql_punct_is(p, "@") {
            return err(graphql_error(p, "directives on variable definitions are not supported"));
        }
        p.variables = p.variables + 1;
        p.nodes = p.nodes + 1;
        if p.variables > p.limits.max_variables {
            return err(graphql_error(p, "variable count exceeds configured limit"));
        }
        if p.nodes > p.limits.max_nodes {
            return err(graphql_error(p, "node count exceeds configured limit"));
        }
        push(defs, VariableDef { name: name, type_ref: type_ref,
                                 has_default: has_default,
                                 default_value: default_value });
    }
    graphql_take(p);
    return ok(defs);
}

fn graphql_parse_type_ref(p: Parser, depth: int) -> result[Span, str] {
    if depth > 16 { return err(graphql_error(p, "type reference is too deep")); }
    let start = graphql_peek(p).start;
    let end = start;
    if graphql_punct_is(p, "[") {
        graphql_take(p);
        let inner = graphql_parse_type_ref(p, depth + 1);
        guard let _valid = inner else let e = err_of(inner) { return err(e); }
        if !graphql_punct_is(p, "]") {
            return err(graphql_error(p, "expected ']' in list type"));
        }
        let close = graphql_take(p);
        end = close.end;
    } else if graphql_peek(p).kind == TOKEN_NAME {
        let name = graphql_take(p);
        end = name.end;
    } else {
        return err(graphql_error(p, "expected a named or list type"));
    }
    if graphql_punct_is(p, "!") {
        let nonnull = graphql_take(p);
        end = nonnull.end;
    }
    return ok(Span { start: start, end: end });
}

fn graphql_parse_selection_set(p: Parser, depth: int)
                            -> result[[Selection], str] {
    if depth > p.limits.max_depth {
        return err(graphql_error(p, "selection depth exceeds configured limit"));
    }
    if !graphql_punct_is(p, "{") {
        return err(graphql_error(p, "expected '{' to start selection set"));
    }
    graphql_take(p);
    let selections: [Selection] = [];
    while !graphql_punct_is(p, "}") {
        if graphql_peek(p).kind == TOKEN_EOF {
            return err(graphql_error(p, "unterminated selection set"));
        }
        let selection_result = graphql_parse_selection(p, depth);
        guard let selection = selection_result else let e = err_of(selection_result) {
            return err(e);
        }
        push(selections, selection);
        if len(selections) > p.limits.max_breadth {
            return err(graphql_error(p, "selection breadth exceeds configured limit"));
        }
    }
    graphql_take(p);
    if len(selections) == 0 {
        return err(graphql_error(p, "selection set cannot be empty"));
    }
    return ok(selections);
}

fn graphql_parse_selection(p: Parser, depth: int) -> result[Selection, str] {
    if graphql_peek(p).kind == TOKEN_SPREAD {
        graphql_take(p);
        if graphql_keyword(p, "on") {
            graphql_take(p);
            if graphql_peek(p).kind != TOKEN_NAME {
                return err(graphql_error(p, "expected inline fragment type condition"));
            }
            let token = graphql_take(p);
            let condition = Span { start: token.start, end: token.end };
            let dirs_result = graphql_parse_directives(p, 0);
            guard let dirs = dirs_result else let e = err_of(dirs_result) { return err(e); }
            let children_result = graphql_parse_selection_set(p, depth + 1);
            guard let children = children_result else let e = err_of(children_result) {
                return err(e);
            }
            return graphql_new_selection(p, SELECTION_INLINE,
                                         Span { start: 0, end: 0 },
                                         Span { start: 0, end: 0 }, condition,
                                         [], dirs, children);
        }
        if graphql_punct_is(p, "@") || graphql_punct_is(p, "{") {
            let dirs_result = graphql_parse_directives(p, 0);
            guard let dirs = dirs_result else let e = err_of(dirs_result) { return err(e); }
            let children_result = graphql_parse_selection_set(p, depth + 1);
            guard let children = children_result else let e = err_of(children_result) {
                return err(e);
            }
            return graphql_new_selection(p, SELECTION_INLINE,
                                         Span { start: 0, end: 0 },
                                         Span { start: 0, end: 0 },
                                         Span { start: 0, end: 0 }, [], dirs, children);
        }
        if graphql_peek(p).kind != TOKEN_NAME {
            return err(graphql_error(p, "expected fragment name after '...'"));
        }
        let token = graphql_take(p);
        let name = Span { start: token.start, end: token.end };
        let dirs_result = graphql_parse_directives(p, 0);
        guard let dirs = dirs_result else let e = err_of(dirs_result) { return err(e); }
        return graphql_new_selection(p, SELECTION_SPREAD, name,
                                     Span { start: 0, end: 0 },
                                     Span { start: 0, end: 0 }, [], dirs, []);
    }
    if graphql_peek(p).kind != TOKEN_NAME {
        return err(graphql_error(p, "expected a field name or fragment"));
    }
    let first = graphql_take(p);
    let name = Span { start: first.start, end: first.end };
    let alias = Span { start: 0, end: 0 };
    if graphql_punct_is(p, ":") {
        graphql_take(p);
        if graphql_peek(p).kind != TOKEN_NAME {
            return err(graphql_error(p, "expected field name after alias"));
        }
        let field = graphql_take(p);
        alias = name;
        name = Span { start: field.start, end: field.end };
        p.aliases = p.aliases + 1;
        if p.aliases > p.limits.max_aliases {
            return err(graphql_error(p, "alias count exceeds configured limit"));
        }
    }
    let arguments_result = graphql_parse_arguments(p, 0);
    guard let arguments = arguments_result else let e = err_of(arguments_result) {
        return err(e);
    }
    let directives_result = graphql_parse_directives(p, 0);
    guard let directives = directives_result else let e = err_of(directives_result) {
        return err(e);
    }
    let children: [Selection] = [];
    if graphql_punct_is(p, "{") {
        let children_result = graphql_parse_selection_set(p, depth + 1);
        guard let parsed_children = children_result else let e = err_of(children_result) {
            return err(e);
        }
        children = parsed_children;
    }
    return graphql_new_selection(p, SELECTION_FIELD, name, alias,
                                 Span { start: 0, end: 0 }, arguments,
                                 directives, children);
}

fn graphql_new_selection(p: Parser, kind: int, name: Span, alias: Span,
                         condition: Span, arguments: [Argument], directives: [Directive],
                         children: [Selection]) -> result[Selection, str] {
    p.nodes = p.nodes + 1;
    if p.nodes > p.limits.max_nodes {
        return err(graphql_error(p, "node count exceeds configured limit"));
    }
    return ok(Selection { kind: kind, name: name, alias: alias,
                          type_condition: condition, arguments: arguments,
                          directives: directives, children: children });
}

fn graphql_parse_arguments(p: Parser, depth: int) -> result[[Argument], str] {
    let arguments: [Argument] = [];
    if !graphql_punct_is(p, "(") { return ok(arguments); }
    graphql_take(p);
    while !graphql_punct_is(p, ")") {
        if graphql_peek(p).kind == TOKEN_EOF {
            return err(graphql_error(p, "unterminated argument list"));
        }
        if graphql_peek(p).kind != TOKEN_NAME {
            return err(graphql_error(p, "expected argument name"));
        }
        let token = graphql_take(p);
        let name = Span { start: token.start, end: token.end };
        for i in 0..len(arguments) {
            if span_text(p.source, arguments[i].name) == span_text(p.source, name) {
                return err(graphql_error(p, "duplicate argument " + span_text(p.source, name)));
            }
        }
        if !graphql_punct_is(p, ":") {
            return err(graphql_error(p, "expected ':' after argument name"));
        }
        graphql_take(p);
        let value_result = graphql_parse_value(p, depth + 1);
        guard let value = value_result else let e = err_of(value_result) { return err(e); }
        push(arguments, Argument { name: name, value: value });
        if len(arguments) > p.limits.max_breadth {
            return err(graphql_error(p, "argument count exceeds configured limit"));
        }
    }
    graphql_take(p);
    return ok(arguments);
}

fn graphql_parse_directives(p: Parser, depth: int) -> result[[Directive], str] {
    let directives: [Directive] = [];
    while graphql_punct_is(p, "@") {
        graphql_take(p);
        if graphql_peek(p).kind != TOKEN_NAME {
            return err(graphql_error(p, "expected directive name after '@'"));
        }
        let token = graphql_take(p);
        let name = Span { start: token.start, end: token.end };
        let arguments_result = graphql_parse_arguments(p, depth + 1);
        guard let arguments = arguments_result else let e = err_of(arguments_result) {
            return err(e);
        }
        push(directives, Directive { name: name, arguments: arguments });
        if len(directives) > 32 {
            return err(graphql_error(p, "directive count exceeds 32"));
        }
    }
    return ok(directives);
}

fn graphql_parse_value(p: Parser, depth: int) -> result[Value, str] {
    if depth > p.limits.max_depth {
        return err(graphql_error(p, "input value depth exceeds configured limit"));
    }
    let token = graphql_peek(p);
    if graphql_punct_is(p, "$") {
        let start = graphql_take(p).start;
        if graphql_peek(p).kind != TOKEN_NAME {
            return err(graphql_error(p, "expected variable name after '$'"));
        }
        let name_token = graphql_take(p);
        p.nodes = p.nodes + 1;
        if p.nodes > p.limits.max_nodes {
            return err(graphql_error(p, "node count exceeds configured limit"));
        }
        return ok(Value { kind: VALUE_VARIABLE,
                          source: Span { start: start, end: name_token.end },
                          name: Span { start: name_token.start, end: name_token.end },
                          items: [], fields: [] });
    }
    if token.kind == TOKEN_STRING || token.kind == TOKEN_INT || token.kind == TOKEN_FLOAT {
        graphql_take(p);
        let kind = VALUE_STRING;
        if token.kind == TOKEN_INT { kind = VALUE_INT; }
        if token.kind == TOKEN_FLOAT { kind = VALUE_FLOAT; }
        p.nodes = p.nodes + 1;
        if p.nodes > p.limits.max_nodes {
            return err(graphql_error(p, "node count exceeds configured limit"));
        }
        return ok(Value { kind: kind, source: Span { start: token.start, end: token.end },
                          name: Span { start: 0, end: 0 }, items: [], fields: [] });
    }
    if token.kind == TOKEN_NAME {
        graphql_take(p);
        let text = graphql_token_text(p, token);
        let kind = VALUE_ENUM;
        if text == "true" || text == "false" { kind = VALUE_BOOL; }
        if text == "null" { kind = VALUE_NULL; }
        p.nodes = p.nodes + 1;
        if p.nodes > p.limits.max_nodes {
            return err(graphql_error(p, "node count exceeds configured limit"));
        }
        return ok(Value { kind: kind, source: Span { start: token.start, end: token.end },
                          name: Span { start: token.start, end: token.end },
                          items: [], fields: [] });
    }
    if graphql_punct_is(p, "[") {
        let start = graphql_take(p).start;
        let items: [Value] = [];
        while !graphql_punct_is(p, "]") {
            if graphql_peek(p).kind == TOKEN_EOF {
                return err(graphql_error(p, "unterminated list value"));
            }
            let item_result = graphql_parse_value(p, depth + 1);
            guard let item = item_result else let e = err_of(item_result) { return err(e); }
            push(items, item);
            if len(items) > p.limits.max_breadth {
                return err(graphql_error(p, "input list exceeds configured breadth"));
            }
        }
        let end = graphql_take(p).end;
        p.nodes = p.nodes + 1;
        if p.nodes > p.limits.max_nodes {
            return err(graphql_error(p, "node count exceeds configured limit"));
        }
        return ok(Value { kind: VALUE_LIST, source: Span { start: start, end: end },
                          name: Span { start: 0, end: 0 }, items: items, fields: [] });
    }
    if graphql_punct_is(p, "{") {
        let start = graphql_take(p).start;
        let fields: [Argument] = [];
        while !graphql_punct_is(p, "}") {
            if graphql_peek(p).kind == TOKEN_EOF {
                return err(graphql_error(p, "unterminated input object"));
            }
            if graphql_peek(p).kind != TOKEN_NAME {
                return err(graphql_error(p, "expected input object field name"));
            }
            let field_token = graphql_take(p);
            let field_name = Span { start: field_token.start, end: field_token.end };
            for i in 0..len(fields) {
                if span_text(p.source, fields[i].name) == span_text(p.source, field_name) {
                    return err(graphql_error(p, "duplicate input object field"));
                }
            }
            if !graphql_punct_is(p, ":") {
                return err(graphql_error(p, "expected ':' after input object field"));
            }
            graphql_take(p);
            let value_result = graphql_parse_value(p, depth + 1);
            guard let value = value_result else let e = err_of(value_result) { return err(e); }
            push(fields, Argument { name: field_name, value: value });
            if len(fields) > p.limits.max_breadth {
                return err(graphql_error(p, "input object exceeds configured breadth"));
            }
        }
        let end = graphql_take(p).end;
        p.nodes = p.nodes + 1;
        if p.nodes > p.limits.max_nodes {
            return err(graphql_error(p, "node count exceeds configured limit"));
        }
        return ok(Value { kind: VALUE_OBJECT, source: Span { start: start, end: end },
                          name: Span { start: 0, end: 0 }, items: [], fields: fields });
    }
    return err(graphql_error(p, "expected a scalar, variable, list, or object value"));
}

fn graphql_peek(p: Parser) -> Token {
    return p.tokens[p.pos];
}

fn graphql_take(p: Parser) -> Token {
    let token = p.tokens[p.pos];
    if token.kind != TOKEN_EOF { p.pos = p.pos + 1; }
    return token;
}

fn graphql_punct_is(p: Parser, value: str) -> bool {
    let token = graphql_peek(p);
    return token.kind == TOKEN_PUNCT && graphql_token_text(p, token) == value;
}

fn graphql_keyword(p: Parser, value: str) -> bool {
    let token = graphql_peek(p);
    return token.kind == TOKEN_NAME && graphql_token_text(p, token) == value;
}

fn graphql_token_text(p: Parser, token: Token) -> str {
    return strings.from_bytes(p.source, token.start, token.end);
}

fn graphql_error(p: Parser, message: str) -> str {
    let token = graphql_peek(p);
    let line = 1;
    let column = 1;
    for i in 0..token.start {
        if p.source[i] == 10 { line = line + 1; column = 1; }
        else { column = column + 1; }
    }
    return "graphql parse: line " + to_str(line) + ", column " +
           to_str(column) + ": " + message;
}

fn graphql_name_start(c: int) -> bool {
    return c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

fn graphql_name_continue(c: int) -> bool {
    return graphql_name_start(c) || (c >= 48 && c <= 57);
}

fn graphql_punct(c: int) -> bool {
    return c == 33 || c == 36 || c == 38 || c == 40 || c == 41 ||
           c == 58 || c == 61 || c == 64 || c == 91 || c == 93 ||
           c == 123 || c == 124 || c == 125;
}

fn graphql_scan_number(source: bytes, start: int) -> result[int, str] {
    let i = start;
    if source[i] == 45 {
        i = i + 1;
        if i >= len(source) { return err("graphql parse: '-' must start a number"); }
    }
    if source[i] == 48 {
        i = i + 1;
        if i < len(source) && source[i] >= 48 && source[i] <= 57 {
            return err("graphql parse: integer cannot have a leading zero");
        }
    } else if source[i] >= 49 && source[i] <= 57 {
        while i < len(source) && source[i] >= 48 && source[i] <= 57 { i = i + 1; }
    } else {
        return err("graphql parse: expected digits in number");
    }
    if i < len(source) && source[i] == 46 {
        i = i + 1;
        if i >= len(source) || source[i] < 48 || source[i] > 57 {
            return err("graphql parse: decimal point must be followed by digits");
        }
        while i < len(source) && source[i] >= 48 && source[i] <= 57 { i = i + 1; }
    }
    if i < len(source) && (source[i] == 69 || source[i] == 101) {
        i = i + 1;
        if i < len(source) && (source[i] == 43 || source[i] == 45) { i = i + 1; }
        if i >= len(source) || source[i] < 48 || source[i] > 57 {
            return err("graphql parse: exponent must contain digits");
        }
        while i < len(source) && source[i] >= 48 && source[i] <= 57 { i = i + 1; }
    }
    return ok(i);
}

fn graphql_scan_string(source: bytes, start: int) -> result[int, str] {
    let i = start + 1;
    while i < len(source) {
        let c = source[i];
        if c == 34 { return ok(i + 1); }
        if c < 32 { return err("graphql parse: unescaped control in string"); }
        if c == 92 {
            i = i + 1;
            if i >= len(source) { return err("graphql parse: truncated string escape"); }
            let escape = source[i];
            if escape == 34 || escape == 92 || escape == 47 || escape == 98 ||
               escape == 102 || escape == 110 || escape == 114 || escape == 116 {
                i = i + 1;
                continue;
            }
            if escape != 117 || i + 4 >= len(source) {
                return err("graphql parse: invalid string escape");
            }
            for j in i + 1..i + 5 {
                if graphql_hex(source[j]) < 0 {
                    return err("graphql parse: invalid Unicode escape");
                }
            }
            let code = 0;
            for j in i + 1..i + 5 {
                code = code * 16 + graphql_hex(source[j]);
            }
            if code >= 55296 && code <= 56319 {
                if i + 10 >= len(source) || source[i + 5] != 92 ||
                   source[i + 6] != 117 {
                    return err("graphql parse: high surrogate lacks a low surrogate");
                }
                let low = 0;
                for j in i + 7..i + 11 {
                    let digit = graphql_hex(source[j]);
                    if digit < 0 { return err("graphql parse: invalid Unicode escape"); }
                    low = low * 16 + digit;
                }
                if low < 56320 || low > 57343 {
                    return err("graphql parse: invalid low surrogate");
                }
                i = i + 11;
                continue;
            }
            if code >= 56320 && code <= 57343 {
                return err("graphql parse: unpaired low surrogate");
            }
            i = i + 5;
            continue;
        }
        i = i + 1;
    }
    return err("graphql parse: unterminated string");
}

fn graphql_hex(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 65 && c <= 70 { return c - 65 + 10; }
    if c >= 97 && c <= 102 { return c - 97 + 10; }
    return -1;
}

fn graphql_utf8_valid(raw: bytes) -> bool {
    let i = 0;
    while i < len(raw) {
        let a = raw[i];
        if a <= 127 { i = i + 1; continue; }
        if a >= 194 && a <= 223 {
            if i + 1 >= len(raw) || raw[i + 1] < 128 || raw[i + 1] > 191 { return false; }
            i = i + 2;
            continue;
        }
        if a >= 224 && a <= 239 {
            if i + 2 >= len(raw) || raw[i + 1] < 128 || raw[i + 1] > 191 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 { return false; }
            if a == 224 && raw[i + 1] < 160 { return false; }
            if a == 237 && raw[i + 1] >= 160 { return false; }
            i = i + 3;
            continue;
        }
        if a >= 240 && a <= 244 {
            if i + 3 >= len(raw) || raw[i + 1] < 128 || raw[i + 1] > 191 ||
               raw[i + 2] < 128 || raw[i + 2] > 191 ||
               raw[i + 3] < 128 || raw[i + 3] > 191 { return false; }
            if a == 240 && raw[i + 1] < 144 { return false; }
            if a == 244 && raw[i + 1] >= 144 { return false; }
            i = i + 4;
            continue;
        }
        return false;
    }
    return true;
}

pub fn validate_document(doc: Document, requested_name: str)
                         -> result[Operation, str] {
    let selected = operation(doc, requested_name);
    guard let op = selected else let e = err_of(selected) { return err(e); }
    let known: map[str]bool = {};
    let used: map[str]bool = {};
    for i in 0..len(op.variables) {
        let name = span_text(doc.source, op.variables[i].name);
        known[name] = true;
    }
    let active: map[str]bool = {};
    let checked = graphql_check_variables_in_selections(
        doc, op.selections, op, known, used, active, 0);
    guard let _ok = checked else let e = err_of(checked) { return err(e); }
    let directive_check = graphql_check_variable_args(
        doc, op.directives, op, known, used, active, 0);
    guard let _directives_ok = directive_check else let e = err_of(directive_check) {
        return err(e);
    }
    for i in 0..len(op.variables) {
        let name = span_text(doc.source, op.variables[i].name);
        if !has(used, name) {
            return err("graphql validation: variable $" + name + " is never used");
        }
    }
    return ok(op);
}

fn graphql_validate_structure(doc: Document) -> result[bool, str] {
    for i in 0..len(doc.fragments) {
        let active: map[str]bool = {};
        let name = span_text(doc.source, doc.fragments[i].name);
        active[name] = true;
        let checked = graphql_check_fragment_spreads(
            doc, doc.fragments[i].selections, active, 0);
        guard let _ok = checked else let e = err_of(checked) { return err(e); }
    }
    for i in 0..len(doc.operations) {
        let active: map[str]bool = {};
        let checked = graphql_check_fragment_spreads(
            doc, doc.operations[i].selections, active, 0);
        guard let _ok = checked else let e = err_of(checked) { return err(e); }
    }
    return ok(true);
}

fn graphql_check_fragment_spreads(doc: Document, selections: [Selection],
                                  active: map[str]bool, depth: int)
                                  -> result[bool, str] {
    if depth > HARD_MAX_FRAGMENTS {
        return err("graphql validation: fragment expansion exceeds hard limit");
    }
    for i in 0..len(selections) {
        let selection = selections[i];
        if selection.kind == SELECTION_SPREAD {
            let name = span_text(doc.source, selection.name);
            if has(active, name) {
                return err("graphql validation: fragment cycle includes " + name);
            }
            let found = fragment(doc, name);
            guard let item = found else {
                return err("graphql validation: unknown fragment " + name);
            }
            active[name] = true;
            let nested = graphql_check_fragment_spreads(
                doc, item.selections, active, depth + 1);
            del(active, name);
            guard let _ok = nested else let e = err_of(nested) { return err(e); }
        } else {
            let nested = graphql_check_fragment_spreads(
                doc, selection.children, active, depth + 1);
            guard let _ok = nested else let e = err_of(nested) { return err(e); }
        }
    }
    return ok(true);
}

fn graphql_check_variables_in_selections(doc: Document,
                                         selections: [Selection],
                                         operation: Operation,
                                         known: map[str]bool,
                                         used: map[str]bool,
                                         active: map[str]bool,
                                         depth: int) -> result[bool, str] {
    if depth > doc.node_count + 1 {
        return err("graphql validation: fragment expansion exceeded node budget");
    }
    for i in 0..len(selections) {
        let selection = selections[i];
        let args = graphql_check_variable_values(
            doc, selection.arguments, operation, known, used, depth + 1);
        guard let _args_ok = args else let e = err_of(args) { return err(e); }
        let dirs = graphql_check_variable_args(
            doc, selection.directives, operation, known, used, active, depth + 1);
        guard let _dirs_ok = dirs else let e = err_of(dirs) { return err(e); }
        if selection.kind == SELECTION_SPREAD {
            let name = span_text(doc.source, selection.name);
            if !has(active, name) {
                let found = fragment(doc, name);
                guard let item = found else {
                    return err("graphql validation: unknown fragment " + name);
                }
                active[name] = true;
                let nested = graphql_check_variables_in_selections(
                    doc, item.selections, operation, known, used, active, depth + 1);
                del(active, name);
                guard let _ok = nested else let e = err_of(nested) { return err(e); }
            }
        } else {
            let nested = graphql_check_variables_in_selections(
                doc, selection.children, operation, known, used, active, depth + 1);
            guard let _ok = nested else let e = err_of(nested) { return err(e); }
        }
    }
    return ok(true);
}

fn graphql_check_variable_args(doc: Document, directives: [Directive],
                               operation: Operation, known: map[str]bool,
                               used: map[str]bool, active: map[str]bool,
                               depth: int) -> result[bool, str] {
    for i in 0..len(directives) {
        let args = graphql_check_variable_values(
            doc, directives[i].arguments, operation, known, used, depth + 1);
        guard let _ok = args else let e = err_of(args) { return err(e); }
    }
    return ok(true);
}

fn graphql_check_variable_values(doc: Document, arguments: [Argument],
                                 operation: Operation, known: map[str]bool,
                                 used: map[str]bool, depth: int)
                                 -> result[bool, str] {
    for i in 0..len(arguments) {
        let checked = graphql_check_variable_value(
            doc, arguments[i].value, operation, known, used, depth + 1);
        guard let _ok = checked else let e = err_of(checked) { return err(e); }
    }
    return ok(true);
}

fn graphql_check_variable_value(doc: Document, value: Value,
                                operation: Operation, known: map[str]bool,
                                used: map[str]bool, depth: int)
                                -> result[bool, str] {
    if depth > HARD_MAX_DEPTH {
        return err("graphql validation: input value nesting exceeds hard limit");
    }
    if value.kind == VALUE_VARIABLE {
        let name = span_text(doc.source, value.name);
        if !has(known, name) {
            return err("graphql validation: variable $" + name + " is not defined by this operation");
        }
        used[name] = true;
        return ok(true);
    }
    for i in 0..len(value.items) {
        let nested = graphql_check_variable_value(
            doc, value.items[i], operation, known, used, depth + 1);
        guard let _ok = nested else let e = err_of(nested) { return err(e); }
    }
    for i in 0..len(value.fields) {
        let nested = graphql_check_variable_value(
            doc, value.fields[i].value, operation, known, used, depth + 1);
        guard let _ok = nested else let e = err_of(nested) { return err(e); }
    }
    return ok(true);
}

pub fn should_include(doc: Document, directives: [Directive], variables: Variables,
                      operation: Operation, limits: Limits)
                      -> result[bool, str] {
    let include = true;
    for i in 0..len(directives) {
        let directive = directives[i];
        let name = span_text(doc.source, directive.name);
        if name != "skip" && name != "include" {
            return err("graphql validation: unsupported directive @" + name);
        }
        if len(directive.arguments) != 1 ||
           span_text(doc.source, directive.arguments[0].name) != "if" {
            return err("graphql validation: @" + name + " requires exactly one 'if' argument");
        }
        let encoded = graphql_value_json(doc.source, directive.arguments[0].value,
                                         variables, operation, limits, 0);
        guard let raw = encoded else let e = err_of(encoded) { return err(e); }
        if raw == b"true" {
            if name == "skip" { include = false; }
        } else if raw == b"false" {
            if name == "include" { include = false; }
        } else {
            return err("graphql validation: directive 'if' must be Boolean");
        }
    }
    return ok(include);
}

pub gc struct ExpansionBudget {
    count: int,
    max: int
}

pub fn collect_selections(doc: Document, selections: [Selection], type_name: str,
                          variables: Variables, operation: Operation, limits: Limits)
                          -> result[[Selection], str] {
    let budget = expansion_budget(limits);
    return collect_selections_budget(doc, selections, type_name, variables,
                                     operation, limits, budget);
}

pub fn expansion_budget(limits: Limits) -> ExpansionBudget {
    return ExpansionBudget { count: 0, max: limits.max_nodes };
}

// Cached validation expansions still charge the execution budget once per
// emitted object, matching collect_selections_budget without rescanning ASTs.
pub fn charge_expanded_selection_budget(expanded: [Selection],
                                        budget: ExpansionBudget) -> bool {
    for i in 0..len(expanded) {
        budget.count = budget.count + 1;
        if budget.count > budget.max { return false; }
    }
    return true;
}

pub fn collect_selections_budget(doc: Document, selections: [Selection], type_name: str,
                                  variables: Variables, operation: Operation,
                                  limits: Limits, budget: ExpansionBudget)
                                  -> result[[Selection], str] {
    let expanded: [Selection] = [];
    let expansion_result = graphql_expand_selections(
        doc, selections, type_name, variables, operation, limits, expanded, budget, 0);
    guard let _ok = expansion_result else let e = err_of(expansion_result) { return err(e); }
    return ok(expanded);
}

pub fn type_conditions(doc: Document, limits: Limits) -> result[[str], str] {
    let names: [str] = [];
    let budget = ExpansionBudget { count: 0, max: limits.max_nodes };
    for i in 0..len(doc.fragments) {
        let name = span_text(doc.source, doc.fragments[i].type_condition);
        graphql_add_unique_type(names, name);
        let checked = graphql_collect_inline_conditions(
            doc.source, doc.fragments[i].selections, names, limits, budget, 0);
        guard let _ok = checked else let e = err_of(checked) { return err(e); }
    }
    for i in 0..len(doc.operations) {
        let checked = graphql_collect_inline_conditions(
            doc.source, doc.operations[i].selections, names, limits, budget, 0);
        guard let _ok = checked else let e = err_of(checked) { return err(e); }
    }
    return ok(names);
}

fn graphql_collect_inline_conditions(source: bytes, selections: [Selection],
                                     names: [str], limits: Limits,
                                     budget: ExpansionBudget, depth: int)
                                     -> result[bool, str] {
    if depth > limits.max_depth {
        return err("graphql validation: inline fragment nesting exceeds configured limit");
    }
    for i in 0..len(selections) {
        budget.count = budget.count + 1;
        if budget.count > budget.max {
            return err("graphql validation: fragment condition scan exceeds node limit");
        }
        let selection = selections[i];
        if selection.kind == SELECTION_INLINE {
            graphql_add_unique_type(names, span_text(source, selection.type_condition));
        }
        let nested = graphql_collect_inline_conditions(
            source, selection.children, names, limits, budget, depth + 1);
        guard let _ok = nested else let e = err_of(nested) { return err(e); }
    }
    return ok(true);
}

fn graphql_add_unique_type(names: [str], name: str) {
    for i in 0..len(names) {
        if names[i] == name { return; }
    }
    push(names, name);
}

fn graphql_expand_selections(doc: Document, selections: [Selection], type_name: str,
                             variables: Variables, operation: Operation,
                             limits: Limits, expanded: [Selection],
                             budget: ExpansionBudget, depth: int)
                             -> result[bool, str] {
    if depth > limits.max_depth {
        return err("graphql validation: fragment expansion exceeds configured depth");
    }
    for i in 0..len(selections) {
        let selection = selections[i];
        let include_result = should_include(doc, selection.directives,
                                            variables, operation, limits);
        guard let include = include_result else let e = err_of(include_result) {
            return err(e);
        }
        if !include { continue; }
        if selection.kind == SELECTION_FIELD {
            budget.count = budget.count + 1;
            if budget.count > budget.max {
                return err("graphql validation: expanded selection count exceeds configured limit");
            }
            push(expanded, selection);
            continue;
        }
        if selection.kind == SELECTION_INLINE {
            if span_text(doc.source, selection.type_condition) != type_name { continue; }
            let nested = graphql_expand_selections(
                doc, selection.children, type_name, variables, operation,
                limits, expanded, budget, depth + 1);
            guard let _ok = nested else let e = err_of(nested) { return err(e); }
            continue;
        }
        if selection.kind == SELECTION_SPREAD {
            let name = span_text(doc.source, selection.name);
            let found = fragment(doc, name);
            guard let fragment_value = found else {
                return err("graphql validation: unknown fragment " + name);
            }
            if span_text(doc.source, fragment_value.type_condition) != type_name { continue; }
            let fragment_include = should_include(
                doc, fragment_value.directives, variables, operation, limits);
            guard let include_fragment = fragment_include else let e = err_of(fragment_include) {
                return err(e);
            }
            if !include_fragment { continue; }
            let nested = graphql_expand_selections(
                doc, fragment_value.selections, type_name, variables, operation,
                limits, expanded, budget, depth + 1);
            guard let _ok = nested else let e = err_of(nested) { return err(e); }
            continue;
        }
        return err("graphql validation: selection has an unsupported kind");
    }
    return ok(true);
}
