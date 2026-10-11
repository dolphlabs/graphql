package main

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

type tokenKind uint8

const (
	tokEOF tokenKind = iota
	tokName
	tokInt
	tokFloat
	tokString
	tokPunct
	tokSpread
)

type token struct {
	kind tokenKind
	text string
	pos  int
}

type typeRef struct {
	name    string
	list    bool
	inner   *typeRef
	nonNull bool
}

func (t *typeRef) String() string {
	var s string
	if t.list {
		s = "[" + t.inner.String() + "]"
	} else {
		s = t.name
	}
	if t.nonNull {
		s += "!"
	}
	return s
}

type inputValue struct {
	name    string
	typ     *typeRef
	def     *value
	hasDef  bool
	linePos int
}

type fieldDef struct {
	name       string
	typ        *typeRef
	args       []inputValue
	def        *value
	hasDefault bool
}

type typeDef struct {
	kind   string
	name   string
	fields []fieldDef
	values []string
}

type value struct {
	kind   string
	raw    string
	name   string
	items  []value
	fields []valueField
}

type valueField struct {
	name  string
	value value
}

type schema struct {
	types       []typeDef
	queryRoot   string
	mutRoot     string
	explicit    bool
	definitions map[string]int
}

type sdlParser struct {
	source []byte
	tokens []token
	pos    int
	schema *schema
}

func parseSDL(source string) (*schema, error) {
	if len(source) > maxSDLBytes {
		return nil, fmt.Errorf("SDL exceeds %d-byte limit", maxSDLBytes)
	}
	if !utf8.ValidString(source) {
		return nil, fmt.Errorf("SDL is not valid UTF-8")
	}
	tokens, err := lexSDL([]byte(source))
	if err != nil {
		return nil, err
	}
	s := &schema{queryRoot: "Query", definitions: make(map[string]int)}
	p := &sdlParser{source: []byte(source), tokens: tokens, schema: s}
	for p.peek().kind != tokEOF {
		if p.peek().kind == tokString { // SDL descriptions are documentation.
			p.take()
			continue
		}
		if p.nameIs("schema") {
			if err := p.parseSchemaRoots(s); err != nil {
				return nil, err
			}
			continue
		}
		if p.nameIs("type") || p.nameIs("input") || p.nameIs("enum") {
			def, err := p.parseDefinition()
			if err != nil {
				return nil, err
			}
			if _, exists := s.definitions[def.name]; exists {
				return nil, p.errorf("duplicate definition %q", def.name)
			}
			s.definitions[def.name] = len(s.types)
			s.types = append(s.types, def)
			continue
		}
		if p.nameIs("scalar") {
			return nil, p.errorf("custom scalars need generated codecs; remove or map this scalar explicitly")
		}
		if p.nameIs("interface") || p.nameIs("union") {
			return nil, p.errorf("interfaces and unions are not supported by direct v1 dispatch; use object types")
		}
		if p.nameIs("directive") {
			return nil, p.errorf("custom directive definitions are not supported in v1")
		}
		return nil, p.errorf("expected type, input, enum, or schema definition")
	}
	if !s.explicit {
		if _, ok := s.definitions["Mutation"]; ok {
			s.mutRoot = "Mutation"
		}
	}
	if _, ok := s.definitions[s.queryRoot]; !ok {
		return nil, fmt.Errorf("schema query root %q is not defined", s.queryRoot)
	}
	if s.types[s.definitions[s.queryRoot]].kind != "type" {
		return nil, fmt.Errorf("schema query root %q must be an object type", s.queryRoot)
	}
	if s.mutRoot != "" {
		idx, ok := s.definitions[s.mutRoot]
		if !ok {
			return nil, fmt.Errorf("schema mutation root %q is not defined", s.mutRoot)
		}
		if s.types[idx].kind != "type" {
			return nil, fmt.Errorf("schema mutation root %q must be an object type", s.mutRoot)
		}
	}
	if err := p.validate(); err != nil {
		return nil, err
	}
	return s, nil
}

