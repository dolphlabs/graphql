import "builder";
import "json";
import "strings";

fn generate_execution(out: builder.Str, schema: Schema, context_type: str) {
    out.write_line("// Reuse validated selections and typed arguments during execution.");
    out.write_line("gc struct graphql_ExpansionEntry { type_id: int, incoming: [__graphql.Selection], expanded: [__graphql.Selection] }");

    let arg_field_types: [str] = [];
    let arg_field_names: [str] = [];
    for i in 0..len(schema.types) {
        let td = schema.types[i];
        for j in 0..len(td.fields) {
            let f = td.fields[j];
            if len(f.args) == 0 { continue; }
            out.write_line(
                "gc struct graphql_ArgsEntry_" + td.name + "_" + f.name +
                " { selection: __graphql.Selection, args: " + td.name + "_" + f.name + "_Args }"
            );
            push(arg_field_types, td.name);
            push(arg_field_names, f.name);
        }
    }
    out.write_line("");

    out.write_line("gc struct graphql_ExecutionPlan {");
    if len(arg_field_types) == 0 {
        out.write_line("    expansions: [graphql_ExpansionEntry]");
    } else {
        out.write_line("    expansions: [graphql_ExpansionEntry],");
        for i in 0..len(arg_field_types) {
            let tn = arg_field_types[i];
            let fnm = arg_field_names[i];
            let line = "    args_" + tn + "_" + fnm + ": [graphql_ArgsEntry_" + tn + "_" + fnm + "]";
            if i + 1 < len(arg_field_types) {
                line = line + ",";
            }
            out.write_line(line);
        }
    }
    out.write_line("}");
    out.write_line("");

    out.write_line("fn graphql_same_selection_list(a: [__graphql.Selection], b: [__graphql.Selection]) -> bool {");
    out.write_line("    if len(a) != len(b) { return false; }");
    out.write_line("    for i in 0..len(a) {");
    out.write_line("        let left = a[i];");
    out.write_line("        let right = b[i];");
    out.write_line("        if left.kind != right.kind || left.name.start != right.name.start || left.name.end != right.name.end || left.alias.start != right.alias.start || left.alias.end != right.alias.end || left.type_condition.start != right.type_condition.start || left.type_condition.end != right.type_condition.end { return false; }");
    out.write_line("    }");
    out.write_line("    return true;");
    out.write_line("}");
    out.write_line("");

    out.write_line("fn graphql_expansion_index(plan: graphql_ExecutionPlan, type_id: int, incoming: [__graphql.Selection]) -> int {");
    out.write_line("    for i in 0..len(plan.expansions) {");
    out.write_line("        let entry = plan.expansions[i];");
    out.write_line("        if entry.type_id == type_id && graphql_same_selection_list(entry.incoming, incoming) { return i; }");
    out.write_line("    }");
    out.write_line("    return -1;");
    out.write_line("}");
    out.write_line("");

    for i in 0..len(arg_field_types) {
        let tn = arg_field_types[i];
        let fnm = arg_field_names[i];
        out.write_line("fn graphql_args_index_" + tn + "_" + fnm + "(plan: graphql_ExecutionPlan, selection: __graphql.Selection) -> int {");
        out.write_line("    for i in 0..len(plan.args_" + tn + "_" + fnm + ") {");
        out.write_line("        let planned = plan.args_" + tn + "_" + fnm + "[i].selection;");
        out.write_line("        if planned.name.start == selection.name.start && planned.name.end == selection.name.end && planned.alias.start == selection.alias.start && planned.alias.end == selection.alias.end { return i; }");
        out.write_line("    }");
        out.write_line("    return -1;");
        out.write_line("}");
        out.write_line("");
    }

    out.write_line("// A caller-owned parsed operation. Keep one handle per persisted operation.");
    out.write_line("pub gc struct graphql_PreparedQuery { document: __graphql.Document, operation: __graphql.Operation, limits: __graphql.Limits }");
    out.write_line("struct graphql_ParsedQuery { document: __graphql.Document, operation: __graphql.Operation }");
    out.write_line("");

    out.write_line("fn graphql_parse_query(query: str, operation_name: str, limits: __graphql.Limits) -> result[graphql_ParsedQuery, str] {");
    out.write_line("    let planned = __graphql.plan_uncached(query, operation_name, limits, graphql_schema_has_object_type);");
    out.write_line("    guard let plan = planned else let e = err_of(planned) { return err(e); }");
    out.write_line("    return ok(graphql_ParsedQuery { document: plan.document, operation: plan.operation });");
    out.write_line("}");
    out.write_line("");

    out.write_line("pub fn graphql_prepare(query: str, operation_name: str, limits: __graphql.Limits) -> result[graphql_PreparedQuery, str] {");
    out.write_line("    let parsed_result = graphql_parse_query(query, operation_name, limits);");
    out.write_line("    guard let parsed = parsed_result else let e = err_of(parsed_result) { return err(e); }");
    out.write_line("    return ok(graphql_PreparedQuery { document: parsed.document, operation: parsed.operation, limits: limits });");
    out.write_line("}");
    out.write_line("");

    out.write_line("pub fn graphql_execute(query: str, operation_name: str, variables_json: bytes, context: " + context_type + ", limits: __graphql.Limits) -> result[bytes, str] {");
    out.write_line("    let parsed_result = graphql_parse_query(query, operation_name, limits);");
    out.write_line("    guard let parsed = parsed_result else let e = err_of(parsed_result) { return __graphql.failure(e, limits); }");
    out.write_line("    return graphql_execute_document(parsed.document, parsed.operation, variables_json, context, limits);");
    out.write_line("}");
    out.write_line("");

    out.write_line("pub fn graphql_execute_prepared(prepared: graphql_PreparedQuery, variables_json: bytes, context: " + context_type + ") -> result[bytes, str] {");
    out.write_line("    return graphql_execute_document(prepared.document, prepared.operation, variables_json, context, prepared.limits);");
    out.write_line("}");
    out.write_line("");

    out.write_line("// graphql_execute with each query's plan (parse, type conditions, validated");
    out.write_line("// operation) kept in a caller-owned __graphql.PlanCache, keyed by the query");
    out.write_line("// text: for clients that resend the same query without persisting it.");
    out.write_line("pub fn graphql_execute_cached(cache: __graphql.PlanCache, query: str, operation_name: str, variables_json: bytes, context: " + context_type + ", limits: __graphql.Limits) -> result[bytes, str] {");
    out.write_line("    let planned = __graphql.plan(cache, query, operation_name, limits, graphql_schema_has_object_type);");
    out.write_line("    guard let plan = planned else let e = err_of(planned) { return __graphql.failure(e, limits); }");
    out.write_line("    return graphql_execute_document(plan.document, plan.operation, variables_json, context, limits);");
    out.write_line("}");
    out.write_line("");

    out.write_line("fn graphql_execute_document(doc: __graphql.Document, operation: __graphql.Operation, variables_json: bytes, context: " + context_type + ", limits: __graphql.Limits) -> result[bytes, str] {");
    out.write_line("    let variables_result = __graphql.parse_variables(variables_json, limits);");
    out.write_line("    guard let variables = variables_result else let e = err_of(variables_result) { return __graphql.failure(e, limits); }");
    out.write_line("    let errors_result = __graphql.errors_new(100);");
    out.write_line("    guard let errors = errors_result else let e = err_of(errors_result) { return err(e); }");
    out.write_line("    let args_plan = graphql_ExecutionPlan {");
    if len(arg_field_types) == 0 {
        out.write_line("        expansions: []");
    } else {
        out.write_line("        expansions: [],");
        for i in 0..len(arg_field_types) {
            let line = "        args_" + arg_field_types[i] + "_" + arg_field_names[i] + ": []";
            if i + 1 < len(arg_field_types) {
                line = line + ",";
            }
            out.write_line(line);
        }
    }
    out.write_line("    };");

    generate_root_exec_branch(out, "__graphql.OP_QUERY", schema.query_type);
    if schema.has_mutation {
        generate_root_exec_branch(out, "__graphql.OP_MUTATION", schema.mutation_type);
    }
    out.write_line("    return __graphql.failure(\"unsupported operation kind\", limits);");
    out.write_line("}");
    out.write_line("");

    out.write_line("fn graphql_schema_has_object_type(name: str) -> bool {");
    for i in 0..len(schema.types) {
        out.write_line("    if name == " + json.encode(schema.types[i].name) + " { return true; }");
    }
    out.write_line("    return false;");
    out.write_line("}");
    out.write_line("");

    for i in 0..len(schema.inputs) {
        generate_input_normalizer(out, schema, schema.inputs[i]);
    }

    for i in 0..len(schema.types) {
        let td = schema.types[i];
        for j in 0..len(td.fields) {
            let f = td.fields[j];
            if len(f.args) == 0 { continue; }
            generate_resolver_args(out, schema, td.name, f);
        }
    }

    for type_id in 0..len(schema.types) {
        let td = schema.types[type_id];
        generate_validator(out, schema, td, type_id, context_type);
        generate_emitter(out, schema, td, type_id, context_type);
        for j in 0..len(td.fields) {
            generate_field_encoders(out, schema, td.name, td.fields[j], context_type);
        }
    }
}

