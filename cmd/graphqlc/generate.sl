import "builder";
import "json";
import "strings";

fn valid_context_type(ctx: str) -> bool {
    if len(ctx) == 0 { return false; }
    let parts = strings.split(ctx, ".");
    if len(parts) == 0 { return false; }
    for i in 0..len(parts) {
        if !valid_slang_identifier(parts[i]) {
            return false;
        }
    }
    return true;
}

fn value_json(v: Value) -> str {
    if v.kind == ValueKind.NULL { return "null"; }
    if v.kind == ValueKind.BOOL {
        if v.bool_val { return "true"; }
        return "false";
    }
    if v.kind == ValueKind.INT { return to_str(v.int_val); }
    if v.kind == ValueKind.FLOAT { return v.text; }
    if v.kind == ValueKind.STRING || v.kind == ValueKind.ENUM {
        return json.encode(v.text);
    }
    if v.kind == ValueKind.LIST {
        let out = builder.new_str();
        out.write("[");
        for i in 0..len(v.items) {
            if i > 0 { out.write(","); }
            out.write(value_json(v.items[i]));
        }
        out.write("]");
        return out.finish();
    }
    if v.kind == ValueKind.OBJECT {
        let out = builder.new_str();
        out.write("{");
        for i in 0..len(v.fields) {
            if i > 0 { out.write(","); }
            let vf = v.fields[i];
            out.write(json.encode(vf.name));
            out.write(":");
            out.write(value_json(vf.value));
        }
        out.write("}");
        return out.finish();
    }
    return "null";
}

fn is_root_type(schema: Schema, name: str) -> bool {
    if name == schema.query_type { return true; }
    if schema.has_mutation && name == schema.mutation_type { return true; }
    return false;
}

fn parent_slang_type(schema: Schema, name: str) -> str {
    if is_root_type(schema, name) { return "__graphql.Root"; }
    return name;
}

fn register_generated_symbol(seen: map[str]bool, name: str) -> result[bool, str] {
    if has(seen, name) {
        return err("graphql codegen: generated symbol collision on " + name);
    }
    seen[name] = true;
    return ok(true);
}

fn register_type_ref_normalizers(seen: map[str]bool, prefix: str, t: TypeRef) -> result[bool, str] {
    let cur: opt[TypeRef] = some(t);
    let level = 0;
    while true {
        guard let tr = cur else { break; }
        let rr = register_generated_symbol(seen, prefix + "_" + to_str(level));
        guard let _ok = rr else let e = err_of(rr) { return err(e); }
        if !tr.is_list { break; }
        cur = tr.inner;
        level = level + 1;
    }
    return ok(true);
}

fn validate_generated_names(schema: Schema, context_type: str) -> result[bool, str] {
    if !valid_context_type(context_type) {
        return err("graphql codegen: invalid context type '" + context_type + "'");
    }
    let seen: map[str]bool = {};
    let reserved_globals = [
        "__graphql", "builder", "json",
        "GRAPHQL_QUERY_ROOT", "GRAPHQL_MUTATION_ROOT",
        "graphql_ExpansionEntry", "graphql_ExecutionPlan",
        "graphql_same_selection_list", "graphql_expansion_index",
        "graphql_PreparedQuery", "graphql_ParsedQuery",
        "graphql_parse_query", "graphql_prepare",
        "graphql_execute", "graphql_execute_prepared",
        "graphql_execute_cached", "graphql_execute_document",
        "graphql_schema_has_object_type"
    ];
    for i in 0..len(reserved_globals) {
        seen[reserved_globals[i]] = true;
    }

    for i in 0..len(schema.enums) {
        let ed = schema.enums[i];
        if strings.has_prefix(ed.name, "graphql_") || strings.has_prefix(ed.name, "resolve_") {
            return err("graphql codegen: reserved prefix on enum " + ed.name);
        }
        let rr = register_generated_symbol(seen, ed.name);
        guard let _ok = rr else let e = err_of(rr) { return err(e); }
    }

    for i in 0..len(schema.inputs) {
        let inp = schema.inputs[i];
        if strings.has_prefix(inp.name, "graphql_") || strings.has_prefix(inp.name, "resolve_") {
            return err("graphql codegen: reserved prefix on input " + inp.name);
        }
        let rr = register_generated_symbol(seen, inp.name);
        guard let _ok = rr else let e = err_of(rr) { return err(e); }
        let nr = register_generated_symbol(seen, "graphql_normalize_input_" + inp.name);
        guard let _nok = nr else let e = err_of(nr) { return err(e); }
        for j in 0..len(inp.fields) {
            let inf = inp.fields[j];
            let fr = register_type_ref_normalizers(seen, "graphql_normalize_input_" + inp.name + "_" + inf.name, inf.typ);
            guard let _fok = fr else let e = err_of(fr) { return err(e); }
        }
    }

    for i in 0..len(schema.types) {
        let td = schema.types[i];
        if strings.has_prefix(td.name, "graphql_") || strings.has_prefix(td.name, "resolve_") {
            return err("graphql codegen: reserved prefix on type " + td.name);
        }
        let rr = register_generated_symbol(seen, td.name);
        guard let _ok = rr else let e = err_of(rr) { return err(e); }
        let vr = register_generated_symbol(seen, "graphql_validate_" + td.name);
        guard let _vok = vr else let e = err_of(vr) { return err(e); }
        let er = register_generated_symbol(seen, "graphql_emit_" + td.name);
        guard let _eok = er else let e = err_of(er) { return err(e); }

        for j in 0..len(td.fields) {
            let f = td.fields[j];
            let call_r = register_generated_symbol(seen, "graphql_call_" + td.name + "_" + f.name);
            guard let _cok = call_r else let e = err_of(call_r) { return err(e); }
            let enc_r = register_type_ref_normalizers(seen, "graphql_encode_" + td.name + "_" + f.name, f.typ);
            guard let _encok = enc_r else let e = err_of(enc_r) { return err(e); }
            if len(f.args) > 0 {
                let args_struct = td.name + "_" + f.name + "_Args";
                let ar1 = register_generated_symbol(seen, args_struct);
                guard let _a1 = ar1 else let e = err_of(ar1) { return err(e); }
                let ar2 = register_generated_symbol(seen, "graphql_ArgsEntry_" + td.name + "_" + f.name);
                guard let _a2 = ar2 else let e = err_of(ar2) { return err(e); }
                let ar3 = register_generated_symbol(seen, "graphql_args_index_" + td.name + "_" + f.name);
                guard let _a3 = ar3 else let e = err_of(ar3) { return err(e); }
                let ar4 = register_generated_symbol(seen, "graphql_resolver_args_" + td.name + "_" + f.name);
                guard let _a4 = ar4 else let e = err_of(ar4) { return err(e); }
                for k in 0..len(f.args) {
                    let arg = f.args[k];
                    let ar5 = register_generated_symbol(seen, "graphql_resolver_arg_" + td.name + "_" + f.name + "_" + arg.name);
                    guard let _a5 = ar5 else let e = err_of(ar5) { return err(e); }
                    let ar6 = register_type_ref_normalizers(seen, "graphql_normalize_arg_" + td.name + "_" + f.name + "_" + arg.name, arg.typ);
                    guard let _a6 = ar6 else let e = err_of(ar6) { return err(e); }
                }
            }
        }
    }
    return ok(true);
}