func lexSDL(raw []byte) ([]token, error) {
	var out []token
	for i := 0; i < len(raw); {
		c := raw[i]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == ',' {
			i++
			continue
		}
		if c == '#' {
			for i < len(raw) && raw[i] != '\n' && raw[i] != '\r' {
				i++
			}
			continue
		}
		start := i
		if nameStart(c) {
			i++
			for i < len(raw) && nameContinue(raw[i]) {
				i++
			}
			if err := appendSDLToken(&out, token{tokName, string(raw[start:i]), start}); err != nil {
				return nil, err
			}
			continue
		}
		if c == '-' || (c >= '0' && c <= '9') {
			end, kind, err := scanNumber(raw, i)
			if err != nil {
				return nil, fmt.Errorf("SDL byte %d: %w", start, err)
			}
			i = end
			if err := appendSDLToken(&out, token{kind, string(raw[start:end]), start}); err != nil {
				return nil, err
			}
			continue
		}
		if c == '"' {
			if i+2 < len(raw) && raw[i+1] == '"' && raw[i+2] == '"' {
				return nil, fmt.Errorf("SDL byte %d: block strings are not supported; use quoted descriptions", i)
			}
			end, err := scanString(raw, i)
			if err != nil {
				return nil, fmt.Errorf("SDL byte %d: %w", start, err)
			}
			i = end
			if err := appendSDLToken(&out, token{tokString, string(raw[start:end]), start}); err != nil {
				return nil, err
			}
			continue
		}
		if c == '.' && i+2 < len(raw) && raw[i+1] == '.' && raw[i+2] == '.' {
			i += 3
			if err := appendSDLToken(&out, token{tokSpread, "...", start}); err != nil {
				return nil, err
			}
			continue
		}
		if strings.ContainsRune("!$&():=@[]{|}", rune(c)) {
			i++
			if err := appendSDLToken(&out, token{tokPunct, string(c), start}); err != nil {
				return nil, err
			}
			continue
		}
		return nil, fmt.Errorf("SDL byte %d: invalid character %q", i, c)
	}
	out = append(out, token{kind: tokEOF, pos: len(raw)})
	return out, nil
}

func appendSDLToken(tokens *[]token, next token) error {
	if len(*tokens) >= 100000 {
		return fmt.Errorf("SDL token count exceeds 100000-token limit")
	}
	*tokens = append(*tokens, next)
	return nil
}

func (p *sdlParser) parseSchemaRoots(s *schema) error {
	p.take() // schema
	if s.explicit {
		return p.errorf("duplicate schema definition")
	}
	s.explicit = true
	s.queryRoot = ""
	s.mutRoot = ""
	if err := p.expect("{"); err != nil {
		return err
	}
	for !p.is("}") {
		root, err := p.expectName()
		if err != nil {
			return err
		}
		if err := p.expect(":"); err != nil {
			return err
		}
		typ, err := p.expectName()
		if err != nil {
			return err
		}
		switch root.text {
		case "query":
			if s.queryRoot != "" {
				return p.errorf("duplicate query root")
			}
			s.queryRoot = typ.text
		case "mutation":
			if s.mutRoot != "" {
				return p.errorf("duplicate mutation root")
			}
			s.mutRoot = typ.text
		default:
			return p.errorf("schema root %q is unsupported", root.text)
		}
	}
	p.take()
	if s.queryRoot == "" {
		return p.errorf("schema definition must declare a query root")
	}
	return nil
}