fn generate_root_exec_branch(out: builder.Str, op_const: str, root_name: str) {
    out.write_line("    if operation.kind == " + op_const + " {");
    out.write_line("        let validation_budget = __graphql.expansion_budget(limits);");
    out.write_line("        let checked = graphql_validate_" + root_name + "(operation.selections, doc, variables, operation, context, limits, args_plan, validation_budget, 0);");
    out.write_line("        guard let _valid = checked else let e = err_of(checked) { return __graphql.failure(e, limits); }");
    out.write_line("        let execution_budget = __graphql.expansion_budget(limits);");
    out.write_line("        let execution = graphql_emit_" + root_name + "(__graphql.root_new(), operation.selections, doc, variables, operation, context, errors, limits, args_plan, execution_budget, 0);");
    out.write_line("        let data = b\"null\";");
    out.write_line("        if let value = execution { data = value; } else let e = err_of(execution) {");
    out.write_line("            if e != \"graphql_nonnull_bubble\" {");
    out.write_line("                let added = __graphql.error_add(errors, \"execution failed\");");
    out.write_line("                guard let _ok = added else let add_error = err_of(added) { return err(add_error); }");
    out.write_line("            }");
    out.write_line("        }");
    out.write_line("        return __graphql.execution_response(data, errors, limits);");
    out.write_line("    }");
}

