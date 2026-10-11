package main

import (
	"strings"
	"testing"
)

const testSDL = `schema { query: Root mutation: Change }
enum State { READY DONE }
input Filter { state: State! ids: [ID!] }
type Root { item(id: ID!, filter: Filter): Item userCount(limit: Int = 10): Int! }
type Change { setState(id: ID!, state: State!): Item }
type Item { id: ID! state: State! children: [Item!]! }
`

func TestGenerateTypesAndResolverContracts(t *testing.T) {
	s, err := parseSDL(testSDL)
	if err != nil {
		t.Fatal(err)
	}
	got, err := generate(s, "app.Context")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"pub let GRAPHQL_QUERY_ROOT = \"Root\";",
		"pub let GRAPHQL_MUTATION_ROOT = \"Change\";",
		"pub enum State {\n    READY,\n    DONE,\n}",
		"pub gc struct Filter {\n    state: State,\n    ids: opt[[str]],\n}",
		"pub gc struct Root_item_Args {\n    id: str,\n    filter: opt[Filter],\n}",
		"pub gc struct Item {\n    id: str,\n    state: State,\n    children: [Item],\n}",
		"pub fn graphql_call_Root_item(parent: __graphql.Root, args: Root_item_Args, ctx: app.Context) -> result[opt[Item], str]",
		"return resolve_Root_item(parent, args, ctx);",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("generated source missing %q", want)
		}
	}
}

func TestGenerateIsDeterministic(t *testing.T) {
	s, err := parseSDL(testSDL)
	if err != nil {
		t.Fatal(err)
	}
	first, err := generate(s, "graphql.Context")
	if err != nil {
		t.Fatal(err)
	}
	second, err := generate(s, "graphql.Context")
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("same schema generated different source")
	}
}

func TestParseSDLRejectsInvalidDefinitions(t *testing.T) {
	tests := []struct {
		name string
		sdl  string
		want string
	}{
		{"unknown type", `type Query { x: Missing }`, `unknown type "Missing"`},
		{"input object as output", `input I { value: String } type Query { x: I }`, `input object "I" cannot be used as an output`},
		{"output object as input", `type O { value: String } type Query { x(a: O): String }`, `output object "O" cannot be used as an input`},
		{"duplicate type", `type Query { x: Int } enum Query { A }`, `duplicate definition "Query"`},
		{"unknown root", `schema { query: Missing } type Query { x: Int }`, `schema query root "Missing" is not defined`},
		{"reserved name", `type Query { fn: Int }`, `field name "fn" is reserved`},
		{"union", `union Search = A | B type Query { x: Int }`, `interfaces and unions are not supported`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := parseSDL(tt.sdl)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("parseSDL() error = %v, want substring %q", err, tt.want)
			}
		})
	}
}

func TestGeneratedIdentifierCollisionsFail(t *testing.T) {
	s, err := parseSDL(`type A_B { c: Int } type A { B_c: Int } type Query { x: Int }`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := generate(s, "graphql.Context"); err == nil || !strings.Contains(err.Error(), "collides") {
		t.Fatalf("generate() error = %v, want generated-name collision", err)
	}
}

func TestGeneratorRejectsInvalidContextAndReservedGeneratedNames(t *testing.T) {
	s, err := parseSDL(`type Query { x: Int }`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := generate(s, `App.Ctx; fn injected()`); err == nil {
		t.Fatal("context type injection was accepted")
	}
	reserved, err := parseSDL(`type GRAPHQL_QUERY_ROOT { x: Int } type Query { y: Int }`)
	if err == nil {
		_, err = generate(reserved, "graphql.Context")
	}
	if err == nil || !strings.Contains(err.Error(), "collides") {
		t.Fatalf("reserved generated identifier error = %v", err)
	}
	if _, err := parseSDL(`type Query { __typename: String }`); err == nil || !strings.Contains(err.Error(), "reserved by GraphQL") {
		t.Fatalf("introspection name error = %v", err)
	}
	graphqlType, err := parseSDL(`type graphql { value: Int } type Query { object: graphql }`)
	if err == nil {
		_, err = generate(graphqlType, "graphql.Context")
	}
	if err != nil {
		t.Fatalf("type named graphql should be safe with generated import alias: %v", err)
	}
}

func TestInputDefaultsAreTypeChecked(t *testing.T) {
	for _, sdl := range []string{
		`input I { n: Int = "one" } type Query { find(i: I): Int }`,
		`input I { n: Int! = null } type Query { find(i: I): Int }`,
		`enum E { A } input I { e: E = B } type Query { find(i: I): Int }`,
		`input I { n: Int = 2147483648 } type Query { find(i: I): Int }`,
		`input I { n: Int! } type Query { find(i: I = {}): Int }`,
		`input I { n: Int } input J { i: I = { unknown: 1 } } type Query { find(j: J): Int }`,
	} {
		if _, err := parseSDL(sdl); err == nil {
			t.Errorf("invalid SDL default accepted: %s", sdl)
		}
	}
	if _, err := parseSDL(`enum E { A } input I { n: Int! e: E = A } type Query { find(i: I = {n: 1}): Int }`); err != nil {
		t.Fatalf("valid nested input default rejected: %v", err)
	}
}

func TestSchemaRejectsMalformedNumbersAndStringEscapes(t *testing.T) {
	for _, sdl := range []string{
		`type Query { x(n: Int = 01): Int }`,
		`"bad\q" type Query { x: Int }`,
		`input I { name: String = "\uD800" } type Query { x(i: I): Int }`,
	} {
		if _, err := parseSDL(sdl); err == nil {
			t.Errorf("parseSDL(%q) unexpectedly succeeded", sdl)
		}
	}
	if _, err := parseSDL(`input I { name: String = "\uD83D\uDE00" } type Query { x(i: I): Int }`); err != nil {
		t.Errorf("valid Unicode surrogate pair rejected: %v", err)
	}
	if _, err := parseSDL(string([]byte{'t', 'y', 'p', 'e', ' ', 'Q', 'u', 'e', 'r', 'y', ' ', '{', 'x', ':', ' ', 0xff, '}'})); err == nil {
		t.Fatal("invalid UTF-8 SDL accepted")
	}
}

func TestSDLParserBoundsTokensAndTypeDepth(t *testing.T) {
	if _, err := parseSDL(strings.Repeat("x ", 100001)); err == nil || !strings.Contains(err.Error(), "token count") {
		t.Fatalf("token count error = %v", err)
	}
	deep := strings.Repeat("[", 65) + "Int" + strings.Repeat("]", 65)
	if _, err := parseSDL("type Query { x: " + deep + " }"); err == nil || !strings.Contains(err.Error(), "nesting exceeds") {
		t.Fatalf("type depth error = %v", err)
	}
}
