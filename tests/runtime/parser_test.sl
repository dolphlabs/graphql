fn test_graphql_parse_operations_aliases_and_nested_fields() {
    let parsed = parse("query Get($id: ID!) { user(id: $id) { alias: name age } }",
                       default_limits());
    guard let doc = parsed else let e = err_of(parsed) { panic(e); }
    assert(len(doc.operations) == 1 && doc.node_count > 0,
           "operation and AST node count");
    let selected = validate_document(doc, "Get");
    guard let op = selected else let e = err_of(selected) { panic(e); }
    assert(operation_name(doc, op) == "Get", "named operation retained");
    assert(len(op.variables) == 1 &&
           span_text(doc.source, op.variables[0].type_ref) == "ID!",
           "variable type span retained");
    let user = op.selections[0];
    assert(selection_name(doc, user) == "user" && len(user.arguments) == 1,
           "field and argument parsed");
    assert(len(user.children) == 2 && response_name(doc, user.children[0]) == "alias" &&
           selection_name(doc, user.children[0]) == "name",
           "nested selection and alias retained");
}

fn test_graphql_values_fragments_and_directives() {
    let query = "query Q($skip: Boolean = false, $id: ID!) { " +
                "user(id: $id) @include(if: $skip) { ...UserFields " +
                "... on User { active } } } " +
                "fragment UserFields on User { name }";
    let parsed = parse(query, default_limits());
    guard let doc = parsed else let e = err_of(parsed) { panic(e); }
    let selected = validate_document(doc, "Q");
    guard let op = selected else let e = err_of(selected) { panic(e); }
    assert(len(doc.fragments) == 1 && len(op.selections[0].children) == 2,
           "fragment spread and inline fragment parsed");
    let vars_result = parse_variables(b"{\"skip\":true,\"id\":\"u-1\"}",
                                      default_limits());
    guard let vars = vars_result else let e = err_of(vars_result) { panic(e); }
    let included = should_include(doc, op.selections[0].directives,
                                  vars, op, default_limits());
    guard let show = included else let e = err_of(included) { panic(e); }
    assert(show, "@include resolves variable");
    let collected_result = collect_selections(
        doc, op.selections[0].children, "User", vars, op, default_limits());
    guard let collected = collected_result else let e = err_of(collected_result) { panic(e); }
    assert(len(collected) == 2 && selection_name(doc, collected[0]) == "name" &&
           selection_name(doc, collected[1]) == "active",
           "fragment and matching inline selections expand for the object type");
    let id_json = value_json(doc, op.selections[0].arguments[0].value,
                             vars, op, default_limits());
    guard let encoded_id = id_json else let e = err_of(id_json) { panic(e); }
    assert(encoded_id == b"\"u-1\"", "variable JSON slice retained");
    let skipped_result = parse("query Q($skip: Boolean = false) { user @skip(if: $skip) { id } }",
                               default_limits());
    guard let skipped = skipped_result else let e = err_of(skipped_result) { panic(e); }
    let skipped_op = validate_document(skipped, "Q");
    guard let so = skipped_op else let e = err_of(skipped_op) { panic(e); }
    let empty = parse_variables(b"{}", default_limits());
    guard let empty_vars = empty else let e = err_of(empty) { panic(e); }
    let keep = should_include(skipped, so.selections[0].directives,
                             empty_vars, so, default_limits());
    guard let should_keep = keep else let e = err_of(keep) { panic(e); }
    assert(should_keep, "directive uses variable default");
}

