import "graphql" as __graphql;
import "strings";

fn resolve_Query_hello(parent: __graphql.Root, args: Query_hello_Args,
                       ctx: __graphql.Context) -> result[str, str] {
    if let who = args.who { if who == "fail" { return err("private resolver detail"); } }
    if let filter = args.filter {
        guard let active = filter.active else { return err("input default missing"); }
        if !active || filter.tenantId != "tenant-1" { return err("input normalization failed"); }
        if len(filter.scopes) != 1 || filter.scopes[0].id != "scope-1" {
            return err("input list coercion failed");
        }
    }
    return ok("hello");
}

fn resolve_Query_user(parent: __graphql.Root, args: Query_user_Args,
                      ctx: __graphql.Context) -> result[opt[User], str] {
    return ok(some(User { id: args.id, name: "Ada", role: Role.USER }));
}

fn resolve_Query_integer(parent: __graphql.Root, args: Query_integer_Args,
                         ctx: __graphql.Context) -> result[int, str] {
    return ok(args.value);
}

fn resolve_Query_over(parent: __graphql.Root, args: __graphql.NoArgs,
                      ctx: __graphql.Context) -> result[[opt[str]], str] {
    return ok([some("small"), some(strings.repeat("x", 300))]);
}

fn resolve_Query_strictOver(parent: __graphql.Root, args: __graphql.NoArgs,
                            ctx: __graphql.Context) -> result[opt[[str]], str] {
    return ok(some([strings.repeat("x", 300)]));
}

fn resolve_User_id(parent: User, args: __graphql.NoArgs,
                    ctx: __graphql.Context) -> result[str, str] {
    return ok(parent.id);
}

fn resolve_User_name(parent: User, args: __graphql.NoArgs,
                      ctx: __graphql.Context) -> result[str, str] {
    if parent.id == "bad" { return err("private database detail"); }
    return ok(parent.name);
}

fn resolve_User_role(parent: User, args: __graphql.NoArgs,
                     ctx: __graphql.Context) -> result[Role, str] {
    return ok(parent.role);
}

fn resolve_Mutation_rename(parent: __graphql.Root, args: Mutation_rename_Args,
                           ctx: __graphql.Context) -> result[User, str] {
    return ok(User { id: args.id, name: args.name, role: Role.USER });
}

let greeting_result = graphql_call_Query_hello(
    __graphql.root_new(), Query_hello_Args { who: some("agent"), filter: none },
    __graphql.context_new());
guard let greeting = greeting_result else let e = err_of(greeting_result) { panic(e); }
println(greeting);

let user_result = graphql_call_Query_user(
    __graphql.root_new(), Query_user_Args { id: "7" }, __graphql.context_new());
guard let maybe_user = user_result else let e = err_of(user_result) { panic(e); }
guard let user = maybe_user else { panic("user resolver returned none"); }
let name_result = graphql_call_User_name(user, __graphql.no_args(), __graphql.context_new());
guard let name = name_result else let e = err_of(name_result) { panic(e); }
println(name);

let query_result = graphql_execute(
    "query Fetch($id: ID!, $who: String = \"agent\", $showRole: Boolean = true, $filter: UserFilter!) { " +
    "hello(who: $who, filter: $filter) user(id: $id) { ...UserFields __typename } __typename } " +
    "fragment UserFields on User { name role @include(if: $showRole) }",
    "Fetch", b"{\"id\":\"7\",\"filter\":{\"tenantId\":\"tenant-1\",\"scopes\":{\"id\":\"scope-1\"}}}",
    __graphql.context_new(), __graphql.default_limits());
guard let query_response = query_result else let e = err_of(query_result) { panic(e); }
println(strings.from_bytes(query_response, 0, len(query_response)));

let mutation_result = graphql_execute(
    "mutation Rename($id: ID!) { rename(id: $id, name: \"Sam\") { id name } }",
    "Rename", b"{\"id\":\"8\"}", __graphql.context_new(), __graphql.default_limits());
guard let mutation_response = mutation_result else let e = err_of(mutation_result) { panic(e); }
println(strings.from_bytes(mutation_response, 0, len(mutation_response)));

let invalid_result = graphql_execute(
    "query { notAField }", "", b"{}", __graphql.context_new(), __graphql.default_limits());
guard let invalid_response = invalid_result else let e = err_of(invalid_result) { panic(e); }
println(strings.from_bytes(invalid_response, 0, len(invalid_response)));

let bad_input_result = graphql_execute(
    "query { hello(filter: {tenantId: \"tenant-1\", unknown: 1}) }", "", b"{}",
    __graphql.context_new(), __graphql.default_limits());
guard let bad_input = bad_input_result else let e = err_of(bad_input_result) { panic(e); }
println(strings.from_bytes(bad_input, 0, len(bad_input)));

let bad_condition_result = graphql_execute(
    "query { user(id: \"7\") { ... on Missing { name } } }", "", b"{}",
    __graphql.context_new(), __graphql.default_limits());
guard let bad_condition = bad_condition_result else let e = err_of(bad_condition_result) { panic(e); }
println(strings.from_bytes(bad_condition, 0, len(bad_condition)));

let partial_result = graphql_execute(
    "query { hello user(id: \"bad\") { name } }", "", b"{}",
    __graphql.context_new(), __graphql.default_limits());
guard let partial = partial_result else let e = err_of(partial_result) { panic(e); }
println(strings.from_bytes(partial, 0, len(partial)));

let nonnull_result = graphql_execute(
    "query { hello(who: \"fail\") }", "", b"{}",
    __graphql.context_new(), __graphql.default_limits());
guard let nonnull = nonnull_result else let e = err_of(nonnull_result) { panic(e); }
println(strings.from_bytes(nonnull, 0, len(nonnull)));

let bounded_result = __graphql.new_limits(65536, 32, 10000, 1000, 128, 256, 1000, 256);
guard let bounded = bounded_result else let e = err_of(bounded_result) { panic(e); }
let list_item_result = graphql_execute(
    "query { over }", "", b"{}", __graphql.context_new(), bounded);
guard let list_item = list_item_result else let e = err_of(list_item_result) { panic(e); }
println(strings.from_bytes(list_item, 0, len(list_item)));

let nonnull_item_result = graphql_execute(
    "query { strictOver }", "", b"{}", __graphql.context_new(), bounded);
guard let nonnull_item = nonnull_item_result else let e = err_of(nonnull_item_result) { panic(e); }
println(strings.from_bytes(nonnull_item, 0, len(nonnull_item)));

let id_integer_result = graphql_execute(
    "query { user(id: 7) { id } }", "", b"{}",
    __graphql.context_new(), __graphql.default_limits());
guard let id_integer = id_integer_result else let e = err_of(id_integer_result) { panic(e); }
println(strings.from_bytes(id_integer, 0, len(id_integer)));

let int_range_result = graphql_execute(
    "query { integer(value: 2147483648) }", "", b"{}",
    __graphql.context_new(), __graphql.default_limits());
guard let int_range = int_range_result else let e = err_of(int_range_result) { panic(e); }
println(strings.from_bytes(int_range, 0, len(int_range)));
