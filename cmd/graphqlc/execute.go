package main

import (
	"fmt"
	"strconv"
	"strings"
)

func generateExecution(s *schema, contextType string) (string, error) {
	var b strings.Builder
	argFields := executionArgsFields(s)
	b.WriteString("// Reuse validated selections and typed arguments during execution.\n")
	b.WriteString("gc struct graphql_ExpansionEntry { type_id: int, incoming: [__graphql.Selection], expanded: [__graphql.Selection] }\n")
	for _, field := range argFields {
		fmt.Fprintf(&b, "gc struct %s { selection: __graphql.Selection, args: %s }\n",
			argsPlanEntryType(field), argsTypeName(field.object, field.field))
	}
	b.WriteString("\ngc struct graphql_ExecutionPlan {\n    expansions: [graphql_ExpansionEntry]")
	if len(argFields) > 0 {
		b.WriteString(",\n")
		for i, field := range argFields {
			comma := ","
			if i == len(argFields)-1 {
				comma = ""
			}
			fmt.Fprintf(&b, "    %s: [%s]%s\n", argsPlanField(field), argsPlanEntryType(field), comma)
		}
	} else {
		b.WriteByte('\n')
	}
	b.WriteString("}\n\n")
	b.WriteString("fn graphql_same_selection_list(a: [__graphql.Selection], b: [__graphql.Selection]) -> bool {\n")
	b.WriteString("    if len(a) != len(b) { return false; }\n    for i in 0..len(a) {\n        let left = a[i];\n        let right = b[i];\n")
	b.WriteString("        if left.kind != right.kind || left.name.start != right.name.start || left.name.end != right.name.end || left.alias.start != right.alias.start || left.alias.end != right.alias.end || left.type_condition.start != right.type_condition.start || left.type_condition.end != right.type_condition.end { return false; }\n    }\n    return true;\n}\n\n")
	b.WriteString("fn graphql_expansion_index(plan: graphql_ExecutionPlan, type_id: int, incoming: [__graphql.Selection]) -> int {\n    for i in 0..len(plan.expansions) {\n        let entry = plan.expansions[i];\n        if entry.type_id == type_id && graphql_same_selection_list(entry.incoming, incoming) { return i; }\n    }\n    return -1;\n}\n\n")
	for _, field := range argFields {
		fmt.Fprintf(&b, "fn graphql_args_index_%s_%s(plan: graphql_ExecutionPlan, selection: __graphql.Selection) -> int {\n", field.object, field.field)
		fmt.Fprintf(&b, "    for i in 0..len(plan.%s) {\n", argsPlanField(field))
		fmt.Fprintf(&b, "        let planned = plan.%s[i].selection;\n", argsPlanField(field))
		b.WriteString("        if planned.name.start == selection.name.start && planned.name.end == selection.name.end && planned.alias.start == selection.alias.start && planned.alias.end == selection.alias.end { return i; }\n")
		b.WriteString("    }\n    return -1;\n}\n\n")
	}
	b.WriteString("// A caller-owned parsed operation. Keep one handle per persisted operation.\n")
	b.WriteString("pub gc struct graphql_PreparedQuery { document: __graphql.Document, operation: __graphql.Operation, limits: __graphql.Limits }\n")
	b.WriteString("struct graphql_ParsedQuery { document: __graphql.Document, operation: __graphql.Operation }\n\n")
	b.WriteString("fn graphql_parse_query(query: str, operation_name: str, limits: __graphql.Limits) -> result[graphql_ParsedQuery, str] {\n")
	b.WriteString("    let planned = __graphql.plan_uncached(query, operation_name, limits, graphql_schema_has_object_type);\n")
	b.WriteString("    guard let plan = planned else let e = err_of(planned) { return err(e); }\n")
	b.WriteString("    return ok(graphql_ParsedQuery { document: plan.document, operation: plan.operation });\n}\n\n")
	b.WriteString("pub fn graphql_prepare(query: str, operation_name: str, limits: __graphql.Limits) -> result[graphql_PreparedQuery, str] {\n")
	b.WriteString("    let parsed_result = graphql_parse_query(query, operation_name, limits);\n")
	b.WriteString("    guard let parsed = parsed_result else let e = err_of(parsed_result) { return err(e); }\n")
	b.WriteString("    return ok(graphql_PreparedQuery { document: parsed.document, operation: parsed.operation, limits: limits });\n}\n\n")
	fmt.Fprintf(&b, "pub fn graphql_execute(query: str, operation_name: str, variables_json: bytes, context: %s, limits: __graphql.Limits) -> result[bytes, str] {\n", contextType)
	b.WriteString("    let parsed_result = graphql_parse_query(query, operation_name, limits);\n")
	b.WriteString("    guard let parsed = parsed_result else let e = err_of(parsed_result) { return __graphql.failure(e, limits); }\n")
	b.WriteString("    return graphql_execute_document(parsed.document, parsed.operation, variables_json, context, limits);\n}\n\n")
	fmt.Fprintf(&b, "pub fn graphql_execute_prepared(prepared: graphql_PreparedQuery, variables_json: bytes, context: %s) -> result[bytes, str] {\n", contextType)
	b.WriteString("    return graphql_execute_document(prepared.document, prepared.operation, variables_json, context, prepared.limits);\n}\n\n")
	b.WriteString("// graphql_execute with each query's plan (parse, type conditions, validated\n")
	b.WriteString("// operation) kept in a caller-owned __graphql.PlanCache, keyed by the query\n")
	b.WriteString("// text: for clients that resend the same query without persisting it.\n")
	fmt.Fprintf(&b, "pub fn graphql_execute_cached(cache: __graphql.PlanCache, query: str, operation_name: str, variables_json: bytes, context: %s, limits: __graphql.Limits) -> result[bytes, str] {\n", contextType)
	b.WriteString("    let planned = __graphql.plan(cache, query, operation_name, limits, graphql_schema_has_object_type);\n")
	b.WriteString("    guard let plan = planned else let e = err_of(planned) { return __graphql.failure(e, limits); }\n")
	b.WriteString("    return graphql_execute_document(plan.document, plan.operation, variables_json, context, limits);\n}\n\n")
	fmt.Fprintf(&b, "fn graphql_execute_document(doc: __graphql.Document, operation: __graphql.Operation, variables_json: bytes, context: %s, limits: __graphql.Limits) -> result[bytes, str] {\n", contextType)
	b.WriteString("    let variables_result = __graphql.parse_variables(variables_json, limits);\n")
	b.WriteString("    guard let variables = variables_result else let e = err_of(variables_result) { return __graphql.failure(e, limits); }\n")
	b.WriteString("    let errors_result = __graphql.errors_new(100);\n")
	b.WriteString("    guard let errors = errors_result else let e = err_of(errors_result) { return err(e); }\n")
	b.WriteString("    let args_plan = graphql_ExecutionPlan {\n        expansions: []")
	if len(argFields) > 0 {
		b.WriteString(",\n")
		for i, field := range argFields {
			comma := ","
			if i == len(argFields)-1 {
				comma = ""
			}
			fmt.Fprintf(&b, "        %s: []%s\n", argsPlanField(field), comma)
		}
	} else {
		b.WriteByte('\n')
	}
	b.WriteString("    };\n")
	b.WriteString("    if operation.kind == __graphql.OP_QUERY {\n")
	b.WriteString("        let validation_budget = __graphql.expansion_budget(limits);\n")
	fmt.Fprintf(&b, "        let checked = graphql_validate_%s(operation.selections, doc, variables, operation, context, limits, args_plan, validation_budget, 0);\n", s.queryRoot)
	b.WriteString("        guard let _valid = checked else let e = err_of(checked) { return __graphql.failure(e, limits); }\n")
	b.WriteString("        let execution_budget = __graphql.expansion_budget(limits);\n")
	fmt.Fprintf(&b, "        let execution = graphql_emit_%s(__graphql.root_new(), operation.selections, doc, variables, operation, context, errors, limits, args_plan, execution_budget, 0);\n", s.queryRoot)
	b.WriteString("        let data = b\"null\";\n")
	b.WriteString("        if let value = execution { data = value; } else let e = err_of(execution) {\n")
	b.WriteString("            if e != \"graphql_nonnull_bubble\" {\n")
	b.WriteString("                let added = __graphql.error_add(errors, \"execution failed\");\n")
	b.WriteString("                guard let _ok = added else let add_error = err_of(added) { return err(add_error); }\n")
	b.WriteString("            }\n        }\n")
	b.WriteString("        return __graphql.execution_response(data, errors, limits);\n    }\n")
	if s.mutRoot != "" {
		b.WriteString("    if operation.kind == __graphql.OP_MUTATION {\n")
		b.WriteString("        let validation_budget = __graphql.expansion_budget(limits);\n")
		fmt.Fprintf(&b, "        let checked = graphql_validate_%s(operation.selections, doc, variables, operation, context, limits, args_plan, validation_budget, 0);\n", s.mutRoot)
		b.WriteString("        guard let _valid = checked else let e = err_of(checked) { return __graphql.failure(e, limits); }\n")
		b.WriteString("        let execution_budget = __graphql.expansion_budget(limits);\n")
		fmt.Fprintf(&b, "        let execution = graphql_emit_%s(__graphql.root_new(), operation.selections, doc, variables, operation, context, errors, limits, args_plan, execution_budget, 0);\n", s.mutRoot)
		b.WriteString("        let data = b\"null\";\n")
		b.WriteString("        if let value = execution { data = value; } else let e = err_of(execution) {\n")
		b.WriteString("            if e != \"graphql_nonnull_bubble\" {\n")
		b.WriteString("                let added = __graphql.error_add(errors, \"execution failed\");\n")
		b.WriteString("                guard let _ok = added else let add_error = err_of(added) { return err(add_error); }\n")
		b.WriteString("            }\n        }\n")
		b.WriteString("        return __graphql.execution_response(data, errors, limits);\n    }\n")
	} else {
		b.WriteString("    if operation.kind == __graphql.OP_MUTATION { return __graphql.failure(\"mutation root is not defined\", limits); }\n")
	}
	b.WriteString("    return __graphql.failure(\"unsupported operation kind\", limits);\n}\n\n")
	b.WriteString("fn graphql_schema_has_object_type(name: str) -> bool {\n")
	for _, d := range s.types {
		if d.kind == "type" {
			fmt.Fprintf(&b, "    if name == %q { return true; }\n", d.name)
		}
	}
	b.WriteString("    return false;\n}\n\n")

	for _, d := range s.types {
		if d.kind != "input" {
			continue
		}
		if err := generateInputNormalizer(&b, s, d); err != nil {
			return "", err
		}
		for _, f := range d.fields {
			if err := generateValueNormalizer(&b, s, "input_"+d.name+"_"+f.name, f.typ); err != nil {
				return "", err
			}
		}
	}
	for _, d := range s.types {
		if d.kind != "type" {
			continue
		}
		for _, f := range d.fields {
			for _, arg := range f.args {
				if err := generateValueNormalizer(&b, s, "arg_"+d.name+"_"+f.name+"_"+arg.name, arg.typ); err != nil {
					return "", err
				}
			}
			if len(f.args) > 0 {
				for _, arg := range f.args {
					if err := generateResolverArg(&b, s, d, f, arg); err != nil {
						return "", err
					}
				}
				generateResolverArgs(&b, d, f)
			}
		}
	}

	for _, d := range s.types {
		if d.kind != "type" {
			continue
		}
		if err := generateValidator(&b, s, d, contextType); err != nil {
			return "", err
		}
		if err := generateEmitter(&b, s, d, contextType); err != nil {
			return "", err
		}
		for _, f := range d.fields {
			if err := generateFieldEncoders(&b, s, d, f, contextType); err != nil {
				return "", err
			}
		}
	}
	return b.String(), nil
}

