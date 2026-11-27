import "fs";
import "os";
import "strings";
import "time";

fn must_parse(sdl: str) -> Schema {
    let sr = parse_sdl(sdl);
    guard let s = sr else let e = err_of(sr) {
        panic("expected parse_sdl to succeed, got: " + e);
    }
    return s;
}

fn must_fail_parse(sdl: str, substr: str) {
    let sr = parse_sdl(sdl);
    if let _s = sr {
        panic("expected parse_sdl error containing '" + substr + "', but succeeded");
    } else let e = err_of(sr) {
        if len(substr) > 0 && !strings.contains(e, substr) {
            panic("expected parse error containing '" + substr + "', got: " + e);
        }
    }
}

fn must_fail_generate(sdl: str, ctx: str, substr: str) {
    let s = must_parse(sdl);
    let gr = generate(s, ctx);
    if let _g = gr {
        panic("expected generate error containing '" + substr + "', but succeeded");
    } else let e = err_of(gr) {
        if len(substr) > 0 && !strings.contains(e, substr) {
            panic("expected generate error containing '" + substr + "', got: " + e);
        }
    }
}

fn make_test_tmp(tag: str) -> str {
    let d = os.tmpdir() + "/graphqlc_" + tag + "_" + to_str(os.pid()) + "_" + to_str(time.mono());
    let mr = fs.mkdir(d);
    guard let _ok = mr else let e = err_of(mr) { panic("mkdir: " + e); }
    return d;
}

fn write_test_file(path: str, content: str) {
    let fdr = fs.create(path);
    guard let fd = fdr else let e = err_of(fdr) { panic("create: " + e); }
    let _w = fs.write(fd, to_bytes(content));
    let _c = fs.close(fd);
}

fn test_parse_valid_schema_and_types() {
    let sdl =
        "# leading comment\n" +
        "\"root schema\"\n" +
        "enum Status { ACTIVE, DISABLED }\n" +
        "input PageInput {\n" +
        "    limit: Int = 20\n" +
        "    ratio: Float = 1.5e2\n" +
        "    enabled: Boolean = false\n" +
        "    status: Status = ACTIVE\n" +
        "    tags: [String!]! = \"default-tag\"\n" +
        "    id: ID = 7\n" +
        "}\n" +
        "type Item {\n" +
        "    id: ID!\n" +
        "    score: Float!\n" +
        "    active: Boolean!\n" +
        "}\n" +
        "type Query {\n" +
        "    items(page: PageInput = { limit: 10, tags: [\"a\", \"b\"], id: \"x\" }, note: String = \"hi\\n\\uD83D\\uDE00\"): [Item]!\n" +
        "}\n" +
        "type Mutation {\n" +
        "    ping: Boolean!\n" +
        "}\n";
    let s = must_parse(sdl);
    assert(s.query_type == "Query", "query_type");
    assert(s.has_mutation && s.mutation_type == "Mutation", "mutation_type");
    assert(len(s.enums) == 1 && len(s.inputs) == 1 && len(s.types) == 3, "counts");

    let gr = generate(s, "graphql.Context");
    guard let code = gr else let e = err_of(gr) { panic("generate failed: " + e); }
    assert(strings.contains(code, "pub enum Status"), "enum generated");
    assert(strings.contains(code, "score: float"), "float mapped");
    assert(strings.contains(code, "active: bool"), "bool mapped");
    assert(strings.contains(code, "graphql_validate_Mutation"), "mutation validator generated");
    assert(strings.contains(code, "graphql Float result is not finite"), "float check generated");
}

fn test_explicit_schema_custom_roots() {
    let sdl =
        "schema { query: RootQuery, mutation: RootMutation }\n" +
        "type RootQuery { ping: String! }\n" +
        "type RootMutation { touch: Int! }\n";
    let s = must_parse(sdl);
    assert(s.query_type == "RootQuery", "custom query root");
    assert(s.has_mutation && s.mutation_type == "RootMutation", "custom mutation root");
    let gr = generate(s, "app.ReqCtx");
    guard let code = gr else let e = err_of(gr) { panic("generate failed: " + e); }
    assert(strings.contains(code, "pub let GRAPHQL_QUERY_ROOT = \"RootQuery\";"), "query root const");
    assert(strings.contains(code, "pub let GRAPHQL_MUTATION_ROOT = \"RootMutation\";"), "mutation root const");
    assert(strings.contains(code, "ctx: app.ReqCtx"), "custom context param");
    assert(strings.contains(code, "pub gc struct RootQuery"), "root query struct emitted");
    assert(strings.contains(code, "pub gc struct RootMutation"), "root mutation struct emitted");
}

fn test_schema_without_mutation() {
    let sdl = "type Query { hello: String! }";
    let s = must_parse(sdl);
    assert(!s.has_mutation, "no mutation");
    let gr = generate(s, "");
    guard let code = gr else let e = err_of(gr) { panic("generate failed: " + e); }
    assert(!strings.contains(code, "GRAPHQL_MUTATION_ROOT"), "no mutation const");
    assert(!strings.contains(code, "OP_MUTATION"), "no mutation branch emitted");
    assert(strings.contains(code, "ctx: graphql.Context"), "empty context defaults");
}