func (p *sdlParser) parseDefinition() (typeDef, error) {
	kind := p.take().text
	name, err := p.expectName()
	if err != nil {
		return typeDef{}, err
	}
	if err := validSlangIdentifier(name.text); err != nil {
		return typeDef{}, p.errorf("type name %q %s", name.text, err)
	}
	if strings.HasPrefix(name.text, "__") {
		return typeDef{}, p.errorf("type names beginning '__' are reserved by GraphQL")
	}
	d := typeDef{kind: kind, name: name.text}
	if kind == "enum" {
		if err := p.expect("{"); err != nil {
			return typeDef{}, err
		}
		for !p.is("}") {
			if p.peek().kind == tokString {
				p.take()
			}
			v, err := p.expectName()
			if err != nil {
				return typeDef{}, err
			}
			if strings.HasPrefix(v.text, "__") {
				return typeDef{}, p.errorf("enum value names beginning '__' are reserved")
			}
			for _, old := range d.values {
				if old == v.text {
					return typeDef{}, p.errorf("duplicate enum value %q", v.text)
				}
			}
			d.values = append(d.values, v.text)
		}
		p.take()
		if len(d.values) == 0 {
			return typeDef{}, p.errorf("enum %q must contain at least one value", d.name)
		}
		return d, nil
	}
	if p.is("implements") || p.is("&") {
		return typeDef{}, p.errorf("interfaces are not supported; remove implements")
	}
	if p.is("@") {
		return typeDef{}, p.errorf("schema directives are not supported in v1")
	}
	if err := p.expect("{"); err != nil {
		return typeDef{}, err
	}
	for !p.is("}") {
		if p.peek().kind == tokString {
			p.take() // description
		}
		fieldName, err := p.expectName()
		if err != nil {
			return typeDef{}, err
		}
		if err := validSlangIdentifier(fieldName.text); err != nil {
			return typeDef{}, p.errorf("field name %q %s", fieldName.text, err)
		}
		if strings.HasPrefix(fieldName.text, "__") {
			return typeDef{}, p.errorf("field names beginning '__' are reserved by GraphQL")
		}
		for _, old := range d.fields {
			if old.name == fieldName.text {
				return typeDef{}, p.errorf("duplicate field %q on %s", fieldName.text, d.name)
			}
		}
		var args []inputValue
		if kind == "type" && p.is("(") {
			args, err = p.parseInputValues(")")
			if err != nil {
				return typeDef{}, err
			}
		}
		if err := p.expect(":"); err != nil {
			return typeDef{}, err
		}
		typ, err := p.parseTypeRef()
		if err != nil {
			return typeDef{}, err
		}
		if p.is("@") {
			return typeDef{}, p.errorf("field directives are not supported in v1")
		}
		var def *value
		hasDefault := false
		if kind == "input" && p.is("=") {
			p.take()
			def, err = p.parseValue()
			if err != nil {
				return typeDef{}, err
			}
			hasDefault = true
		}
		d.fields = append(d.fields, fieldDef{name: fieldName.text, typ: typ, args: args,
			def: def, hasDefault: hasDefault})
	}
	p.take()
	if len(d.fields) == 0 {
		return typeDef{}, p.errorf("%s %q must contain at least one field", kind, d.name)
	}
	return d, nil
}

func (p *sdlParser) parseInputValues(end string) ([]inputValue, error) {
	if err := p.expect("("); err != nil {
		return nil, err
	}
	var args []inputValue
	for !p.is(end) {
		if p.peek().kind == tokString {
			p.take()
		}
		name, err := p.expectName()
		if err != nil {
			return nil, err
		}
		if err := validSlangIdentifier(name.text); err != nil {
			return nil, p.errorf("argument name %q %s", name.text, err)
		}
		if strings.HasPrefix(name.text, "__") {
			return nil, p.errorf("argument names beginning '__' are reserved by GraphQL")
		}
		for _, old := range args {
			if old.name == name.text {
				return nil, p.errorf("duplicate argument %q", name.text)
			}
		}
		if err := p.expect(":"); err != nil {
			return nil, err
		}
		typ, err := p.parseTypeRef()
		if err != nil {
			return nil, err
		}
		arg := inputValue{name: name.text, typ: typ, linePos: name.pos}
		if p.is("=") {
			p.take()
			arg.def, err = p.parseValue()
			if err != nil {
				return nil, err
			}
			arg.hasDef = true
		}
		if p.is("@") {
			return nil, p.errorf("input value directives are not supported in v1")
		}
		args = append(args, arg)
	}
	p.take()
	return args, nil
}

func (p *sdlParser) parseTypeRef() (*typeRef, error) {
	return p.parseTypeRefDepth(0)
}

func (p *sdlParser) parseTypeRefDepth(depth int) (*typeRef, error) {
	if depth > 64 {
		return nil, p.errorf("type nesting exceeds 64 levels")
	}
	t := &typeRef{}
	if p.is("[") {
		p.take()
		inner, err := p.parseTypeRefDepth(depth + 1)
		if err != nil {
			return nil, err
		}
		if err := p.expect("]"); err != nil {
			return nil, err
		}
		t.list, t.inner = true, inner
	} else {
		name, err := p.expectName()
		if err != nil {
			return nil, err
		}
		t.name = name.text
	}
	if p.is("!") {
		p.take()
		t.nonNull = true
	}
	return t, nil
}

func (p *sdlParser) parseValue() (*value, error) {
	return p.parseValueDepth(0)
}