type executionArgField struct {
	object string
	field  string
}

func executionArgsFields(s *schema) []executionArgField {
	var fields []executionArgField
	for _, d := range s.types {
		if d.kind != "type" {
			continue
		}
		for _, f := range d.fields {
			if len(f.args) > 0 {
				fields = append(fields, executionArgField{object: d.name, field: f.name})
			}
		}
	}
	return fields
}

func argsPlanField(field executionArgField) string {
	return "args_" + field.object + "_" + field.field
}

func argsPlanEntryType(field executionArgField) string {
	return "graphql_ArgsEntry_" + field.object + "_" + field.field
}

func executionObjectID(s *schema, name string) int {
	id := 0
	for _, d := range s.types {
		if d.kind != "type" {
			continue
		}
		if d.name == name {
			return id
		}
		id++
	}
	return -1
}

func generateValidator(b *strings.Builder, s *schema, d typeDef, contextType string) error {
	fmt.Fprintf(b, "fn graphql_validate_%s(incoming: [__graphql.Selection], doc: __graphql.Document, variables: __graphql.Variables, operation: __graphql.Operation, context: %s, limits: __graphql.Limits, args_plan: graphql_ExecutionPlan, budget: __graphql.ExpansionBudget, depth: int) -> result[bool, str] {\n", d.name, contextType)
	b.WriteString("    if depth > limits.max_depth { return err(\"graphql validation: selection depth exceeds configured limit\"); }\n")
	fmt.Fprintf(b, "    let expanded_result = __graphql.collect_selections_budget(doc, incoming, %q, variables, operation, limits, budget);\n", d.name)
	b.WriteString("    guard let selections = expanded_result else let e = err_of(expanded_result) { return err(e); }\n")
	fmt.Fprintf(b, "    push(args_plan.expansions, graphql_ExpansionEntry { type_id: %d, incoming: incoming, expanded: selections });\n", executionObjectID(s, d.name))
	b.WriteString("    let response_names: map[str]bool = {};\n")
	b.WriteString("    for i in 0..len(selections) {\n")
	b.WriteString("        let selection = selections[i];\n")
	b.WriteString("        let response_name = __graphql.response_name(doc, selection);\n")
	b.WriteString("        if has(response_names, response_name) { return err(\"graphql validation: duplicate response name \" + response_name); }\n")
	b.WriteString("        response_names[response_name] = true;\n")
	b.WriteString("        let field_name = __graphql.selection_name(doc, selection);\n")
	b.WriteString("        if field_name == \"__typename\" {\n")
	b.WriteString("            if len(selection.arguments) != 0 || len(selection.children) != 0 { return err(\"graphql validation: __typename takes no arguments or selection set\"); }\n")
	b.WriteString("            continue;\n        }\n")
	for _, f := range d.fields {
		fmt.Fprintf(b, "        if field_name == %q {\n", f.name)
		if len(f.args) > 0 {
			fmt.Fprintf(b, "            let typed_args_result = graphql_resolver_args_%s_%s(doc, selection, variables, operation, limits);\n", d.name, f.name)
			b.WriteString("            guard let typed_args = typed_args_result else let e = err_of(typed_args_result) { return err(e); }\n")
			fmt.Fprintf(b, "            push(args_plan.%s, %s { selection: selection, args: typed_args });\n", argsPlanField(executionArgField{object: d.name, field: f.name}), argsPlanEntryType(executionArgField{object: d.name, field: f.name}))
		} else {
			b.WriteString("            let args_json_result = __graphql.arguments_json(doc, selection, variables, operation, limits, []);\n")
			b.WriteString("            guard let _args_json = args_json_result else let e = err_of(args_json_result) { return err(e); }\n")
		}
		objectName, isObject := s.outputObject(f.typ)
		if isObject {
			b.WriteString("            if len(selection.children) == 0 { return err(\"graphql validation: object field requires a selection set\"); }\n")
			fmt.Fprintf(b, "            let nested = graphql_validate_%s(selection.children, doc, variables, operation, context, limits, args_plan, budget, depth + 1);\n", objectName)
			b.WriteString("            guard let _nested_ok = nested else let e = err_of(nested) { return err(e); }\n")
		} else {
			b.WriteString("            if len(selection.children) != 0 { return err(\"graphql validation: scalar field cannot have a selection set\"); }\n")
		}
		b.WriteString("            continue;\n        }\n")
	}
	b.WriteString("        return err(\"graphql validation: unknown field \" + field_name + \" on \" + ")
	fmt.Fprintf(b, "%q);\n", d.name)
	b.WriteString("    }\n    return ok(true);\n}\n\n")
	return nil
}