fn generate_input_normalizer(out: builder.Str, schema: Schema, inp: InputDef) {
    out.write_line("fn graphql_normalize_input_" + inp.name + "(raw: bytes, limits: __graphql.Limits, depth: int) -> result[bytes, str] {");
    out.write_line("    if depth > limits.max_depth { return err(\"graphql validation: input object depth exceeds configured limit\"); }");
    out.write_line("    let parsed_result = __graphql.parse_input_object(raw, limits);");
    out.write_line("    guard let fields = parsed_result else let e = err_of(parsed_result) { return err(e); }");
    let key_list = builder.new_str();
    key_list.write("[");
    for i in 0..len(inp.fields) {
        if i > 0 { key_list.write(", "); }
        key_list.write(json.encode(inp.fields[i].name));
    }
    key_list.write("]");
    out.write_line("    let known_result = __graphql.validate_object_keys(fields, " + key_list.finish() + ");");
    out.write_line("    guard let _known = known_result else let e = err_of(known_result) { return err(e); }");
    out.write_line("    let out = builder.new_bytes();");
    out.write_line("    out.write_byte(123);");
    out.write_line("    let written = 0;");
    for i in 0..len(inp.fields) {
        let inf = inp.fields[i];
        let idx = to_str(i);
        let prefix = "graphql_normalize_input_" + inp.name + "_" + inf.name;
        out.write_line("    let value_result_" + idx + " = __graphql.variables_get(fields, " + json.encode(inf.name) + ");");
        out.write_line("    if let raw_value_" + idx + " = value_result_" + idx + " {");
        out.write_line("        let normalized_result_" + idx + " = " + prefix + "_0(raw_value_" + idx + ", limits, depth + 1);");
        out.write_line("        guard let normalized_" + idx + " = normalized_result_" + idx + " else let e = err_of(normalized_result_" + idx + ") { return err(e); }");
        out.write_line("        if written > 0 { out.write_byte(44); }");
        out.write_line("        out.write(b" + json.encode(json.encode(inf.name) + ":") + ");");
        out.write_line("        out.write(normalized_" + idx + ");");
        out.write_line("        written = written + 1;");
        out.write_line("    } else {");
        if inf.has_default {
            out.write_line("        if written > 0 { out.write_byte(44); }");
            out.write_line("        out.write(b" + json.encode(json.encode(inf.name) + ":") + ");");
            out.write_line("        out.write(b" + json.encode(value_json(inf.default_val)) + ");");
            out.write_line("        written = written + 1;");
        } else if inf.typ.non_null {
            out.write_line("        return err(" + json.encode("graphql validation: required input field " + inp.name + "." + inf.name + " is missing") + ");");
        }
        out.write_line("    }");
    }
    out.write_line("    out.write_byte(125);");
    out.write_line("    if out.size() > limits.max_response_bytes { return err(\"graphql validation: normalized input exceeds byte limit\"); }");
    out.write_line("    return ok(out.finish());");
    out.write_line("}");
    out.write_line("");

    for i in 0..len(inp.fields) {
        let inf = inp.fields[i];
        generate_value_normalizer(out, schema, "graphql_normalize_input_" + inp.name + "_" + inf.name, inf.typ, 0);
    }
}