fn generate(schema: Schema, context_type: str) -> result[str, str] {
    let ctx = context_type;
    if len(ctx) == 0 {
        ctx = "graphql.Context";
    }
    let check_res = validate_generated_names(schema, ctx);
    guard let _ok = check_res else let e = err_of(check_res) { return err(e); }

    let out = builder.new_str();
    out.write_line("// Code generated by graphqlc. DO NOT EDIT.");
    out.write_line("// Edit the SDL and regenerate; resolvers remain ordinary named functions.");
    out.write_line("");
    out.write_line("import \"graphql\" as __graphql;");
    out.write_line("import \"builder\";");
    out.write_line("import \"json\";");
    out.write_line("");
    out.write_line("pub let GRAPHQL_QUERY_ROOT = " + json.encode(schema.query_type) + ";");
    if schema.has_mutation {
        out.write_line("pub let GRAPHQL_MUTATION_ROOT = " + json.encode(schema.mutation_type) + ";");
    }
    out.write_line("");

    for i in 0..len(schema.enums) {
        let ed = schema.enums[i];
        out.write_line("pub enum " + ed.name + " {");
        for j in 0..len(ed.values) {
            out.write_line("    " + ed.values[j] + ",");
        }
        out.write_line("}");
        out.write_line("");
    }

    for i in 0..len(schema.struct_order) {
        let name = schema.struct_order[i];
        out.write_line("pub gc struct " + name + " {");
        if has(schema.type_map, name) {
            let td = schema.type_map[name];
            for j in 0..len(td.fields) {
                let f = td.fields[j];
                out.write_line("    " + f.name + ": " + slang_type(f.typ) + ",");
            }
        } else if has(schema.input_map, name) {
            let inp = schema.input_map[name];
            for j in 0..len(inp.fields) {
                let inf = inp.fields[j];
                out.write_line("    " + inf.name + ": " + slang_type(inf.typ) + ",");
            }
        }
        out.write_line("}");
        out.write_line("");
    }

    for i in 0..len(schema.types) {
        let td = schema.types[i];
        for j in 0..len(td.fields) {
            let f = td.fields[j];
            if len(f.args) == 0 {
                continue;
            }
            out.write_line("pub gc struct " + td.name + "_" + f.name + "_Args {");
            for k in 0..len(f.args) {
                let a = f.args[k];
                out.write_line("    " + a.name + ": " + slang_type(a.typ) + ",");
            }
            out.write_line("}");
            out.write_line("");
        }
    }

    out.write_line("// Implement one named resolver for each schema field.");
    out.write_line("// Generated wrappers call them directly; no resolver registry is used.");
    for i in 0..len(schema.types) {
        let td = schema.types[i];
        let ptype = parent_slang_type(schema, td.name);
        for j in 0..len(td.fields) {
            let f = td.fields[j];
            let args_type = "__graphql.NoArgs";
            if len(f.args) > 0 {
                args_type = td.name + "_" + f.name + "_Args";
            }
            out.write_line(
                "pub fn graphql_call_" + td.name + "_" + f.name +
                "(parent: " + ptype + ", args: " + args_type +
                ", ctx: " + ctx + ") -> result[" + slang_type(f.typ) + ", str] {"
            );
            out.write_line("    return resolve_" + td.name + "_" + f.name + "(parent, args, ctx);");
            out.write_line("}");
            out.write_line("");
        }
    }

    generate_execution(out, schema, ctx);
    let rendered = out.finish();
    if strings.has_suffix(rendered, "\n\n") {
        rendered = strings.slice(rendered, 0, len(rendered) - 1);
    }
    return ok(rendered);
}