func generateEmitter(b *strings.Builder, s *schema, d typeDef, contextType string) error {
	parent := resolverParentType(s, d.name)
	fmt.Fprintf(b, "fn graphql_emit_%s(parent: %s, incoming: [__graphql.Selection], doc: __graphql.Document, variables: __graphql.Variables, operation: __graphql.Operation, context: %s, errors: __graphql.Errors, limits: __graphql.Limits, args_plan: graphql_ExecutionPlan, budget: __graphql.ExpansionBudget, depth: int) -> result[bytes, str] {\n", d.name, parent, contextType)
	b.WriteString("    if depth > limits.max_depth { return err(\"graphql execution: selection depth exceeds configured limit\"); }\n")
	fmt.Fprintf(b, "    let expansion_index = graphql_expansion_index(args_plan, %d, incoming);\n", executionObjectID(s, d.name))
	b.WriteString("    if expansion_index < 0 { return err(\"graphql execution: validated selection expansion is missing\"); }\n")
	b.WriteString("    let selections = args_plan.expansions[expansion_index].expanded;\n")
	b.WriteString("    if !__graphql.charge_expanded_selection_budget(selections, budget) { return err(\"graphql validation: expanded selection count exceeds configured limit\"); }\n")
	b.WriteString("    let out = builder.new_bytes();\n    out.write_byte(123);\n")
	b.WriteString("    let written = 0;\n")
	b.WriteString("    for i in 0..len(selections) {\n")
	b.WriteString("        let selection = selections[i];\n")
	b.WriteString("        let field_name = __graphql.selection_name(doc, selection);\n")
	b.WriteString("        let response_name = __graphql.response_name(doc, selection);\n")
	b.WriteString("        if written > 0 { out.write_byte(44); }\n")
	b.WriteString("        let key_result = __graphql.write_json_string_bounded(out, response_name, limits.max_response_bytes);\n")
	b.WriteString("        guard let _key_ok = key_result else let e = err_of(key_result) { return err(e); }\n")
	b.WriteString("        out.write_byte(58);\n")
	b.WriteString("        if field_name == \"__typename\" {\n")
	// The query type name is a static SDL name and the GraphQL lexer limits it to ASCII.
	b.WriteString("            let typename_result = __graphql.write_json_string_bounded(out, ")
	fmt.Fprintf(b, "%q, limits.max_response_bytes);\n", d.name)
	b.WriteString("            guard let _typename_ok = typename_result else let e = err_of(typename_result) { return err(e); }\n")
	b.WriteString("            if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n")
	b.WriteString("            written = written + 1;\n            continue;\n        }\n")
	for _, f := range d.fields {
		fmt.Fprintf(b, "        if field_name == %q {\n", f.name)
		if len(f.args) > 0 {
			field := executionArgField{object: d.name, field: f.name}
			fmt.Fprintf(b, "            let args_index = graphql_args_index_%s_%s(args_plan, selection);\n", d.name, f.name)
			b.WriteString("            if args_index < 0 { return err(\"graphql execution: validated arguments are missing\"); }\n")
			fmt.Fprintf(b, "            let args = args_plan.%s[args_index].args;\n", argsPlanField(field))
		} else {
			b.WriteString("            let args = __graphql.no_args();\n")
		}
		fmt.Fprintf(b, "            let resolved_result = graphql_call_%s_%s(parent, args, context);\n", d.name, f.name)
		b.WriteString("            guard let resolved = resolved_result else let _resolver_error = err_of(resolved_result) {\n")
		b.WriteString("                let added = __graphql.error_add(errors, \"resolver failed\");\n")
		b.WriteString("                guard let _added = added else let e = err_of(added) { return err(e); }\n")
		if f.typ.nonNull {
			b.WriteString("                return err(\"graphql_nonnull_bubble\");\n")
		} else {
			b.WriteString("                out.write(b\"null\");\n")
			b.WriteString("                if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n")
			b.WriteString("                written = written + 1;\n                continue;\n")
		}
		b.WriteString("            }\n")
		fmt.Fprintf(b, "            let encoded_result = graphql_encode_%s_%s_0(resolved, selection, doc, variables, operation, context, errors, limits, args_plan, budget, depth);\n", d.name, f.name)
		b.WriteString("            guard let encoded = encoded_result else let e = err_of(encoded_result) {\n")
		b.WriteString("                if e != \"graphql_nonnull_bubble\" {\n")
		b.WriteString("                    let added = __graphql.error_add(errors, \"result could not be encoded\");\n")
		b.WriteString("                    guard let _added = added else let add_error = err_of(added) { return err(add_error); }\n")
		b.WriteString("                }\n")
		if f.typ.nonNull {
			b.WriteString("                return err(\"graphql_nonnull_bubble\");\n")
		} else {
			b.WriteString("                out.write(b\"null\");\n")
			b.WriteString("                if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n")
			b.WriteString("                written = written + 1;\n                continue;\n")
		}
		b.WriteString("            }\n")
		b.WriteString("            out.write(encoded);\n")
		b.WriteString("            if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n")
		b.WriteString("            written = written + 1;\n            continue;\n        }\n")
	}
	b.WriteString("        return err(\"graphql execution: validated field has no generated resolver\");\n    }\n")
	b.WriteString("    out.write_byte(125);\n")
	b.WriteString("    if out.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n")
	b.WriteString("    return ok(out.finish());\n}\n\n")
	return nil
}