fn test_reject_unsupported_sdl_constructs() {
    must_fail_parse("scalar DateTime\ntype Query { flag: Boolean }", "scalar");
    must_fail_parse("interface Node { id: ID! }\ntype Query { flag: Boolean }", "interface");
    must_fail_parse("union Search = User | Item\ntype User { id: ID! }\ntype Item { id: ID! }\ntype Query { flag: Boolean }", "union");
    must_fail_parse("directive @auth on FIELD_DEFINITION\ntype Query { flag: Boolean }", "directive");
    must_fail_parse("extend type Query { extra: String }", "extend");
    must_fail_parse("type User implements Node { id: ID }\ntype Query { flag: Boolean }", "implements");
    must_fail_parse("type Query { flag: Boolean @skip }", "directives");
    must_fail_parse("schema { query: Query, subscription: Sub }\ntype Query { flag: Boolean }\ntype Sub { flag: Boolean }", "unsupported root operation");
    must_fail_parse("type Query { \"\"\"block\"\"\" flag: Boolean }", "block strings");
}

fn test_reject_invalid_roots_and_duplicates() {
    must_fail_parse("type Other { x: Int }", "query root type Query");
    must_fail_parse("schema { query: Query, mutation: Query }\ntype Query { x: Int }", "must differ");
    must_fail_parse("type Query { a: Int }\ntype Query { b: Int }", "duplicate type");
    must_fail_parse("type Query { a: Int, a: String }", "duplicate field");
    must_fail_parse("type Query { a(x: Int, x: Int): Int }", "duplicate argument");
    must_fail_parse("enum E { A, A }\ntype Query { a: E }", "duplicate enum value");
    must_fail_parse("type Query { __hidden: String }", "introspection");
    must_fail_parse("type __Bad { x: String }\ntype Query { a: String }", "introspection");
    must_fail_parse("type Query { fn: String }", "reserved slang identifier");
    must_fail_parse("type struct { x: String }\ntype Query { x: String }", "reserved slang identifier");
}

fn test_reject_invalid_type_categories_and_defaults() {
    must_fail_parse("input In { a: Int }\ntype Query { x: In }", "cannot be used in return type");
    must_fail_parse("type User { id: ID! }\ntype Query { x(u: User): String }", "cannot be used in argument");
    must_fail_parse("type User { id: ID! }\ninput Bad { u: User }\ntype Query { x: String }", "cannot be used in input field");
    must_fail_parse("type Query { x: Missing }", "unknown type Missing");
    must_fail_parse("type Query { x(a: Int! = null): Int }", "null default");
    must_fail_parse("type Query { x(a: Int = 2147483648): Int }", "signed 32-bit");
    must_fail_parse("type Query { x(a: Int = 1.5): Int }", "expected Int");
    must_fail_parse("type Query { x(a: Float = \"no\"): Int }", "expected Float");
    must_fail_parse("type Query { x(a: Boolean = 1): Int }", "expected Boolean");
    must_fail_parse("enum E { A }\ntype Query { x(a: E = B): Int }", "unknown enum value B");
    must_fail_parse("input I { a: Int! }\ntype Query { x(i: I = {}): Int }", "missing required field I.a");
    must_fail_parse("input I { a: Int! }\ntype Query { x(i: I = { a: 1, b: 2 }): Int }", "unknown input field I.b");
}

fn test_reject_lex_errors_and_limits() {
    must_fail_parse("type Query { x(a: Int = 01): Int }", "leading zeroes");
    must_fail_parse("type Query { x(a: Float = 1.): Int }", "invalid fractional");
    must_fail_parse("type Query { x(a: Float = 1e): Int }", "invalid exponent");
    must_fail_parse("type Query { x(a: String = \"\\uD800\"): Int }", "unpaired high surrogate");
    must_fail_parse("type Query { x(a: String = \"\\uDC00\"): Int }", "unpaired low surrogate");
    must_fail_parse("type Query { x(a: String = \"unterminated): Int }", "unterminated string");
    must_fail_parse(strings.repeat(" ", 1048577), "1 MiB");
}

fn test_reject_codegen_collisions() {
    must_fail_generate("type Query { a: String }", "1bad.Ctx", "invalid context type");
    must_fail_generate("type Query { a: String }", "bad.", "invalid context type");
    must_fail_generate("type graphql_Custom { x: Int }\ntype Query { a: String }", "graphql.Context", "reserved prefix");
    must_fail_generate(
        "type User_id_Args { x: Int }\ntype User { id(y: Int): ID! }\ntype Query { u: User }",
        "graphql.Context",
        "symbol collision"
    );
}

fn test_cli_write_and_check_roundtrip() {
    let dir = make_test_tmp("cli");
    let schema_file = dir + "/schema.graphql";
    let out_file = dir + "/schema.gen.sl";
    write_test_file(schema_file, "type Query { ping(who: String = \"world\"): String! }");

    let wres = run_cli(["-schema", schema_file, "-out", out_file]);
    guard let _wok = wres else let e = err_of(wres) { panic("run_cli write failed: " + e); }
    assert(os.exists(out_file), "output file exists");

    let cres = run_cli(["-schema", schema_file, "-out", out_file, "-check"]);
    guard let _cok = cres else let e = err_of(cres) { panic("run_cli check failed: " + e); }

    write_test_file(out_file, "// stale");
    let stale_res = run_cli(["-schema", schema_file, "-out", out_file, "-check"]);
    if let _ok = stale_res {
        panic("expected -check to fail on stale output");
    } else let e = err_of(stale_res) {
        assert(strings.contains(e, "out of date"), "stale check message: " + e);
    }

    let missing_flags = run_cli(["-schema", schema_file]);
    if let _ok = missing_flags {
        panic("expected missing -out error");
    }

    let bad_flag = run_cli(["-nope"]);
    if let _ok = bad_flag {
        panic("expected unknown flag error");
    }

    let _r1 = os.remove(out_file);
    let _r2 = os.remove(schema_file);
    let _r3 = os.remove(dir);
}