fn test_graphql_argument_json_applies_defaults_and_checks_names() {
    let parsed = parse("query Q($id: ID!, $label: String = \"fallback\") { " +
                       "user(id: $id, label: $label) { id } }", default_limits());
    guard let doc = parsed else let e = err_of(parsed) { panic(e); }
    let selected = validate_document(doc, "Q");
    guard let op = selected else let e = err_of(selected) { panic(e); }
    let vars_result = parse_variables(b"{\"id\":\"42\"}", default_limits());
    guard let vars = vars_result else let e = err_of(vars_result) { panic(e); }
    let specs = [
        ArgSpec { name: "id", type_ref: "ID!", required: true,
                  has_default: false, default_json: b"" },
        ArgSpec { name: "label", type_ref: "String", required: false,
                  has_default: false, default_json: b"" }
    ];
    let encoded_result = arguments_json(doc, op.selections[0], vars, op,
                                        default_limits(), specs);
    guard let encoded = encoded_result else let e = err_of(encoded_result) { panic(e); }
    assert(encoded == b"{\"id\":\"42\",\"label\":\"fallback\"}",
           "variable default is applied while building typed resolver args");
    let omitted = parse("query { user }", default_limits());
    guard let omitted_doc = omitted else let e = err_of(omitted) { panic(e); }
    let omitted_op = validate_document(omitted_doc, "");
    guard let empty_op = omitted_op else let e = err_of(omitted_op) { panic(e); }
    let empty_vars_result = parse_variables(b"{}", default_limits());
    guard let empty_vars = empty_vars_result else let e = err_of(empty_vars_result) { panic(e); }
    assert(is_err(arguments_json(omitted_doc, empty_op.selections[0], empty_vars,
                                 empty_op, default_limits(), specs)),
           "missing required resolver argument is rejected");
    let unknown = parse("query { user(extra: 1) }", default_limits());
    guard let unknown_doc = unknown else let e = err_of(unknown) { panic(e); }
    let unknown_op = validate_document(unknown_doc, "");
    guard let unknown_selected = unknown_op else let e = err_of(unknown_op) { panic(e); }
    assert(is_err(arguments_json(unknown_doc, unknown_selected.selections[0],
                                 empty_vars, unknown_selected, default_limits(), [])),
           "unknown resolver argument is rejected");
    let missing_nullable_result = parse(
        "query Q($label: String) { user(label: $label) }", default_limits());
    guard let missing_nullable = missing_nullable_result else let e = err_of(missing_nullable_result) { panic(e); }
    let nullable_op_result = validate_document(missing_nullable, "Q");
    guard let nullable_op = nullable_op_result else let e = err_of(nullable_op_result) { panic(e); }
    let nullable_specs = [ArgSpec { name: "label", type_ref: "String", required: false,
                                    has_default: false, default_json: b"" }];
    let omitted_nullable = arguments_json(missing_nullable, nullable_op.selections[0],
                                          empty_vars, nullable_op, default_limits(), nullable_specs);
    guard let omitted_json = omitted_nullable else let e = err_of(omitted_nullable) { panic(e); }
    assert(omitted_json == b"{}", "missing nullable variable omits its argument");
}

fn test_graphql_input_value_json_conversion() {
    let parsed = parse("query Q($name: String = \"N\") { " +
                       "find(filter: {name: $name, ids: [1, 2], mode: FAST}) { id } }",
                       default_limits());
    guard let doc = parsed else let e = err_of(parsed) { panic(e); }
    let selected = validate_document(doc, "Q");
    guard let op = selected else let e = err_of(selected) { panic(e); }
    let vars_result = parse_variables(b"{}", default_limits());
    guard let vars = vars_result else let e = err_of(vars_result) { panic(e); }
    let json_result = value_json(doc, op.selections[0].arguments[0].value,
                                 vars, op, default_limits());
    guard let json = json_result else let e = err_of(json_result) { panic(e); }
    assert(json == b"{\"name\":\"N\",\"ids\":[1,2],\"mode\":\"FAST\"}",
           "literal/default arguments become typed decoder JSON");
}

fn test_graphql_rejects_ambiguous_or_hostile_documents() {
    assert(is_err(parse("query { x(a: 1, a: 2) }", default_limits())),
           "duplicate argument rejected");
    assert(is_err(parse("query($x: Int, $x: Int) { x(a: $x) }", default_limits())),
           "duplicate variable rejected");
    assert(is_err(parse("query { x(a: 01) }", default_limits())),
           "leading-zero integer rejected");
    assert(is_err(parse("query { x(a: \"bad\\q\") }", default_limits())),
           "unknown string escape rejected");
    assert(is_err(parse("query { x(a: \"\\uD800\") }", default_limits())),
           "unpaired string surrogate rejected");
    assert(!is_err(parse("query { x(a: \"\\uD83D\\uDE00\") }", default_limits())),
           "valid surrogate pair accepted");
    assert(is_err(parse("subscription S { changed }", default_limits())),
           "subscription rejected with v1 boundary");
    assert(is_err(parse("query { x { ...Loop } } fragment Loop on X { ...Loop }",
                        default_limits())), "fragment cycle rejected");
    assert(is_err(parse("query { x { ...Missing } }", default_limits())),
           "unknown fragment rejected");
    let undefined = parse("query Q { x(a: $missing) }", default_limits());
    guard let doc = undefined else let e = err_of(undefined) { panic(e); }
    assert(is_err(validate_document(doc, "Q")), "undefined variable rejected");
    let unused = parse("query Q($unused: Int) { x }", default_limits());
    guard let unused_doc = unused else let e = err_of(unused) { panic(e); }
    assert(is_err(validate_document(unused_doc, "Q")), "unused variable rejected");
    let multi = parse("query A { x } query B { y }", default_limits());
    guard let multi_doc = multi else let e = err_of(multi) { panic(e); }
    assert(is_err(operation(multi_doc, "")), "ambiguous operation selection rejected");
}