func (p *sdlParser) parseValueDepth(depth int) (*value, error) {
	if depth > 64 {
		return nil, p.errorf("default value nesting exceeds 64 levels")
	}
	t := p.peek()
	switch t.kind {
	case tokString, tokInt, tokFloat:
		p.take()
		return &value{kind: map[tokenKind]string{tokString: "string", tokInt: "int", tokFloat: "float"}[t.kind], raw: t.text}, nil
	case tokName:
		p.take()
		switch t.text {
		case "true", "false", "null":
			return &value{kind: t.text, raw: t.text}, nil
		default:
			return &value{kind: "enum", name: t.text}, nil
		}
	case tokPunct:
		if t.text == "[" {
			p.take()
			v := &value{kind: "list"}
			for !p.is("]") {
				item, err := p.parseValueDepth(depth + 1)
				if err != nil {
					return nil, err
				}
				v.items = append(v.items, *item)
			}
			p.take()
			return v, nil
		}
		if t.text == "{" {
			p.take()
			v := &value{kind: "object"}
			for !p.is("}") {
				name, err := p.expectName()
				if err != nil {
					return nil, err
				}
				if err := p.expect(":"); err != nil {
					return nil, err
				}
				for _, old := range v.fields {
					if old.name == name.text {
						return nil, p.errorf("duplicate input field %q", name.text)
					}
				}
				item, err := p.parseValueDepth(depth + 1)
				if err != nil {
					return nil, err
				}
				v.fields = append(v.fields, valueField{name: name.text, value: *item})
			}
			p.take()
			return v, nil
		}
	}
	return nil, p.errorf("expected a default value")
}

func (p *sdlParser) validate() error {
	for _, d := range p.schema.types {
		if d.kind == "enum" {
			for _, name := range d.values {
				if err := validSlangIdentifier(name); err != nil {
					return fmt.Errorf("enum value %s.%s %w", d.name, name, err)
				}
			}
			continue
		}
		for _, f := range d.fields {
			isInput := d.kind == "input"
			if err := p.validateType(f.typ, isInput); err != nil {
				return fmt.Errorf("%s.%s: %w", d.name, f.name, err)
			}
			if f.hasDefault {
				if err := p.validateDefault(f.typ, f.def); err != nil {
					return fmt.Errorf("%s.%s default: %w", d.name, f.name, err)
				}
			}
			for _, arg := range f.args {
				if err := p.validateType(arg.typ, true); err != nil {
					return fmt.Errorf("%s.%s(%s): %w", d.name, f.name, arg.name, err)
				}
				if arg.hasDef {
					if err := p.validateDefault(arg.typ, arg.def); err != nil {
						return fmt.Errorf("%s.%s(%s) default: %w", d.name, f.name, arg.name, err)
					}
				}
			}
		}
	}
	return nil
}