func generateFieldEncoders(b *strings.Builder, s *schema, object typeDef, field fieldDef, contextType string) error {
	for t, level := field.typ, 0; ; t, level = t.inner, level+1 {
		typeName, err := s.slangType(t)
		if err != nil {
			return err
		}
		fmt.Fprintf(b, "fn graphql_encode_%s_%s_%d(value: %s, selection: __graphql.Selection, doc: __graphql.Document, variables: __graphql.Variables, operation: __graphql.Operation, context: %s, errors: __graphql.Errors, limits: __graphql.Limits, args_plan: graphql_ExecutionPlan, budget: __graphql.ExpansionBudget, depth: int) -> result[bytes, str] {\n", object.name, field.name, level, typeName, contextType)
		valueName := "value"
		if !t.nonNull {
			valueName = fmt.Sprintf("unwrapped_%d", level)
			fmt.Fprintf(b, "    guard let %s = value else { return ok(b\"null\"); }\n", valueName)
		}
		if t.list {
			fmt.Fprintf(b, "    if len(%s) > limits.max_breadth { return err(\"graphql response list exceeds configured breadth\"); }\n", valueName)
			fmt.Fprintf(b, "    let out_%d = builder.new_bytes();\n    out_%d.write_byte(91);\n", level, level)
			fmt.Fprintf(b, "    for index_%d in 0..len(%s) {\n", level, valueName)
			fmt.Fprintf(b, "        if index_%d > 0 { out_%d.write_byte(44); }\n", level, level)
			fmt.Fprintf(b, "        let item_result_%d = graphql_encode_%s_%s_%d(%s[index_%d], selection, doc, variables, operation, context, errors, limits, args_plan, budget, depth);\n", level, object.name, field.name, level+1, valueName, level)
			fmt.Fprintf(b, "        guard let item_%d = item_result_%d else let e = err_of(item_result_%d) {\n", level, level, level)
			b.WriteString("            if e != \"graphql_nonnull_bubble\" {\n")
			b.WriteString("                let added = __graphql.error_add(errors, \"result could not be encoded\");\n")
			b.WriteString("                guard let _added = added else let add_error = err_of(added) { return err(add_error); }\n")
			b.WriteString("            }\n")
			if t.inner.nonNull {
				b.WriteString("            return err(\"graphql_nonnull_bubble\");\n")
			} else {
				fmt.Fprintf(b, "            out_%d.write(b\"null\");\n", level)
				fmt.Fprintf(b, "            if out_%d.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n            continue;\n", level)
			}
			fmt.Fprintf(b, "        }\n        out_%d.write(item_%d);\n", level, level)
			fmt.Fprintf(b, "        if out_%d.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n", level)
			fmt.Fprintf(b, "    }\n    out_%d.write_byte(93);\n    if out_%d.size() > limits.max_response_bytes { return err(\"graphql response exceeds configured byte limit\"); }\n    return ok(out_%d.finish());\n}\n\n", level, level, level)
			continue
		}
		if typeName, isObject := s.outputObject(t); isObject {
			fmt.Fprintf(b, "    let encoded_result = graphql_emit_%s(%s, selection.children, doc, variables, operation, context, errors, limits, args_plan, budget, depth + 1);\n", typeName, valueName)
			fmt.Fprintf(b, "    guard let encoded = encoded_result else let e = err_of(encoded_result) {\n")
			b.WriteString("        if e != \"graphql_nonnull_bubble\" {\n")
			b.WriteString("            let added = __graphql.error_add(errors, \"result could not be encoded\");\n")
			b.WriteString("            guard let _added = added else let add_error = err_of(added) { return err(add_error); }\n")
			b.WriteString("        }\n")
			if t.nonNull {
				b.WriteString("        return err(\"graphql_nonnull_bubble\");\n")
			} else {
				b.WriteString("        return ok(b\"null\");\n")
			}
			b.WriteString("    }\n    return ok(encoded);\n}\n\n")
		} else if t.name == "String" || t.name == "ID" {
			fmt.Fprintf(b, "    if len(%s) > limits.max_response_bytes { return err(\"graphql response string exceeds configured byte limit\"); }\n", valueName)
			b.WriteString("    let out = builder.new_bytes();\n")
			fmt.Fprintf(b, "    let written = __graphql.write_json_string_bounded(out, %s, limits.max_response_bytes);\n", valueName)
			b.WriteString("    guard let _written = written else let e = err_of(written) { return err(e); }\n")
			b.WriteString("    if out.size() > limits.max_response_bytes { return err(\"graphql response string exceeds configured byte limit\"); }\n")
			b.WriteString("    return ok(out.finish());\n}\n\n")
		} else if t.name == "Int" {
			fmt.Fprintf(b, "    if %s < -2147483648 || %s > 2147483647 { return err(\"graphql Int result is outside the signed 32-bit range\"); }\n", valueName, valueName)
			fmt.Fprintf(b, "    let encoded = json.encode(%s);\n    return ok(to_bytes(encoded));\n}\n\n", valueName)
		} else {
			fmt.Fprintf(b, "    let encoded = json.encode(%s);\n    return ok(to_bytes(encoded));\n}\n\n", valueName)
		}
		break
	}
	return nil
}