fn test_graphql_variable_json_scanner() {
    let raw = parse_variables(b"{\"id\":\"x\\u0031\",\"nested\":{\"n\":[1,true,null]}}",
                              default_limits());
    guard let vars = raw else let e = err_of(raw) { panic(e); }
    let id = variables_get(vars, "id");
    guard let id_raw = id else { panic("variable key missing"); }
    assert(id_raw == b"\"x\\u0031\"", "variables preserve raw JSON values");
    assert(is_err(parse_variables(b"[]", default_limits())),
           "variables must be a JSON object");
    assert(is_err(parse_variables(b"{\"x\":1,\"x\":2}", default_limits())),
           "duplicate variable keys rejected");
    assert(is_err(parse_variables(b"{\"x\":01}", default_limits())),
           "malformed JSON number rejected");
    assert(is_err(parse_variables(b"{\"x\":{\"a\":1,\"a\":2}}", default_limits())),
           "duplicate nested JSON keys rejected");
    assert(is_err(parse_variables(b"{\"x\":\"\\uD800\"}", default_limits())),
           "unpaired Unicode surrogate rejected");
    let object_limits_result = new_limits(100, 4, 20, 4, 2, 0, 10, 100);
    guard let object_limits = object_limits_result else let e = err_of(object_limits_result) { panic(e); }
    let input_fields = parse_input_object(b"{\"a\":1,\"b\":2}", object_limits);
    guard let input_object = input_fields else let e = err_of(input_fields) { panic(e); }
    assert(len(input_object.entries) == 2,
           "input object fields use breadth budget rather than operation variable budget");
    let array_items = json_array_values(b"[1,{\"x\":true},null]", default_limits());
    guard let items = array_items else let e = err_of(array_items) { panic(e); }
    assert(len(items) == 3 && items[0] == b"1" && items[2] == b"null",
           "bounded JSON array values retain source slices");
}

fn test_graphql_builtin_scalar_input_coercion() {
    let int_value = normalize_int32(b"2147483647");
    guard let max_int = int_value else let e = err_of(int_value) { panic(e); }
    assert(max_int == b"2147483647", "GraphQL Int accepts signed 32-bit maximum");
    assert(is_err(normalize_int32(b"2147483648")), "GraphQL Int rejects overflow");
    assert(is_err(normalize_int32(b"1.0")), "GraphQL Int rejects fractional numbers");
    let string_id = normalize_id(b"\"abc\"");
    guard let original = string_id else let e = err_of(string_id) { panic(e); }
    assert(original == b"\"abc\"", "GraphQL ID accepts strings");
    let integer_id = normalize_id(b"42");
    guard let encoded = integer_id else let e = err_of(integer_id) { panic(e); }
    assert(encoded == b"\"42\"", "GraphQL ID integer input is coerced to string");
    assert(is_err(normalize_id(b"1.5")), "GraphQL ID rejects fractional numbers");
}

fn test_graphql_configurable_limits() {
    let too_deep = new_limits(100, HARD_MAX_DEPTH + 1, 10, 0, 0, 0, 10, 100);
    assert(is_err(too_deep), "hard depth limit enforced");
    let tiny = new_limits(100, 1, 2, 0, 0, 0, 4, 100);
    guard let limits = tiny else let e = err_of(tiny) { panic(e); }
    assert(is_err(parse("query { user { name } }", limits)),
           "selection depth limit enforced");
    assert(is_err(parse("query { a b c }", limits)),
           "node budget enforced");
}

fn test_graphql_response_is_bounded_and_valid_json() {
    let made = errors_new(2);
    guard let errors = made else let e = err_of(made) { panic(e); }
    let add = error_add(errors, "quoted \"message\"\n");
    guard let _added = add else let e = err_of(add) { panic(e); }
    let response_bytes = response(b"{\"ok\":true}", errors, default_limits());
    guard let encoded = response_bytes else let e = err_of(response_bytes) { panic(e); }
    assert(encoded == b"{\"data\":{\"ok\":true},\"errors\":[{\"message\":\"quoted \\\"message\\\"\\n\"}]}",
           "response wraps data and escapes errors as JSON");
    assert(is_err(response(b"{bad}", errors, default_limits())),
           "invalid data JSON rejected");
    assert(is_err(response(b"[]", errors, default_limits())),
           "GraphQL data must be object or null");
    assert(is_err(response(b"{\"x\":1,\"x\":2}", errors, default_limits())),
           "duplicate data keys rejected");
    let tiny_result = new_limits(100, 4, 20, 4, 2, 2, 10, 10);
    guard let tiny = tiny_result else let e = err_of(tiny_result) { panic(e); }
    assert(is_err(response(b"{\"long\":true}", errors, tiny)),
           "response byte limit enforced");
    let escaped = builder.new_bytes();
    assert(is_err(write_json_string_bounded(escaped, strings.repeat("\n", 16), 32)),
           "string escaping stops at its output byte limit");
}

fn is_err[T](value: result[T, str]) -> bool {
    if let _ok = value { return false; }
    return true;
}
