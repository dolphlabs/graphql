import "builder";
import "strings";
import "unicode";

fn max_sdl_bytes() -> int {
    return 1048576;
}

fn max_tokens() -> int {
    return 100000;
}

enum TokenKind {
    EOF,
    NAME,
    INT,
    FLOAT,
    STRING,
    SPREAD,
    PUNCT
}

enum ValueKind {
    NULL,
    BOOL,
    INT,
    FLOAT,
    STRING,
    ENUM,
    LIST,
    OBJECT
}

struct Token {
    kind: TokenKind,
    val: str,
    pos: int
}

gc struct TypeRef {
    name: str,
    is_list: bool,
    inner: opt[TypeRef],
    non_null: bool
}

gc struct ValueField {
    name: str,
    value: Value
}

gc struct Value {
    kind: ValueKind,
    text: str,
    bool_val: bool,
    int_val: int,
    float_val: float,
    items: [Value],
    fields: [ValueField]
}

gc struct InputValueDef {
    name: str,
    typ: TypeRef,
    has_default: bool,
    default_val: Value
}

gc struct FieldDef {
    name: str,
    args: [InputValueDef],
    typ: TypeRef
}

gc struct TypeDef {
    name: str,
    fields: [FieldDef]
}

gc struct InputDef {
    name: str,
    fields: [InputValueDef]
}

gc struct EnumDef {
    name: str,
    values: [str]
}

gc struct Schema {
    query_type: str,
    mutation_type: str,
    has_mutation: bool,
    explicit_schema: bool,
    struct_order: [str],
    enums: [EnumDef],
    enum_map: map[str]EnumDef,
    types: [TypeDef],
    type_map: map[str]TypeDef,
    inputs: [InputDef],
    input_map: map[str]InputDef
}

gc struct SDLParser {
    tokens: [Token],
    pos: int
}