func generateInputNormalizer(b *strings.Builder, s *schema, d typeDef) error {
	fmt.Fprintf(b, "fn graphql_normalize_input_%s(raw: bytes, limits: __graphql.Limits, depth: int) -> result[bytes, str] {\n", d.name)
	b.WriteString("    if depth > limits.max_depth { return err(\"graphql validation: input object depth exceeds configured limit\"); }\n")
	fmt.Fprintf(b, "    let parsed_result = __graphql.parse_input_object(raw, limits);\n")
	b.WriteString("    guard let fields = parsed_result else let e = err_of(parsed_result) { return err(e); }\n")
	allowed := make([]string, 0, len(d.fields))
	for _, field := range d.fields {
		allowed = append(allowed, strconv.Quote(field.name))
	}
	fmt.Fprintf(b, "    let known_result = __graphql.validate_object_keys(fields, [%s]);\n", strings.Join(allowed, ", "))
	b.WriteString("    guard let _known = known_result else let e = err_of(known_result) { return err(e); }\n")
	b.WriteString("    let out = builder.new_bytes();\n    out.write_byte(123);\n")
	b.WriteString("    let written = 0;\n")
	for i, field := range d.fields {
		keyBytes := "b" + strconv.Quote(`"`+field.name+`":`)
		fmt.Fprintf(b, "    let value_result_%d = __graphql.variables_get(fields, %q);\n", i, field.name)
		fmt.Fprintf(b, "    if let raw_value_%d = value_result_%d {\n", i, i)
		fmt.Fprintf(b, "        let normalized_result_%d = graphql_normalize_input_%s_%s_0(raw_value_%d, limits, depth + 1);\n", i, d.name, field.name, i)
		fmt.Fprintf(b, "        guard let normalized_%d = normalized_result_%d else let e = err_of(normalized_result_%d) { return err(e); }\n", i, i, i)
		fmt.Fprintf(b, "        if written > 0 { out.write_byte(44); }\n        out.write(%s);\n        out.write(normalized_%d);\n        written = written + 1;\n", keyBytes, i)
		b.WriteString("    } else {\n")
		if field.hasDefault {
			defaultValue, err := valueJSON(field.def)
			if err != nil {
				return err
			}
			fmt.Fprintf(b, "        if written > 0 { out.write_byte(44); }\n        out.write(%s);\n        out.write(b%s);\n        written = written + 1;\n", keyBytes, strconv.Quote(defaultValue))
		} else if field.typ.nonNull {
			fmt.Fprintf(b, "        return err(\"graphql validation: required input field %s.%s is missing\");\n", d.name, field.name)
		}
		b.WriteString("    }\n")
	}
	b.WriteString("    out.write_byte(125);\n")
	b.WriteString("    if out.size() > limits.max_response_bytes { return err(\"graphql validation: normalized input exceeds byte limit\"); }\n")
	b.WriteString("    return ok(out.finish());\n}\n\n")
	return nil
}

