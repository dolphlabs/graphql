import "builder";
import "fs";
import "io";
import "os";
import "proc";
import "strings";
import "time";
import "unicode";

fn read_sdl_file(path: str) -> result[str, str] {
    let fdr = fs.open(path);
    guard let fd = fdr else let e = err_of(fdr) {
        return err("open " + path + ": " + e);
    }
    let out = builder.new_bytes();
    let limit = max_sdl_bytes();
    let total = 0;
    while true {
        let rr = fs.read(fd, 65536);
        guard let chunk = rr else let e = err_of(rr) {
            let _c = fs.close(fd);
            return err("read " + path + ": " + e);
        }
        if len(chunk) == 0 {
            break;
        }
        total = total + len(chunk);
        if total > limit {
            let _c = fs.close(fd);
            return err(path + ": schema exceeds 1 MiB byte limit");
        }
        out.write(chunk);
    }
    let cr = fs.close(fd);
    guard let _ok = cr else let e = err_of(cr) {
        return err("close " + path + ": " + e);
    }
    let bs = out.finish();
    if !unicode.valid_bytes(bs) {
        return err(path + ": schema is not valid UTF-8");
    }
    return ok(strings.from_bytes(bs, 0, len(bs)));
}

fn read_existing_file(path: str) -> result[str, str] {
    let fdr = fs.open(path);
    guard let fd = fdr else let e = err_of(fdr) {
        return err("open " + path + ": " + e);
    }
    let out = builder.new_bytes();
    while true {
        let rr = fs.read(fd, 65536);
        guard let chunk = rr else let e = err_of(rr) {
            let _c = fs.close(fd);
            return err("read " + path + ": " + e);
        }
        if len(chunk) == 0 {
            break;
        }
        out.write(chunk);
    }
    let cr = fs.close(fd);
    guard let _ok = cr else let e = err_of(cr) {
        return err("close " + path + ": " + e);
    }
    let bs = out.finish();
    return ok(strings.from_bytes(bs, 0, len(bs)));
}

fn parent_dir(path: str) -> str {
    let slash = strings.rfind(path, "/");
    if slash < 0 { return "."; }
    if slash == 0 { return "/"; }
    return strings.slice(path, 0, slash);
}

fn write_atomic(path: str, content: str) -> result[bool, str] {
    let dir = parent_dir(path);
    let stamp = to_str(os.pid()) + "." + to_str(time.mono());
    let tmp = dir + "/.graphqlc." + stamp + ".tmp";
    if dir == "/" {
        tmp = "/.graphqlc." + stamp + ".tmp";
    }
    let fdr = fs.create(tmp);
    guard let fd = fdr else let e = err_of(fdr) {
        return err("create temp " + tmp + ": " + e);
    }
    let data = to_bytes(content);
    let wr = fs.write(fd, data);
    guard let nw = wr else let e = err_of(wr) {
        let _c = fs.close(fd);
        let _r = os.remove(tmp);
        return err("write " + tmp + ": " + e);
    }
    if nw != len(data) {
        let _c = fs.close(fd);
        let _r = os.remove(tmp);
        return err("short write to " + tmp);
    }
    let cr = fs.close(fd);
    guard let _ck = cr else let e = err_of(cr) {
        let _r = os.remove(tmp);
        return err("close " + tmp + ": " + e);
    }
    let rr = os.rename(tmp, path);
    guard let _rk = rr else let e = err_of(rr) {
        let _r = os.remove(tmp);
        return err("rename " + tmp + " -> " + path + ": " + e);
    }
    return ok(true);
}

struct CLIFlags {
    schema_path: str,
    out_path: str,
    context_type: str,
    check: bool,
    help: bool
}

fn parse_bool_flag(raw: str) -> result[bool, str] {
    if raw == "true" || raw == "1" { return ok(true); }
    if raw == "false" || raw == "0" { return ok(false); }
    return err("invalid boolean value '" + raw + "' for -check");
}

fn parse_cli_flags(args: [str]) -> result[CLIFlags, str] {
    let res = CLIFlags {
        schema_path: "",
        out_path: "",
        context_type: "graphql.Context",
        check: false,
        help: false
    };
    let i = 0;
    while i < len(args) {
        let arg = args[i];
        if arg == "--" {
            if i + 1 < len(args) {
                return err("unexpected positional argument: " + args[i + 1]);
            }
            break;
        }
        if !strings.has_prefix(arg, "-") || arg == "-" {
            return err("unexpected positional argument: " + arg);
        }
        let body = strings.slice(arg, 1, len(arg));
        if strings.has_prefix(body, "-") {
            body = strings.slice(body, 1, len(body));
        }
        let eq = strings.find(body, "=");
        let name = body;
        let has_eq = false;
        let eq_val = "";
        if eq >= 0 {
            name = strings.slice(body, 0, eq);
            eq_val = strings.slice(body, eq + 1, len(body));
            has_eq = true;
        }
        if name == "h" || name == "help" {
            res.help = true;
            return ok(res);
        }
        if name == "check" {
            if has_eq {
                let br = parse_bool_flag(eq_val);
                guard let bv = br else let e = err_of(br) { return err(e); }
                res.check = bv;
            } else {
                res.check = true;
            }
            i = i + 1;
            continue;
        }
        if name == "schema" || name == "out" || name == "context" {
            let val = "";
            if has_eq {
                val = eq_val;
                i = i + 1;
            } else {
                if i + 1 >= len(args) {
                    return err("flag -" + name + " requires a value");
                }
                val = args[i + 1];
                i = i + 2;
            }
            if name == "schema" { res.schema_path = val; }
            else if name == "out" { res.out_path = val; }
            else { res.context_type = val; }
            continue;
        }
        return err("unknown flag -" + name);
    }
    return ok(res);
}

fn usage_text() -> str {
    return "usage: graphqlc -schema <schema.graphql> -out <schema.gen.sl> [-context <pkg.Type>] [-check]";
}

fn run_cli(args: [str]) -> result[str, str] {
    let pr = parse_cli_flags(args);
    guard let cfg = pr else let e = err_of(pr) { return err(e); }
    if cfg.help {
        return ok(usage_text());
    }
    if len(cfg.schema_path) == 0 || len(cfg.out_path) == 0 {
        return err("both -schema and -out are required (" + usage_text() + ")");
    }
    let sdl_res = read_sdl_file(cfg.schema_path);
    guard let sdl = sdl_res else let e = err_of(sdl_res) { return err(e); }
    let schema_res = parse_sdl(sdl);
    guard let schema = schema_res else let e = err_of(schema_res) { return err(e); }
    let gen_res = generate(schema, cfg.context_type);
    guard let generated = gen_res else let e = err_of(gen_res) { return err(e); }

    if cfg.check {
        let cur_res = read_existing_file(cfg.out_path);
        guard let existing = cur_res else let e = err_of(cur_res) { return err(e); }
        if existing != generated {
            return err(cfg.out_path + " is out of date");
        }
        return ok("");
    }
    let wr = write_atomic(cfg.out_path, generated);
    guard let _wok = wr else let e = err_of(wr) { return err(e); }
    return ok("");
}

fn cli_entry() -> int {
    let raw_args = proc.args();
    let args: [str] = [];
    for i in 1..len(raw_args) {
        push(args, raw_args[i]);
    }
    let res = run_cli(args);
    guard let msg = res else let e = err_of(res) {
        io.eprintln("graphqlc: " + e);
        return 1;
    }
    if len(msg) > 0 {
        io.eprintln(msg);
    }
    return 0;
}

exit(cli_entry());