fn generate_value_normalizer(out: builder.Str, schema: Schema, prefix: str, t: TypeRef, level: int) {
    let fname = prefix + "_" + to_str(level);
    out.write_line("fn " + fname + "(raw: bytes, limits: __graphql.Limits, depth: int) -> result[bytes, str] {");
    out.write_line("    if len(raw) == 0 { return err(\"graphql validation: missing input value\"); }");
    if t.non_null {
        out.write_line("    if raw == b\"null\" { return err(\"graphql validation: null for non-null input value\"); }");
    } else {
        out.write_line("    if raw == b\"null\" { return ok(raw); }");
    }

    if t.is_list {
        let next_fn = prefix + "_" + to_str(level + 1);
        out.write_line("    if raw[0] != 91 {");
        out.write_line("        let item_result = " + next_fn + "(raw, limits, depth + 1);");
        out.write_line("        guard let item = item_result else let e = err_of(item_result) { return err(e); }");
        out.write_line("        let one = builder.new_bytes();");
        out.write_line("        one.write_byte(91);");
        out.write_line("        one.write(item);");
        out.write_line("        one.write_byte(93);");
        out.write_line("        return ok(one.finish());");
        out.write_line("    }");
        out.write_line("    let items_result = __graphql.json_array_values(raw, limits);");
        out.write_line("    guard let items = items_result else let e = err_of(items_result) { return err(e); }");
        out.write_line("    let out = builder.new_bytes();");
        out.write_line("    out.write_byte(91);");
        out.write_line("    for i in 0..len(items) {");
        out.write_line("        if i > 0 { out.write_byte(44); }");
        out.write_line("        let item_result = " + next_fn + "(items[i], limits, depth + 1);");
        out.write_line("        guard let item = item_result else let e = err_of(item_result) { return err(e); }");
        out.write_line("        out.write(item);");
        out.write_line("    }");
        out.write_line("    out.write_byte(93);");
        out.write_line("    if out.size() > limits.max_response_bytes { return err(\"graphql validation: normalized list exceeds byte limit\"); }");
        out.write_line("    return ok(out.finish());");
        out.write_line("}");
        out.write_line("");
        if let inner = t.inner {
            generate_value_normalizer(out, schema, prefix, inner, level + 1);
        }
        return;
    }

    if t.name == "ID" {
        out.write_line("    return __graphql.normalize_id(raw);");
    } else if t.name == "Int" {
        out.write_line("    return __graphql.normalize_int32(raw);");
    } else if has(schema.input_map, t.name) {
        out.write_line("    return graphql_normalize_input_" + t.name + "(raw, limits, depth + 1);");
    } else {
        out.write_line("    return ok(raw);");
    }
    out.write_line("}");
    out.write_line("");
}