func generateValueNormalizer(b *strings.Builder, s *schema, prefix string, typ *typeRef) error {
	for t, level := typ, 0; ; t, level = t.inner, level+1 {
		name := fmt.Sprintf("graphql_normalize_%s_%d", prefix, level)
		fmt.Fprintf(b, "fn %s(raw: bytes, limits: __graphql.Limits, depth: int) -> result[bytes, str] {\n", name)
		b.WriteString("    if len(raw) == 0 { return err(\"graphql validation: missing input value\"); }\n")
		if !t.nonNull {
			b.WriteString("    if raw == b\"null\" { return ok(raw); }\n")
		} else {
			fmt.Fprintf(b, "    if raw == b\"null\" { return err(%q); }\n", "graphql validation: null for non-null input value")
		}
		if t.list {
			b.WriteString("    if raw[0] != 91 {\n")
			fmt.Fprintf(b, "        let item_result = graphql_normalize_%s_%d(raw, limits, depth + 1);\n", prefix, level+1)
			b.WriteString("        guard let item = item_result else let e = err_of(item_result) { return err(e); }\n")
			b.WriteString("        let one = builder.new_bytes();\n        one.write_byte(91);\n        one.write(item);\n        one.write_byte(93);\n        return ok(one.finish());\n    }\n")
			b.WriteString("    let items_result = __graphql.json_array_values(raw, limits);\n")
			b.WriteString("    guard let items = items_result else let e = err_of(items_result) { return err(e); }\n")
			b.WriteString("    let out = builder.new_bytes();\n    out.write_byte(91);\n")
			b.WriteString("    for i in 0..len(items) {\n        if i > 0 { out.write_byte(44); }\n")
			fmt.Fprintf(b, "        let item_result = graphql_normalize_%s_%d(items[i], limits, depth + 1);\n", prefix, level+1)
			b.WriteString("        guard let item = item_result else let e = err_of(item_result) { return err(e); }\n        out.write(item);\n")
			b.WriteString("    }\n    out.write_byte(93);\n")
			b.WriteString("    if out.size() > limits.max_response_bytes { return err(\"graphql validation: normalized list exceeds byte limit\"); }\n")
			b.WriteString("    return ok(out.finish());\n}\n\n")
			continue
		}
		index, exists := s.definitions[t.name]
		if exists && s.types[index].kind == "input" {
			fmt.Fprintf(b, "    return graphql_normalize_input_%s(raw, limits, depth + 1);\n}\n\n", t.name)
		} else if t.name == "Int" {
			b.WriteString("    return __graphql.normalize_int32(raw);\n}\n\n")
		} else if t.name == "ID" {
			b.WriteString("    return __graphql.normalize_id(raw);\n}\n\n")
		} else {
			b.WriteString("    return ok(raw);\n}\n\n")
		}
		break
	}
	return nil
}