func (p *sdlParser) validateDefault(t *typeRef, v *value) error {
	if v == nil {
		return fmt.Errorf("missing default value")
	}
	if v.kind == "null" {
		if t.nonNull {
			return fmt.Errorf("null cannot be the default for non-null %s", t)
		}
		return nil
	}
	if t.list {
		if v.kind != "list" {
			return p.validateDefault(t.inner, v) // GraphQL permits singleton list coercion.
		}
		for i := range v.items {
			if err := p.validateDefault(t.inner, &v.items[i]); err != nil {
				return fmt.Errorf("list item %d: %w", i, err)
			}
		}
		return nil
	}
	switch t.name {
	case "Int":
		if v.kind != "int" {
			return fmt.Errorf("expected Int, got %s", v.kind)
		}
		if _, err := strconv.ParseInt(v.raw, 10, 32); err != nil {
			return fmt.Errorf("Int default is outside the signed 32-bit range")
		}
		return nil
	case "Float":
		if v.kind != "int" && v.kind != "float" {
			return fmt.Errorf("expected Float, got %s", v.kind)
		}
		if _, err := strconv.ParseFloat(v.raw, 64); err != nil {
			return fmt.Errorf("invalid Float default")
		}
		return nil
	case "String":
		if v.kind != "string" {
			return fmt.Errorf("expected String, got %s", v.kind)
		}
		return nil
	case "Boolean":
		if v.kind != "true" && v.kind != "false" {
			return fmt.Errorf("expected Boolean, got %s", v.kind)
		}
		return nil
	case "ID":
		if v.kind != "string" && v.kind != "int" {
			return fmt.Errorf("expected ID string or integer, got %s", v.kind)
		}
		return nil
	}
	index, ok := p.schema.definitions[t.name]
	if !ok {
		return fmt.Errorf("unknown type %q", t.name)
	}
	d := p.schema.types[index]
	if d.kind == "enum" {
		if v.kind != "enum" {
			return fmt.Errorf("expected enum %s", d.name)
		}
		for _, name := range d.values {
			if name == v.name {
				return nil
			}
		}
		return fmt.Errorf("unknown %s value %q", d.name, v.name)
	}
	if d.kind != "input" || v.kind != "object" {
		return fmt.Errorf("expected input object %s", d.name)
	}
	seen := make(map[string]bool, len(v.fields))
	for _, input := range v.fields {
		if seen[input.name] {
			return fmt.Errorf("duplicate input field %q", input.name)
		}
		seen[input.name] = true
		matched := false
		for _, field := range d.fields {
			if input.name == field.name {
				matched = true
				if err := p.validateDefault(field.typ, &input.value); err != nil {
					return fmt.Errorf("field %s: %w", input.name, err)
				}
				break
			}
		}
		if !matched {
			return fmt.Errorf("unknown input field %q on %s", input.name, d.name)
		}
	}
	for _, field := range d.fields {
		if field.typ.nonNull && !field.hasDefault && !seen[field.name] {
			return fmt.Errorf("required input field %q is missing", field.name)
		}
	}
	return nil
}

func (p *sdlParser) validateType(t *typeRef, input bool) error {
	if t.list {
		return p.validateType(t.inner, input)
	}
	switch t.name {
	case "Int", "Float", "String", "Boolean", "ID":
		return nil
	}
	idx, ok := p.schemaIndex(t.name)
	if !ok {
		return fmt.Errorf("unknown type %q", t.name)
	}
	kind := p.pTypeKind(idx)
	if input && kind == "type" {
		return fmt.Errorf("output object %q cannot be used as an input", t.name)
	}
	if !input && kind == "input" {
		return fmt.Errorf("input object %q cannot be used as an output", t.name)
	}
	return nil
}

func (p *sdlParser) schemaIndex(name string) (int, bool) {
	index, ok := p.schema.definitions[name]
	return index, ok
}

func (p *sdlParser) pTypeKind(index int) string {
	return p.schema.types[index].kind
}

func (p *sdlParser) peek() token {
	if p.pos >= len(p.tokens) {
		return token{kind: tokEOF}
	}
	return p.tokens[p.pos]
}

func (p *sdlParser) take() token {
	t := p.peek()
	if t.kind != tokEOF {
		p.pos++
	}
	return t
}

func (p *sdlParser) is(text string) bool { return p.peek().text == text }
func (p *sdlParser) nameIs(text string) bool {
	return p.peek().kind == tokName && p.peek().text == text
}

func (p *sdlParser) expect(text string) error {
	if !p.is(text) {
		return p.errorf("expected %q, found %q", text, p.peek().text)
	}
	p.take()
	return nil
}

func (p *sdlParser) expectName() (token, error) {
	if p.peek().kind != tokName {
		return token{}, p.errorf("expected a name, found %q", p.peek().text)
	}
	return p.take(), nil
}

func (p *sdlParser) errorf(format string, args ...any) error {
	t := p.peek()
	line, col := 1, 1
	for _, c := range p.source[:min(t.pos, len(p.source))] {
		if c == '\n' {
			line, col = line+1, 1
		} else {
			col++
		}
	}
	return fmt.Errorf("SDL line %d, column %d: %s", line, col, fmt.Sprintf(format, args...))
}

func nameStart(c byte) bool    { return c == '_' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }
func nameContinue(c byte) bool { return nameStart(c) || c >= '0' && c <= '9' }