fn generate_resolver_arg(out: builder.Str, schema: Schema, type_name: str, field_name: str, arg: InputValueDef) {
    let prefix = "graphql_normalize_arg_" + type_name + "_" + field_name + "_" + arg.name;

    let stype = slang_type(arg.typ);
    let gtype = graphql_type_str(arg.typ);
    let has_def = "false";
    if arg.has_default { has_def = "true"; }

    out.write_line(
        "fn graphql_resolver_arg_" + type_name + "_" + field_name + "_" + arg.name +
        "(doc: __graphql.Document, selection: __graphql.Selection, variables: __graphql.Variables, operation: __graphql.Operation, limits: __graphql.Limits) -> result[" + stype + ", str] {"
    );
    out.write_line("    let found = __graphql.find_argument(doc, selection, " + json.encode(arg.name) + ");");
    out.write_line("    let raw = b\"\";");
    out.write_line("    if let _ = found {");
    out.write_line("        guard let argument = found else { return err(\"graphql validation: argument lookup failed\"); }");
    out.write_line("        let variable_type = __graphql.validate_variable_type(doc, operation, argument.value, " + json.encode(gtype) + ", " + has_def + ");");
    out.write_line("        guard let _type_ok = variable_type else let e = err_of(variable_type) { return err(e); }");
    out.write_line("        if __graphql.variable_missing(doc, argument.value, variables, operation) {");
    if arg.has_default {
        out.write_line("            raw = b" + json.encode(value_json(arg.default_val)) + ";");
    } else if arg.typ.non_null {
        out.write_line("            return err(" + json.encode("graphql validation: required variable for argument " + arg.name + " is missing") + ");");
    } else {
        out.write_line("            return ok(none);");
    }
    out.write_line("        } else {");
    out.write_line("            let value_result = __graphql.value_json(doc, argument.value, variables, operation, limits);");
    out.write_line("            guard let value = value_result else let e = err_of(value_result) { return err(e); }");
    out.write_line("            raw = value;");
    out.write_line("        }");
    out.write_line("    } else {");
    if arg.has_default {
        out.write_line("        raw = b" + json.encode(value_json(arg.default_val)) + ";");
    } else if arg.typ.non_null {
        out.write_line("        return err(" + json.encode("graphql validation: required argument " + arg.name + " is missing") + ");");
    } else {
        out.write_line("        return ok(none);");
    }
    out.write_line("    }");
    out.write_line("    let normalized_result = " + prefix + "_0(raw, limits, 0);");
    out.write_line("    guard let normalized = normalized_result else let e = err_of(normalized_result) { return err(e); }");
    out.write_line("    let typed_result: result[" + stype + ", str] = json.decode(normalized);");
    out.write_line("    return typed_result;");
    out.write_line("}");
    out.write_line("");
}

fn generate_resolver_args(out: builder.Str, schema: Schema, type_name: str, f: FieldDef) {
    for i in 0..len(f.args) {
        let arg = f.args[i];
        generate_value_normalizer(out, schema, "graphql_normalize_arg_" + type_name + "_" + f.name + "_" + arg.name, arg.typ, 0);
    }
    for i in 0..len(f.args) {
        generate_resolver_arg(out, schema, type_name, f.name, f.args[i]);
    }
    let args_struct = type_name + "_" + f.name + "_Args";
    out.write_line(
        "fn graphql_resolver_args_" + type_name + "_" + f.name +
        "(doc: __graphql.Document, selection: __graphql.Selection, variables: __graphql.Variables, operation: __graphql.Operation, limits: __graphql.Limits) -> result[" + args_struct + ", str] {"
    );
    out.write_line("    for i in 0..len(selection.arguments) {");
    out.write_line("        let actual = __graphql.span_text(doc.source, selection.arguments[i].name);");
    for i in 0..len(f.args) {
        out.write_line("        if actual == " + json.encode(f.args[i].name) + " { continue; }");
    }
    out.write_line("        return err(\"graphql validation: unknown argument \" + actual);");
    out.write_line("    }");
    for i in 0..len(f.args) {
        let idx = to_str(i);
        out.write_line("    let arg_result_" + idx + " = graphql_resolver_arg_" + type_name + "_" + f.name + "_" + f.args[i].name + "(doc, selection, variables, operation, limits);");
        out.write_line("    guard let arg_" + idx + " = arg_result_" + idx + " else let e = err_of(arg_result_" + idx + ") { return err(e); }");
    }
    out.write_line("    return ok(" + args_struct + " {");
    for i in 0..len(f.args) {
        let line = "        " + f.args[i].name + ": arg_" + to_str(i);
        if i + 1 < len(f.args) { line = line + ","; }
        out.write_line(line);
    }
    out.write_line("    });");
    out.write_line("}");
    out.write_line("");
}