func generateResolverArg(b *strings.Builder, s *schema, object typeDef,
	field fieldDef, arg inputValue) error {
	typeName, err := s.slangType(arg.typ)
	if err != nil {
		return fmt.Errorf("%s.%s(%s): %w", object.name, field.name, arg.name, err)
	}
	name := "graphql_resolver_arg_" + object.name + "_" + field.name + "_" + arg.name
	fmt.Fprintf(b, "fn %s(doc: __graphql.Document, selection: __graphql.Selection, variables: __graphql.Variables, operation: __graphql.Operation, limits: __graphql.Limits) -> result[%s, str] {\n", name, typeName)
	fmt.Fprintf(b, "    let found = __graphql.find_argument(doc, selection, %q);\n", arg.name)
	b.WriteString("    let raw = b\"\";\n")
	b.WriteString("    if let _ = found {\n")
	b.WriteString("        guard let argument = found else { return err(\"graphql validation: argument lookup failed\"); }\n")
	fmt.Fprintf(b, "        let variable_type = __graphql.validate_variable_type(doc, operation, argument.value, %q, %t);\n", arg.typ.String(), arg.hasDef)
	b.WriteString("        guard let _type_ok = variable_type else let e = err_of(variable_type) { return err(e); }\n")
	b.WriteString("        if __graphql.variable_missing(doc, argument.value, variables, operation) {\n")
	if arg.hasDef {
		defaultValue, err := valueJSON(arg.def)
		if err != nil {
			return err
		}
		fmt.Fprintf(b, "            raw = b%s;\n", strconv.Quote(defaultValue))
	} else if arg.typ.nonNull {
		fmt.Fprintf(b, "            return err(%q);\n", "graphql validation: required variable for argument "+arg.name+" is missing")
	} else {
		b.WriteString("            return ok(none);\n")
	}
	b.WriteString("        } else {\n")
	b.WriteString("            let value_result = __graphql.value_json(doc, argument.value, variables, operation, limits);\n")
	b.WriteString("            guard let value = value_result else let e = err_of(value_result) { return err(e); }\n")
	b.WriteString("            raw = value;\n        }\n")
	b.WriteString("    } else {\n")
	if arg.hasDef {
		defaultValue, err := valueJSON(arg.def)
		if err != nil {
			return err
		}
		fmt.Fprintf(b, "        raw = b%s;\n", strconv.Quote(defaultValue))
	} else if arg.typ.nonNull {
		fmt.Fprintf(b, "        return err(%q);\n", "graphql validation: required argument "+arg.name+" is missing")
	} else {
		b.WriteString("        return ok(none);\n")
	}
	b.WriteString("    }\n")
	fmt.Fprintf(b, "    let normalized_result = graphql_normalize_arg_%s_%s_%s_0(raw, limits, 0);\n", object.name, field.name, arg.name)
	b.WriteString("    guard let normalized = normalized_result else let e = err_of(normalized_result) { return err(e); }\n")
	fmt.Fprintf(b, "    let typed_result: result[%s, str] = json.decode(normalized);\n    return typed_result;\n}\n\n", typeName)
	return nil
}