func scanNumber(raw []byte, start int) (int, tokenKind, error) {
	i := start
	if raw[i] == '-' {
		i++
		if i == len(raw) {
			return 0, 0, fmt.Errorf("minus must start a number")
		}
	}
	if raw[i] == '0' {
		i++
		if i < len(raw) && raw[i] >= '0' && raw[i] <= '9' {
			return 0, 0, fmt.Errorf("number cannot have a leading zero")
		}
	} else if raw[i] >= '1' && raw[i] <= '9' {
		for i < len(raw) && raw[i] >= '0' && raw[i] <= '9' {
			i++
		}
	} else {
		return 0, 0, fmt.Errorf("expected number digits")
	}
	kind := tokInt
	if i < len(raw) && raw[i] == '.' {
		kind = tokFloat
		i++
		if i == len(raw) || raw[i] < '0' || raw[i] > '9' {
			return 0, 0, fmt.Errorf("fraction needs digits")
		}
		for i < len(raw) && raw[i] >= '0' && raw[i] <= '9' {
			i++
		}
	}
	if i < len(raw) && (raw[i] == 'e' || raw[i] == 'E') {
		kind = tokFloat
		i++
		if i < len(raw) && (raw[i] == '+' || raw[i] == '-') {
			i++
		}
		if i == len(raw) || raw[i] < '0' || raw[i] > '9' {
			return 0, 0, fmt.Errorf("exponent needs digits")
		}
		for i < len(raw) && raw[i] >= '0' && raw[i] <= '9' {
			i++
		}
	}
	return i, kind, nil
}

func scanString(raw []byte, start int) (int, error) {
	for i := start + 1; i < len(raw); i++ {
		if raw[i] == '"' {
			return i + 1, nil
		}
		if raw[i] < 0x20 {
			return 0, fmt.Errorf("unescaped control in string")
		}
		if raw[i] == '\\' {
			i++
			if i >= len(raw) {
				return 0, fmt.Errorf("truncated string escape")
			}
			if strings.ContainsRune("\"\\/bfnrt", rune(raw[i])) {
				continue
			}
			if raw[i] != 'u' || i+4 >= len(raw) {
				return 0, fmt.Errorf("invalid string escape")
			}
			code, err := strconv.ParseUint(string(raw[i+1:i+5]), 16, 16)
			if err != nil {
				return 0, fmt.Errorf("invalid Unicode escape")
			}
			for j := i + 1; j <= i+4; j++ {
				if _, err := strconv.ParseUint(string(raw[j]), 16, 4); err != nil {
					return 0, fmt.Errorf("invalid Unicode escape")
				}
			}
			if code >= 0xD800 && code <= 0xDBFF {
				if i+10 >= len(raw) || raw[i+5] != '\\' || raw[i+6] != 'u' {
					return 0, fmt.Errorf("high surrogate lacks a low surrogate")
				}
				low, err := strconv.ParseUint(string(raw[i+7:i+11]), 16, 16)
				if err != nil || low < 0xDC00 || low > 0xDFFF {
					return 0, fmt.Errorf("invalid low surrogate")
				}
				i += 10
			} else if code >= 0xDC00 && code <= 0xDFFF {
				return 0, fmt.Errorf("unpaired low surrogate")
			} else {
				i += 4
			}
		}
	}
	return 0, fmt.Errorf("unterminated string")
}

func validSlangIdentifier(s string) error {
	if s == "" || !nameStart(s[0]) {
		return fmt.Errorf("is not a valid slang identifier")
	}
	for i := 1; i < len(s); i++ {
		if !nameContinue(s[i]) {
			return fmt.Errorf("is not a valid slang identifier")
		}
	}
	if reservedNames[s] {
		return fmt.Errorf("is reserved in slang; rename it in the schema")
	}
	return nil
}

var reservedNames = map[string]bool{
	"let": true, "fn": true, "pub": true, "gc": true, "struct": true,
	"enum": true, "impl": true, "if": true, "else": true, "while": true,
	"for": true, "in": true, "loop": true, "break": true, "continue": true,
	"return": true, "guard": true, "match": true, "switch": true, "case": true,
	"default": true, "true": true, "false": true, "none": true, "some": true,
	"null": true, "opt": true, "result": true, "err": true, "ok": true,
	"own": true, "mut": true, "move": true, "spawn": true, "chan": true,
	"select": true, "defer": true, "import": true, "as": true,
	"int": true, "i8": true, "i16": true, "i32": true, "i64": true,
	"u8": true, "u16": true, "u32": true, "u64": true, "f32": true,
	"f64": true, "str": true, "bytes": true, "bool": true, "float": true,
	"duration": true, "rawptr": true, "map": true, "list": true,
}