fn generate_validator(out: builder.Str, schema: Schema, td: TypeDef, type_id: int, context_type: str) {
    out.write_line(
        "fn graphql_validate_" + td.name +
        "(incoming: [__graphql.Selection], doc: __graphql.Document, variables: __graphql.Variables, operation: __graphql.Operation, context: " +
        context_type + ", limits: __graphql.Limits, args_plan: graphql_ExecutionPlan, budget: __graphql.ExpansionBudget, depth: int) -> result[bool, str] {"
    );
    out.write_line("    if depth > limits.max_depth { return err(\"graphql validation: selection depth exceeds configured limit\"); }");
    out.write_line("    let expanded_result = __graphql.collect_selections_budget(doc, incoming, " + json.encode(td.name) + ", variables, operation, limits, budget);");
    out.write_line("    guard let selections = expanded_result else let e = err_of(expanded_result) { return err(e); }");
    out.write_line("    push(args_plan.expansions, graphql_ExpansionEntry { type_id: " + to_str(type_id) + ", incoming: incoming, expanded: selections });");
    out.write_line("    let response_names: map[str]bool = {};");
    out.write_line("    for i in 0..len(selections) {");
    out.write_line("        let selection = selections[i];");
    out.write_line("        let response_name = __graphql.response_name(doc, selection);");
    out.write_line("        if has(response_names, response_name) { return err(\"graphql validation: duplicate response name \" + response_name); }");
    out.write_line("        response_names[response_name] = true;");
    out.write_line("        let field_name = __graphql.selection_name(doc, selection);");
    out.write_line("        if field_name == \"__typename\" {");
    out.write_line("            if len(selection.arguments) != 0 || len(selection.children) != 0 { return err(\"graphql validation: __typename takes no arguments or selection set\"); }");
    out.write_line("            continue;");
    out.write_line("        }");
    for i in 0..len(td.fields) {
        let f = td.fields[i];
        out.write_line("        if field_name == " + json.encode(f.name) + " {");
        if len(f.args) > 0 {
            out.write_line("            let typed_args_result = graphql_resolver_args_" + td.name + "_" + f.name + "(doc, selection, variables, operation, limits);");
            out.write_line("            guard let typed_args = typed_args_result else let e = err_of(typed_args_result) { return err(e); }");
            out.write_line("            push(args_plan.args_" + td.name + "_" + f.name + ", graphql_ArgsEntry_" + td.name + "_" + f.name + " { selection: selection, args: typed_args });");
        } else {
            out.write_line("            let args_json_result = __graphql.arguments_json(doc, selection, variables, operation, limits, []);");
            out.write_line("            guard let _args_json = args_json_result else let e = err_of(args_json_result) { return err(e); }");
        }
        let bname = base_type_name(f.typ);
        if has(schema.type_map, bname) {
            out.write_line("            if len(selection.children) == 0 { return err(\"graphql validation: object field requires a selection set\"); }");
            out.write_line("            let nested = graphql_validate_" + bname + "(selection.children, doc, variables, operation, context, limits, args_plan, budget, depth + 1);");
            out.write_line("            guard let _nested_ok = nested else let e = err_of(nested) { return err(e); }");
        } else {
            out.write_line("            if len(selection.children) != 0 { return err(\"graphql validation: scalar field cannot have a selection set\"); }");
        }
        out.write_line("            continue;");
        out.write_line("        }");
    }
    out.write_line("        return err(\"graphql validation: unknown field \" + field_name + \" on \" + " + json.encode(td.name) + ");");
    out.write_line("    }");
    out.write_line("    return ok(true);");
    out.write_line("}");
    out.write_line("");
}