func generateResolverArgs(b *strings.Builder, object typeDef, field fieldDef) {
	fmt.Fprintf(b, "fn graphql_resolver_args_%s_%s(doc: __graphql.Document, selection: __graphql.Selection, variables: __graphql.Variables, operation: __graphql.Operation, limits: __graphql.Limits) -> result[%s, str] {\n", object.name, field.name, argsTypeName(object.name, field.name))
	b.WriteString("    for i in 0..len(selection.arguments) {\n")
	b.WriteString("        let actual = __graphql.span_text(doc.source, selection.arguments[i].name);\n")
	for _, arg := range field.args {
		fmt.Fprintf(b, "        if actual == %q { continue; }\n", arg.name)
	}
	b.WriteString("        return err(\"graphql validation: unknown argument \" + actual);\n    }\n")
	for i, arg := range field.args {
		fmt.Fprintf(b, "    let arg_result_%d = graphql_resolver_arg_%s_%s_%s(doc, selection, variables, operation, limits);\n", i, object.name, field.name, arg.name)
		fmt.Fprintf(b, "    guard let arg_%d = arg_result_%d else let e = err_of(arg_result_%d) { return err(e); }\n", i, i, i)
	}
	fmt.Fprintf(b, "    return ok(%s {\n", argsTypeName(object.name, field.name))
	for i, arg := range field.args {
		comma := ","
		if i == len(field.args)-1 {
			comma = ""
		}
		fmt.Fprintf(b, "        %s: arg_%d%s\n", arg.name, i, comma)
	}
	b.WriteString("    });\n}\n\n")
}

func argumentSpecs(s *schema, field fieldDef) string {
	if len(field.args) == 0 {
		return "[]"
	}
	items := make([]string, 0, len(field.args))
	for _, arg := range field.args {
		defaultJSON := "b\"\""
		if arg.hasDef {
			value, _ := valueJSON(arg.def)
			defaultJSON = "b" + strconv.Quote(value)
		}
		required := arg.typ.nonNull && !arg.hasDef
		items = append(items, fmt.Sprintf("__graphql.ArgSpec { name: %q, type_ref: %q, required: %t, has_default: %t, default_json: %s }",
			arg.name, arg.typ.String(), required, arg.hasDef, defaultJSON))
	}
	return "[" + strings.Join(items, ", ") + "]"
}

func (s *schema) outputObject(t *typeRef) (string, bool) {
	for t.list {
		t = t.inner
	}
	index, ok := s.definitions[t.name]
	if !ok || s.types[index].kind != "type" {
		return "", false
	}
	return t.name, true
}