fn is_ascii_alpha(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

fn is_ascii_digit(c: int) -> bool {
    return c >= 48 && c <= 57;
}

fn is_name_start(c: int) -> bool {
    return is_ascii_alpha(c) || c == 95;
}

fn is_name_continue(c: int) -> bool {
    return is_name_start(c) || is_ascii_digit(c);
}

fn hex_val(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 65 && c <= 70 { return 10 + (c - 65); }
    if c >= 97 && c <= 102 { return 10 + (c - 97); }
    return -1;
}

fn parse_hex4(b: bytes, start: int) -> result[int, str] {
    if start + 4 > len(b) {
        return err("graphql SDL: incomplete unicode escape");
    }
    let total = 0;
    for k in 0..4 {
        let d = hex_val(b[start + k]);
        if d < 0 {
            return err("graphql SDL: invalid unicode escape");
        }
        total = total * 16 + d;
    }
    return ok(total);
}

fn is_punct_byte(c: int) -> bool {
    // ! $ & ( ) : = @ [ ] { | }
    return c == 33 || c == 36 || c == 38 || c == 40 || c == 41 ||
           c == 58 || c == 61 || c == 64 || c == 91 || c == 93 ||
           c == 123 || c == 124 || c == 125;
}

struct LexStringRes {
    val: str,
    next_pos: int
}

fn scan_string(b: bytes, start: int) -> result[LexStringRes, str] {
    let n = len(b);
    if start + 2 < n && b[start + 1] == 34 && b[start + 2] == 34 {
        return err("graphql SDL: block strings are not supported");
    }
    let out = builder.new_bytes();
    let i = start + 1;
    while i < n {
        let c = b[i];
        if c == 34 {
            let raw = out.finish();
            return ok(LexStringRes {
                val: strings.from_bytes(raw, 0, len(raw)),
                next_pos: i + 1
            });
        }
        if c == 10 || c == 13 || c < 32 {
            return err("graphql SDL: invalid character in string literal");
        }
        if c == 92 {
            i = i + 1;
            if i >= n {
                return err("graphql SDL: unterminated string escape");
            }
            let esc = b[i];
            if esc == 34 { out.write_byte(34); i = i + 1; continue; }
            if esc == 92 { out.write_byte(92); i = i + 1; continue; }
            if esc == 47 { out.write_byte(47); i = i + 1; continue; }
            if esc == 98 { out.write_byte(8); i = i + 1; continue; }
            if esc == 102 { out.write_byte(12); i = i + 1; continue; }
            if esc == 110 { out.write_byte(10); i = i + 1; continue; }
            if esc == 114 { out.write_byte(13); i = i + 1; continue; }
            if esc == 116 { out.write_byte(9); i = i + 1; continue; }
            if esc == 117 {
                let u1_res = parse_hex4(b, i + 1);
                guard let u1 = u1_res else let e = err_of(u1_res) { return err(e); }
                i = i + 5;
                if u1 >= 55296 && u1 <= 56319 {
                    if i + 1 >= n || b[i] != 92 || b[i + 1] != 117 {
                        return err("graphql SDL: unpaired high surrogate in string");
                    }
                    let u2_res = parse_hex4(b, i + 2);
                    guard let u2 = u2_res else let e = err_of(u2_res) { return err(e); }
                    if u2 < 56320 || u2 > 57343 {
                        return err("graphql SDL: invalid low surrogate in string");
                    }
                    i = i + 6;
                    let cp = 65536 + (u1 - 55296) * 1024 + (u2 - 56320);
                    guard let enc = unicode.encode(cp) else {
                        return err("graphql SDL: invalid unicode code point");
                    }
                    out.write_str(enc);
                    continue;
                }
                if u1 >= 56320 && u1 <= 57343 {
                    return err("graphql SDL: unpaired low surrogate in string");
                }
                guard let enc = unicode.encode(u1) else {
                    return err("graphql SDL: invalid unicode code point");
                }
                out.write_str(enc);
                continue;
            }
            return err("graphql SDL: invalid string escape sequence");
        }
        out.write_byte(c);
        i = i + 1;
    }
    return err("graphql SDL: unterminated string literal");
}

struct LexNumRes {
    tok: Token,
    next_pos: int
}

fn scan_number(b: bytes, start: int) -> result[LexNumRes, str] {
    let n = len(b);
    let i = start;
    let is_float = false;
    if b[i] == 45 {
        i = i + 1;
    }
    if i >= n || !is_ascii_digit(b[i]) {
        return err("graphql SDL: invalid number literal");
    }
    if b[i] == 48 {
        i = i + 1;
        if i < n && is_ascii_digit(b[i]) {
            return err("graphql SDL: leading zeroes are not allowed in numbers");
        }
    } else {
        while i < n && is_ascii_digit(b[i]) {
            i = i + 1;
        }
    }
    if i < n && b[i] == 46 {
        is_float = true;
        i = i + 1;
        if i >= n || !is_ascii_digit(b[i]) {
            return err("graphql SDL: invalid fractional number literal");
        }
        while i < n && is_ascii_digit(b[i]) {
            i = i + 1;
        }
    }
    if i < n && (b[i] == 101 || b[i] == 69) {
        is_float = true;
        i = i + 1;
        if i < n && (b[i] == 43 || b[i] == 45) {
            i = i + 1;
        }
        if i >= n || !is_ascii_digit(b[i]) {
            return err("graphql SDL: invalid exponent in number literal");
        }
        while i < n && is_ascii_digit(b[i]) {
            i = i + 1;
        }
    }
    if i < n && (is_name_start(b[i]) || is_ascii_digit(b[i]) || b[i] == 46) {
        return err("graphql SDL: invalid character after number literal");
    }
    let kind = TokenKind.INT;
    if is_float { kind = TokenKind.FLOAT; }
    return ok(LexNumRes {
        tok: Token { kind: kind, val: strings.from_bytes(b, start, i), pos: start },
        next_pos: i
    });
}

fn lex_sdl(src: str) -> result[[Token], str] {
    let b = to_bytes(src);
    let n = len(b);
    let tokens: [Token] = [];
    let i = 0;
    let tok_limit = max_tokens();
    while i < n {
        let c = b[i];
        // space, \t, \r, \n, comma
        if c == 32 || c == 9 || c == 13 || c == 10 || c == 44 {
            i = i + 1;
            continue;
        }
        // # comment
        if c == 35 {
            while i < n && b[i] != 10 && b[i] != 13 {
                i = i + 1;
            }
            continue;
        }
        if len(tokens) >= tok_limit {
            return err("graphql SDL: exceeds token limit");
        }
        if c == 34 {
            let sres = scan_string(b, i);
            guard let sr = sres else let e = err_of(sres) { return err(e); }
            push(tokens, Token { kind: TokenKind.STRING, val: sr.val, pos: i });
            i = sr.next_pos;
            continue;
        }
        if c == 45 || is_ascii_digit(c) {
            let nres = scan_number(b, i);
            guard let nr = nres else let e = err_of(nres) { return err(e); }
            push(tokens, nr.tok);
            i = nr.next_pos;
            continue;
        }
        if c == 46 {
            if i + 2 < n && b[i + 1] == 46 && b[i + 2] == 46 {
                push(tokens, Token { kind: TokenKind.SPREAD, val: "...", pos: i });
                i = i + 3;
                continue;
            }
            return err("graphql SDL: unexpected '.'");
        }
        if is_punct_byte(c) {
            push(tokens, Token { kind: TokenKind.PUNCT, val: strings.from_bytes(b, i, i + 1), pos: i });
            i = i + 1;
            continue;
        }
        if is_name_start(c) {
            let start = i;
            i = i + 1;
            while i < n && is_name_continue(b[i]) {
                i = i + 1;
            }
            push(tokens, Token { kind: TokenKind.NAME, val: strings.from_bytes(b, start, i), pos: start });
            continue;
        }
        return err("graphql SDL: unexpected character at byte " + to_str(i));
    }
    push(tokens, Token { kind: TokenKind.EOF, val: "", pos: n });
    return ok(tokens);
}

fn is_reserved_name(name: str) -> bool {
    if name == "as" || name == "assert" || name == "bool" || name == "break" ||
       name == "bytes" || name == "case" || name == "chan" || name == "continue" ||
       name == "default" || name == "defer" || name == "else" || name == "enum" ||
       name == "err" || name == "err_of" || name == "exit" || name == "f32" ||
       name == "f64" || name == "false" || name == "float" || name == "fn" ||
       name == "for" || name == "gc" || name == "guard" || name == "has" ||
       name == "i8" || name == "i16" || name == "i32" || name == "i64" ||
       name == "if" || name == "import" || name == "in" || name == "int" ||
       name == "isize" || name == "len" || name == "let" || name == "map" ||
       name == "match" || name == "mut" || name == "nil" || name == "none" ||
       name == "null" || name == "ok" || name == "opt" || name == "panic" ||
       name == "print" || name == "println" || name == "pub" || name == "push" ||
       name == "range" || name == "rawptr" || name == "result" || name == "return" ||
       name == "select" || name == "self" || name == "some" || name == "spawn" ||
       name == "str" || name == "struct" || name == "super" || name == "to_bytes" ||
       name == "to_float" || name == "to_int" || name == "to_str" || name == "true" ||
       name == "type" || name == "u8" || name == "u16" || name == "u32" ||
       name == "u64" || name == "until" || name == "usize" || name == "val_of" ||
       name == "void" || name == "while" || name == "wire" {
        return true;
    }
    return false;
}

fn valid_slang_identifier(name: str) -> bool {
    let b = to_bytes(name);
    if len(b) == 0 { return false; }
    if !is_name_start(b[0]) { return false; }
    for i in 1..len(b) {
        if !is_name_continue(b[i]) { return false; }
    }
    return !is_reserved_name(name);
}

fn check_graphql_name(name: str, what: str) -> result[bool, str] {
    if strings.has_prefix(name, "__") {
        return err("graphql SDL: introspection name " + name + " is not allowed on " + what);
    }
    if !valid_slang_identifier(name) {
        return err("graphql SDL: invalid or reserved slang identifier '" + name + "' on " + what);
    }
    return ok(true);
}

fn p_peek(p: SDLParser) -> Token {
    return p.tokens[p.pos];
}

fn p_advance(p: SDLParser) {
    if p.pos + 1 < len(p.tokens) {
        p.pos = p.pos + 1;
    }
}

fn p_is_punct(p: SDLParser, ch: str) -> bool {
    let t = p_peek(p);
    return t.kind == TokenKind.PUNCT && t.val == ch;
}

fn p_is_name(p: SDLParser, kw: str) -> bool {
    let t = p_peek(p);
    return t.kind == TokenKind.NAME && t.val == kw;
}

fn p_expect_punct(p: SDLParser, ch: str) -> result[bool, str] {
    let t = p_peek(p);
    if t.kind != TokenKind.PUNCT || t.val != ch {
        return err("graphql SDL: expected '" + ch + "', got '" + t.val + "'");
    }
    p_advance(p);
    return ok(true);
}

fn p_expect_name(p: SDLParser) -> result[str, str] {
    let t = p_peek(p);
    if t.kind != TokenKind.NAME {
        return err("graphql SDL: expected identifier, got '" + t.val + "'");
    }
    p_advance(p);
    return ok(t.val);
}

fn p_reject_directives(p: SDLParser) -> result[bool, str] {
    if p_is_punct(p, "@") {
        return err("graphql SDL: directives are not supported");
    }
    return ok(true);
}

fn p_skip_description(p: SDLParser) {
    if p_peek(p).kind == TokenKind.STRING {
        p_advance(p);
    }
}

fn parse_type_ref(p: SDLParser) -> result[TypeRef, str] {
    let cur = TypeRef { name: "", is_list: false, inner: none, non_null: false };
    if p_is_punct(p, "[") {
        p_advance(p);
        let inner_res = parse_type_ref(p);
        guard let inner = inner_res else let e = err_of(inner_res) { return err(e); }
        let close_res = p_expect_punct(p, "]");
        guard let _c = close_res else let e = err_of(close_res) { return err(e); }
        cur.is_list = true;
        cur.inner = some(inner);
    } else {
        let name_res = p_expect_name(p);
        guard let name = name_res else let e = err_of(name_res) { return err(e); }
        cur.name = name;
    }
    if p_is_punct(p, "!") {
        p_advance(p);
        cur.non_null = true;
    }
    return ok(cur);
}

fn base_type_name(t: TypeRef) -> str {
    let cur = t;
    while cur.is_list {
        guard let inner = cur.inner else { return ""; }
        cur = inner;
    }
    return cur.name;
}

fn graphql_type_str(t: TypeRef) -> str {
    let base = t.name;
    if t.is_list {
        guard let inner = t.inner else { return "[]"; }
        base = "[" + graphql_type_str(inner) + "]";
    }
    if t.non_null { return base + "!"; }
    return base;
}

fn slang_type(t: TypeRef) -> str {
    let base = "";
    if t.is_list {
        guard let inner = t.inner else { return "[]"; }
        base = "[" + slang_type(inner) + "]";
    } else if t.name == "ID" || t.name == "String" {
        base = "str";
    } else if t.name == "Int" {
        base = "int";
    } else if t.name == "Float" {
        base = "float";
    } else if t.name == "Boolean" {
        base = "bool";
    } else {
        base = t.name;
    }
    if !t.non_null { return "opt[" + base + "]"; }
    return base;
}

fn is_builtin_scalar(name: str) -> bool {
    return name == "ID" || name == "String" || name == "Int" ||
           name == "Float" || name == "Boolean";
}

fn parse_value(p: SDLParser, depth: int) -> result[Value, str] {
    if depth > 64 {
        return err("graphql SDL: default value nesting exceeds limit");
    }
    let t = p_peek(p);
    if t.kind == TokenKind.INT {
        p_advance(p);
        let ir = to_int(t.val);
        guard let iv = ir else {
            return err("graphql SDL: invalid Int literal " + t.val);
        }
        if iv < -2147483648 || iv > 2147483647 {
            return err("graphql SDL: Int literal outside signed 32-bit range: " + t.val);
        }
        return ok(Value { kind: ValueKind.INT, text: t.val, bool_val: false, int_val: iv, float_val: 0.0, items: [], fields: [] });
    }
    if t.kind == TokenKind.FLOAT {
        p_advance(p);
        let fr = to_float(t.val);
        guard let fv = fr else {
            return err("graphql SDL: invalid Float literal " + t.val);
        }
        return ok(Value { kind: ValueKind.FLOAT, text: t.val, bool_val: false, int_val: 0, float_val: fv, items: [], fields: [] });
    }
    if t.kind == TokenKind.STRING {
        p_advance(p);
        return ok(Value { kind: ValueKind.STRING, text: t.val, bool_val: false, int_val: 0, float_val: 0.0, items: [], fields: [] });
    }
    if t.kind == TokenKind.NAME {
        p_advance(p);
        if t.val == "true" {
            return ok(Value { kind: ValueKind.BOOL, text: "true", bool_val: true, int_val: 0, float_val: 0.0, items: [], fields: [] });
        }
        if t.val == "false" {
            return ok(Value { kind: ValueKind.BOOL, text: "false", bool_val: false, int_val: 0, float_val: 0.0, items: [], fields: [] });
        }
        if t.val == "null" {
            return ok(Value { kind: ValueKind.NULL, text: "null", bool_val: false, int_val: 0, float_val: 0.0, items: [], fields: [] });
        }
        return ok(Value { kind: ValueKind.ENUM, text: t.val, bool_val: false, int_val: 0, float_val: 0.0, items: [], fields: [] });
    }
    if p_is_punct(p, "[") {
        p_advance(p);
        let items: [Value] = [];
        while !p_is_punct(p, "]") {
            if p_peek(p).kind == TokenKind.EOF {
                return err("graphql SDL: unterminated list value");
            }
            let ir = parse_value(p, depth + 1);
            guard let iv = ir else let e = err_of(ir) { return err(e); }
            push(items, iv);
        }
        p_advance(p);
        return ok(Value { kind: ValueKind.LIST, text: "", bool_val: false, int_val: 0, float_val: 0.0, items: items, fields: [] });
    }
    if p_is_punct(p, "{") {
        p_advance(p);
        let fields: [ValueField] = [];
        let seen: map[str]bool = {};
        while !p_is_punct(p, "}") {
            if p_peek(p).kind == TokenKind.EOF {
                return err("graphql SDL: unterminated object value");
            }
            let nr = p_expect_name(p);
            guard let fname = nr else let e = err_of(nr) { return err(e); }
            if has(seen, fname) {
                return err("graphql SDL: duplicate field " + fname + " in object literal");
            }
            seen[fname] = true;
            let cr = p_expect_punct(p, ":");
            guard let _co = cr else let e = err_of(cr) { return err(e); }
            let vr = parse_value(p, depth + 1);
            guard let vv = vr else let e = err_of(vr) { return err(e); }
            push(fields, ValueField { name: fname, value: vv });
        }
        p_advance(p);
        return ok(Value { kind: ValueKind.OBJECT, text: "", bool_val: false, int_val: 0, float_val: 0.0, items: [], fields: fields });
    }
    return err("graphql SDL: unexpected token '" + t.val + "' in value");
}

fn empty_value() -> Value {
    return Value { kind: ValueKind.NULL, text: "", bool_val: false, int_val: 0, float_val: 0.0, items: [], fields: [] };
}

fn parse_input_value_def(p: SDLParser, what: str) -> result[InputValueDef, str] {
    p_skip_description(p);
    let nr = p_expect_name(p);
    guard let name = nr else let e = err_of(nr) { return err(e); }
    let cr = check_graphql_name(name, what);
    guard let _co = cr else let e = err_of(cr) { return err(e); }
    let colon_res = p_expect_punct(p, ":");
    guard let _cl = colon_res else let e = err_of(colon_res) { return err(e); }
    let tr = parse_type_ref(p);
    guard let typ = tr else let e = err_of(tr) { return err(e); }
    let has_def = false;
    let def_val = empty_value();
    if p_is_punct(p, "=") {
        p_advance(p);
        let vr = parse_value(p, 0);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        has_def = true;
        def_val = v;
    }
    let dir_res = p_reject_directives(p);
    guard let _dr = dir_res else let e = err_of(dir_res) { return err(e); }
    return ok(InputValueDef { name: name, typ: typ, has_default: has_def, default_val: def_val });
}

fn parse_field_def(p: SDLParser, type_name: str) -> result[FieldDef, str] {
    p_skip_description(p);
    let nr = p_expect_name(p);
    guard let name = nr else let e = err_of(nr) { return err(e); }
    let cr = check_graphql_name(name, type_name + " field");
    guard let _co = cr else let e = err_of(cr) { return err(e); }
    let args: [InputValueDef] = [];
    let arg_names: map[str]bool = {};
    if p_is_punct(p, "(") {
        p_advance(p);
        if p_is_punct(p, ")") {
            return err("graphql SDL: empty argument list on " + type_name + "." + name);
        }
        while !p_is_punct(p, ")") {
            if p_peek(p).kind == TokenKind.EOF {
                return err("graphql SDL: unterminated argument list on " + type_name + "." + name);
            }
            let ar = parse_input_value_def(p, type_name + "." + name + " argument");
            guard let arg = ar else let e = err_of(ar) { return err(e); }
            if has(arg_names, arg.name) {
                return err("graphql SDL: duplicate argument " + arg.name + " on " + type_name + "." + name);
            }
            arg_names[arg.name] = true;
            push(args, arg);
        }
        p_advance(p);
    }
    let colon_res = p_expect_punct(p, ":");
    guard let _cl = colon_res else let e = err_of(colon_res) { return err(e); }
    let tr = parse_type_ref(p);
    guard let typ = tr else let e = err_of(tr) { return err(e); }
    let dir_res = p_reject_directives(p);
    guard let _dr = dir_res else let e = err_of(dir_res) { return err(e); }
    return ok(FieldDef { name: name, args: args, typ: typ });
}

fn parse_sdl(src: str) -> result[Schema, str] {
    if len(src) > max_sdl_bytes() {
        return err("graphql SDL: schema exceeds 1 MiB byte limit");
    }
    if !unicode.valid(src) {
        return err("graphql SDL: schema is not valid UTF-8");
    }
    let lex_res = lex_sdl(src);
    guard let tokens = lex_res else let e = err_of(lex_res) { return err(e); }
    let p = SDLParser { tokens: tokens, pos: 0 };
    let schema = Schema {
        query_type: "Query",
        mutation_type: "",
        has_mutation: false,
        explicit_schema: false,
        struct_order: [],
        enums: [],
        enum_map: {},
        types: [],
        type_map: {},
        inputs: [],
        input_map: {}
    };
    let defined_names: map[str]bool = {};

    while p_peek(p).kind != TokenKind.EOF {
        p_skip_description(p);
        if p_peek(p).kind == TokenKind.EOF {
            break;
        }
        let kw_res = p_expect_name(p);
        guard let kw = kw_res else let e = err_of(kw_res) { return err(e); }

        if kw == "schema" {
            if schema.explicit_schema {
                return err("graphql SDL: duplicate schema definition");
            }
            schema.explicit_schema = true;
            let dir_res = p_reject_directives(p);
            guard let _dr = dir_res else let e = err_of(dir_res) { return err(e); }
            let open_res = p_expect_punct(p, "{");
            guard let _o = open_res else let e = err_of(open_res) { return err(e); }
            let seen_query = false;
            let seen_mutation = false;
            while !p_is_punct(p, "}") {
                if p_peek(p).kind == TokenKind.EOF {
                    return err("graphql SDL: unterminated schema definition");
                }
                let op_res = p_expect_name(p);
                guard let op = op_res else let e = err_of(op_res) { return err(e); }
                let cl_res = p_expect_punct(p, ":");
                guard let _c = cl_res else let e = err_of(cl_res) { return err(e); }
                let tn_res = p_expect_name(p);
                guard let tn = tn_res else let e = err_of(tn_res) { return err(e); }
                if op == "query" {
                    if seen_query { return err("graphql SDL: duplicate query root operation"); }
                    seen_query = true;
                    schema.query_type = tn;
                } else if op == "mutation" {
                    if seen_mutation { return err("graphql SDL: duplicate mutation root operation"); }
                    seen_mutation = true;
                    schema.mutation_type = tn;
                    schema.has_mutation = true;
                } else {
                    return err("graphql SDL: unsupported root operation " + op);
                }
            }
            p_advance(p);
            if !seen_query {
                return err("graphql SDL: schema definition must specify query root type");
            }
            continue;
        }

        if kw == "type" {
            let tn_res = p_expect_name(p);
            guard let tname = tn_res else let e = err_of(tn_res) { return err(e); }
            let chk = check_graphql_name(tname, "object type");
            guard let _ck = chk else let e = err_of(chk) { return err(e); }
            if has(defined_names, tname) {
                return err("graphql SDL: duplicate type definition " + tname);
            }
            defined_names[tname] = true;
            if p_is_name(p, "implements") {
                return err("graphql SDL: interfaces and implements are not supported");
            }
            let dir_res = p_reject_directives(p);
            guard let _dr = dir_res else let e = err_of(dir_res) { return err(e); }
            let open_res = p_expect_punct(p, "{");
            guard let _o = open_res else let e = err_of(open_res) { return err(e); }
            let fields: [FieldDef] = [];
            let field_names: map[str]bool = {};
            while !p_is_punct(p, "}") {
                if p_peek(p).kind == TokenKind.EOF {
                    return err("graphql SDL: unterminated type " + tname);
                }
                let fr = parse_field_def(p, tname);
                guard let fld = fr else let e = err_of(fr) { return err(e); }
                if has(field_names, fld.name) {
                    return err("graphql SDL: duplicate field " + fld.name + " on type " + tname);
                }
                field_names[fld.name] = true;
                push(fields, fld);
            }
            p_advance(p);
            if len(fields) == 0 {
                return err("graphql SDL: type " + tname + " must define at least one field");
            }
            let td = TypeDef { name: tname, fields: fields };
            push(schema.types, td);
            push(schema.struct_order, tname);
            schema.type_map[tname] = td;
            continue;
        }

        if kw == "input" {
            let in_res = p_expect_name(p);
            guard let iname = in_res else let e = err_of(in_res) { return err(e); }
            let chk = check_graphql_name(iname, "input type");
            guard let _ck = chk else let e = err_of(chk) { return err(e); }
            if has(defined_names, iname) {
                return err("graphql SDL: duplicate type definition " + iname);
            }
            defined_names[iname] = true;
            let dir_res = p_reject_directives(p);
            guard let _dr = dir_res else let e = err_of(dir_res) { return err(e); }
            let open_res = p_expect_punct(p, "{");
            guard let _o = open_res else let e = err_of(open_res) { return err(e); }
            let fields: [InputValueDef] = [];
            let field_names: map[str]bool = {};
            while !p_is_punct(p, "}") {
                if p_peek(p).kind == TokenKind.EOF {
                    return err("graphql SDL: unterminated input " + iname);
                }
                let fr = parse_input_value_def(p, iname + " field");
                guard let fld = fr else let e = err_of(fr) { return err(e); }
                if has(field_names, fld.name) {
                    return err("graphql SDL: duplicate field " + fld.name + " on input " + iname);
                }
                field_names[fld.name] = true;
                push(fields, fld);
            }
            p_advance(p);
            if len(fields) == 0 {
                return err("graphql SDL: input " + iname + " must define at least one field");
            }
            let id = InputDef { name: iname, fields: fields };
            push(schema.inputs, id);
            push(schema.struct_order, iname);
            schema.input_map[iname] = id;
            continue;
        }

        if kw == "enum" {
            let en_res = p_expect_name(p);
            guard let ename = en_res else let e = err_of(en_res) { return err(e); }
            let chk = check_graphql_name(ename, "enum type");
            guard let _ck = chk else let e = err_of(chk) { return err(e); }
            if has(defined_names, ename) {
                return err("graphql SDL: duplicate type definition " + ename);
            }
            defined_names[ename] = true;
            let dir_res = p_reject_directives(p);
            guard let _dr = dir_res else let e = err_of(dir_res) { return err(e); }
            let open_res = p_expect_punct(p, "{");
            guard let _o = open_res else let e = err_of(open_res) { return err(e); }
            let vals: [str] = [];
            let val_names: map[str]bool = {};
            while !p_is_punct(p, "}") {
                if p_peek(p).kind == TokenKind.EOF {
                    return err("graphql SDL: unterminated enum " + ename);
                }
                p_skip_description(p);
                let vn_res = p_expect_name(p);
                guard let vname = vn_res else let e = err_of(vn_res) { return err(e); }
                if vname == "true" || vname == "false" || vname == "null" {
                    return err("graphql SDL: invalid enum value " + vname);
                }
                let vchk = check_graphql_name(vname, ename + " value");
                guard let _vc = vchk else let e = err_of(vchk) { return err(e); }
                if has(val_names, vname) {
                    return err("graphql SDL: duplicate enum value " + vname + " on " + ename);
                }
                val_names[vname] = true;
                let vdir = p_reject_directives(p);
                guard let _vd = vdir else let e = err_of(vdir) { return err(e); }
                push(vals, vname);
            }
            p_advance(p);
            if len(vals) == 0 {
                return err("graphql SDL: enum " + ename + " must define at least one value");
            }
            let ed = EnumDef { name: ename, values: vals };
            push(schema.enums, ed);
            schema.enum_map[ename] = ed;
            continue;
        }

        if kw == "scalar" || kw == "interface" || kw == "union" || kw == "directive" || kw == "extend" {
            return err("graphql SDL: " + kw + " definitions are not supported");
        }
        return err("graphql SDL: unexpected top-level keyword " + kw);
    }

    if !schema.explicit_schema && has(schema.type_map, "Mutation") {
        schema.mutation_type = "Mutation";
        schema.has_mutation = true;
    }

    let val_res = validate_schema(schema);
    guard let _vr = val_res else let e = err_of(val_res) { return err(e); }
    return ok(schema);
}

fn validate_type_ref(schema: Schema, t: TypeRef, allow_object: bool, allow_input: bool, where: str) -> result[bool, str] {
    let bname = base_type_name(t);
    if is_builtin_scalar(bname) {
        return ok(true);
    }
    if has(schema.enum_map, bname) {
        return ok(true);
    }
    if has(schema.type_map, bname) {
        if !allow_object {
            return err("graphql SDL: object type " + bname + " cannot be used in " + where);
        }
        return ok(true);
    }
    if has(schema.input_map, bname) {
        if !allow_input {
            return err("graphql SDL: input type " + bname + " cannot be used in " + where);
        }
        return ok(true);
    }
    return err("graphql SDL: unknown type " + bname + " in " + where);
}

fn validate_default(schema: Schema, t: TypeRef, v: Value, where: str) -> result[bool, str] {
    if v.kind == ValueKind.NULL {
        if t.non_null {
            return err("graphql SDL: null default value for non-null " + where);
        }
        return ok(true);
    }
    if t.is_list {
        guard let inner = t.inner else { return err("graphql SDL: malformed list type"); }
        if v.kind == ValueKind.LIST {
            for i in 0..len(v.items) {
                let ir = validate_default(schema, inner, v.items[i], where);
                guard let _ok = ir else let e = err_of(ir) { return err(e); }
            }
            return ok(true);
        }
        return validate_default(schema, inner, v, where);
    }
    if v.kind == ValueKind.LIST {
        return err("graphql SDL: list default value for non-list " + where);
    }
    let name = t.name;
    if name == "Int" {
        if v.kind != ValueKind.INT {
            return err("graphql SDL: expected Int default value for " + where);
        }
        return ok(true);
    }
    if name == "Float" {
        if v.kind != ValueKind.FLOAT && v.kind != ValueKind.INT {
            return err("graphql SDL: expected Float default value for " + where);
        }
        return ok(true);
    }
    if name == "String" {
        if v.kind != ValueKind.STRING {
            return err("graphql SDL: expected String default value for " + where);
        }
        return ok(true);
    }
    if name == "ID" {
        if v.kind != ValueKind.STRING && v.kind != ValueKind.INT {
            return err("graphql SDL: expected ID (String or Int) default value for " + where);
        }
        return ok(true);
    }
    if name == "Boolean" {
        if v.kind != ValueKind.BOOL {
            return err("graphql SDL: expected Boolean default value for " + where);
        }
        return ok(true);
    }
    if has(schema.enum_map, name) {
        if v.kind != ValueKind.ENUM {
            return err("graphql SDL: expected enum " + name + " default value for " + where);
        }
        let ed = schema.enum_map[name];
        for i in 0..len(ed.values) {
            if ed.values[i] == v.text {
                return ok(true);
            }
        }
        return err("graphql SDL: unknown enum value " + v.text + " for " + name + " in " + where);
    }
    if has(schema.input_map, name) {
        if v.kind != ValueKind.OBJECT {
            return err("graphql SDL: expected input object " + name + " default value for " + where);
        }
        let inp = schema.input_map[name];
        let provided: map[str]Value = {};
        for i in 0..len(v.fields) {
            let vf = v.fields[i];
            let found = false;
            for j in 0..len(inp.fields) {
                if inp.fields[j].name == vf.name {
                    found = true;
                    break;
                }
            }
            if !found {
                return err("graphql SDL: unknown input field " + name + "." + vf.name + " in default value");
            }
            provided[vf.name] = vf.value;
        }
        for i in 0..len(inp.fields) {
            let inf = inp.fields[i];
            if has(provided, inf.name) {
                let dr = validate_default(schema, inf.typ, provided[inf.name], name + "." + inf.name);
                guard let _ok = dr else let e = err_of(dr) { return err(e); }
            } else if inf.typ.non_null && !inf.has_default {
                return err("graphql SDL: missing required field " + name + "." + inf.name + " in default value");
            }
        }
        return ok(true);
    }
    return err("graphql SDL: unsupported default type " + name);
}

fn validate_schema(schema: Schema) -> result[bool, str] {
    if !has(schema.type_map, schema.query_type) {
        return err("graphql SDL: query root type " + schema.query_type + " is not an object type");
    }
    if schema.has_mutation {
        if !has(schema.type_map, schema.mutation_type) {
            return err("graphql SDL: mutation root type " + schema.mutation_type + " is not an object type");
        }
        if schema.mutation_type == schema.query_type {
            return err("graphql SDL: query and mutation root types must differ");
        }
    }
    for i in 0..len(schema.types) {
        let td = schema.types[i];
        for j in 0..len(td.fields) {
            let f = td.fields[j];
            let where_out = "return type of " + td.name + "." + f.name;
            let tr = validate_type_ref(schema, f.typ, true, false, where_out);
            guard let _ok = tr else let e = err_of(tr) { return err(e); }
            for k in 0..len(f.args) {
                let a = f.args[k];
                let where_arg = "argument " + td.name + "." + f.name + "(" + a.name + ")";
                let atr = validate_type_ref(schema, a.typ, false, true, where_arg);
                guard let _aok = atr else let e = err_of(atr) { return err(e); }
                if a.has_default {
                    let dr = validate_default(schema, a.typ, a.default_val, where_arg);
                    guard let _dok = dr else let e = err_of(dr) { return err(e); }
                }
            }
        }
    }
    for i in 0..len(schema.inputs) {
        let inp = schema.inputs[i];
        for j in 0..len(inp.fields) {
            let inf = inp.fields[j];
            let where_in = "input field " + inp.name + "." + inf.name;
            let tr = validate_type_ref(schema, inf.typ, false, true, where_in);
            guard let _ok = tr else let e = err_of(tr) { return err(e); }
            if inf.has_default {
                let dr = validate_default(schema, inf.typ, inf.default_val, where_in);
                guard let _dok = dr else let e = err_of(dr) { return err(e); }
            }
        }
    }
    return ok(true);
}