fn generate_emitter(out: builder.Str, schema: Schema, td: TypeDef, type_id: int, context_type: str) {
    let ptype = parent_slang_type(schema, td.name);
    out.write_line(
        "fn graphql_emit_" + td.name +
        "(parent: " + ptype + ", incoming: [__graphql.Selection], doc: __graphql.Document, variables: __graphql.Variables, operation: __graphql.Operation, context: " +
        context_type + ", errors: __graphql.Errors, limits: __graphql.Limits, args_plan: graphql_ExecutionPlan, budget: __graphql.ExpansionBudget, depth: int) -> result[bytes, str] {"
    );
    out.write_line("    if depth > limits.max_depth { return err(\"graphql execution: selection depth exceeds configured limit\"); }");
    out.write_line("    let expansion_index = graphql_expansion_index(args_plan, " + to_str(type_id) + ", incoming);");
    out.write_line("    if expansion_index < 0 { return err(\"graphql execution: validated selection expansion is missing\"); }");
    out.write_line("    let selections = args_plan.expansions[expansion_index].expanded;");
    out.write_line("    if !__graphql.charge_expanded_selection_budget(selections, budget) { return err(\"graphql validation: expanded selection count exceeds configured limit\"); }");
    out.write_line("    let out = builder.new_bytes();");
    out.write_line("    out.write_byte(123);");
    out.write_line("    let written = 0;");
    out.write_line("    for i in 0..len(selections) {");
    out.write_line("        let selection = selections[i];");
    out.write_line("        let field_name = __graphql.selection_name(doc, selection);");
    out.write_line("        let response_name = __graphql.response_name(doc, selection);");
    out.write_line("        if written > 0 { out.write_byte(44); }");
    out.write_line("        let key_result = __graphql.write_json_string_bounded(out, response_name, limits.max_response_bytes);");
    out.write_line("        guard let _key_ok = key_result else let e = err_of(key_result) { return err(e); }");
    out.write_line("        out.write_byte(58);");
    out.write_line("        if field_name == \"__typename\" {");
    out.write_line("            let typename_result = __graphql.write_json_string_bounded(out, " + json.encode(td.name) + ", limits.max_response_bytes);");
    out.write_line("            guard let _typename_ok = typename_result else let e = err_of(typename_result) { return err(e); }");
    out.write_line("            if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
    out.write_line("            written = written + 1;");
    out.write_line("            continue;");
    out.write_line("        }");
    for i in 0..len(td.fields) {
        let f = td.fields[i];
        out.write_line("        if field_name == " + json.encode(f.name) + " {");
        if len(f.args) > 0 {
            out.write_line("            let args_index = graphql_args_index_" + td.name + "_" + f.name + "(args_plan, selection);");
            out.write_line("            if args_index < 0 { return err(\"graphql execution: validated arguments are missing\"); }");
            out.write_line("            let args = args_plan.args_" + td.name + "_" + f.name + "[args_index].args;");
        } else {
            out.write_line("            let args = __graphql.no_args();");
        }
        out.write_line("            let resolved_result = graphql_call_" + td.name + "_" + f.name + "(parent, args, context);");
        out.write_line("            guard let resolved = resolved_result else let _resolver_error = err_of(resolved_result) {");
        out.write_line("                let added = __graphql.error_add(errors, \"resolver failed\");");
        out.write_line("                guard let _added = added else let e = err_of(added) { return err(e); }");
        if f.typ.non_null {
            out.write_line("                return err(\"graphql_nonnull_bubble\");");
        } else {
            out.write_line("                out.write(b\"null\");");
            out.write_line("                if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
            out.write_line("                written = written + 1;");
            out.write_line("                continue;");
        }
        out.write_line("            }");
        out.write_line("            let encoded_result = graphql_encode_" + td.name + "_" + f.name + "_0(resolved, selection, doc, variables, operation, context, errors, limits, args_plan, budget, depth);");
        out.write_line("            guard let encoded = encoded_result else let e = err_of(encoded_result) {");
        out.write_line("                if e != \"graphql_nonnull_bubble\" {");
        out.write_line("                    let added = __graphql.error_add(errors, \"result could not be encoded\");");
        out.write_line("                    guard let _added = added else let add_error = err_of(added) { return err(add_error); }");
        out.write_line("                }");
        if f.typ.non_null {
            out.write_line("                return err(\"graphql_nonnull_bubble\");");
        } else {
            out.write_line("                out.write(b\"null\");");
            out.write_line("                if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
            out.write_line("                written = written + 1;");
            out.write_line("                continue;");
        }
        out.write_line("            }");
        out.write_line("            out.write(encoded);");
        out.write_line("            if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
        out.write_line("            written = written + 1;");
        out.write_line("            continue;");
        out.write_line("        }");
    }
    out.write_line("        return err(\"graphql execution: validated field has no generated resolver\");");
    out.write_line("    }");
    out.write_line("    out.write_byte(125);");
    out.write_line("    if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
    out.write_line("    return ok(out.finish());");
    out.write_line("}");
    out.write_line("");
}

fn generate_field_encoders(out: builder.Str, schema: Schema, type_name: str, f: FieldDef, context_type: str) {
    generate_encoder_level(out, schema, type_name, f.name, f.typ, 0, context_type);
}

fn generate_encoder_level(out: builder.Str, schema: Schema, type_name: str, field_name: str, t: TypeRef, level: int, context_type: str) {
    let lvl = to_str(level);
    let fname = "graphql_encode_" + type_name + "_" + field_name + "_" + lvl;
    out.write_line(
        "fn " + fname +
        "(value: " + slang_type(t) +
        ", selection: __graphql.Selection, doc: __graphql.Document, variables: __graphql.Variables, operation: __graphql.Operation, context: " +
        context_type + ", errors: __graphql.Errors, limits: __graphql.Limits, args_plan: graphql_ExecutionPlan, budget: __graphql.ExpansionBudget, depth: int) -> result[bytes, str] {"
    );
    let val_expr = "value";
    if !t.non_null {
        val_expr = "unwrapped_" + lvl;
        out.write_line("    guard let " + val_expr + " = value else { return ok(b\"null\"); }");
    }

    if t.is_list {
        guard let inner = t.inner else {
            out.write_line("    return ok(b\"[]\");");
            out.write_line("}");
            out.write_line("");
            return;
        }
        let next_fn = "graphql_encode_" + type_name + "_" + field_name + "_" + to_str(level + 1);
        out.write_line("    if len(" + val_expr + ") > limits.max_breadth { return err(\"graphql response list exceeds configured breadth\"); }");
        out.write_line("    let out_" + lvl + " = builder.new_bytes();");
        out.write_line("    out_" + lvl + ".write_byte(91);");
        out.write_line("    for index_" + lvl + " in 0..len(" + val_expr + ") {");
        out.write_line("        if index_" + lvl + " > 0 { out_" + lvl + ".write_byte(44); }");
        out.write_line("        let item_result_" + lvl + " = " + next_fn + "(" + val_expr + "[index_" + lvl + "], selection, doc, variables, operation, context, errors, limits, args_plan, budget, depth);");
        out.write_line("        guard let item_" + lvl + " = item_result_" + lvl + " else let e = err_of(item_result_" + lvl + ") {");
        out.write_line("            if e != \"graphql_nonnull_bubble\" {");
        out.write_line("                let added = __graphql.error_add(errors, \"result could not be encoded\");");
        out.write_line("                guard let _added = added else let add_error = err_of(added) { return err(add_error); }");
        out.write_line("            }");
        if inner.non_null {
            out.write_line("            return err(\"graphql_nonnull_bubble\");");
        } else {
            out.write_line("            out_" + lvl + ".write(b\"null\");");
            out.write_line("            if out_" + lvl + ".size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
            out.write_line("            continue;");
        }
        out.write_line("        }");
        out.write_line("        out_" + lvl + ".write(item_" + lvl + ");");
        out.write_line("        if out_" + lvl + ".size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
        out.write_line("    }");
        out.write_line("    out_" + lvl + ".write_byte(93);");
        out.write_line("    if out_" + lvl + ".size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }");
        out.write_line("    return ok(out_" + lvl + ".finish());");
        out.write_line("}");
        out.write_line("");
        generate_encoder_level(out, schema, type_name, field_name, inner, level + 1, context_type);
        return;
    }

    if has(schema.type_map, t.name) {
        out.write_line("    let encoded_result = graphql_emit_" + t.name + "(" + val_expr + ", selection.children, doc, variables, operation, context, errors, limits, args_plan, budget, depth + 1);");
        out.write_line("    guard let encoded = encoded_result else let e = err_of(encoded_result) {");
        out.write_line("        if e != \"graphql_nonnull_bubble\" {");
        out.write_line("            let added = __graphql.error_add(errors, \"result could not be encoded\");");
        out.write_line("            guard let _added = added else let add_error = err_of(added) { return err(add_error); }");
        out.write_line("        }");
        if t.non_null {
            out.write_line("        return err(\"graphql_nonnull_bubble\");");
        } else {
            out.write_line("        return ok(b\"null\");");
        }
        out.write_line("    }");
        out.write_line("    return ok(encoded);");
        out.write_line("}");
        out.write_line("");
        return;
    }

    if t.name == "String" || t.name == "ID" {
        out.write_line("    if len(" + val_expr + ") > limits.max_response_bytes { return err(\"graphql response string exceeds configured byte limit\"); }");
        out.write_line("    let out = builder.new_bytes();");
        out.write_line("    let written = __graphql.write_json_string_bounded(out, " + val_expr + ", limits.max_response_bytes);");
        out.write_line("    guard let _written = written else let e = err_of(written) { return err(e); }");
        out.write_line("    if out.size() > limits.max_response_bytes { return err(\"graphql response string exceeds configured byte limit\"); }");
        out.write_line("    return ok(out.finish());");
    } else if t.name == "Int" {
        out.write_line("    if " + val_expr + " < -2147483648 || " + val_expr + " > 2147483647 { return err(\"graphql Int result is outside the signed 32-bit range\"); }");
        out.write_line("    let encoded = json.encode(" + val_expr + ");");
        out.write_line("    return ok(to_bytes(encoded));");
    } else if t.name == "Float" {
        out.write_line("    if " + val_expr + " != " + val_expr + " || (" + val_expr + " - " + val_expr + ") != 0.0 { return err(\"graphql Float result is not finite\"); }");
        out.write_line("    let encoded = json.encode(" + val_expr + ");");
        out.write_line("    return ok(to_bytes(encoded));");
    } else {
        out.write_line("    let encoded = json.encode(" + val_expr + ");");
        out.write_line("    return ok(to_bytes(encoded));");
    }
    out.write_line("}");
    out.write_line("");
}
