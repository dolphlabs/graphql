package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunGeneratesAndChecksDeterministicOutput(t *testing.T) {
	dir := t.TempDir()
	schemaPath := filepath.Join(dir, "schema.graphql")
	outputPath := filepath.Join(dir, "graphql.gen.sl")
	if err := os.WriteFile(schemaPath, []byte(`type Query { ping: String! }`), 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{"-schema", schemaPath, "-out", outputPath}
	var stdout, stderr bytes.Buffer
	if err := run(args, &stdout, &stderr); err != nil {
		t.Fatalf("run() error = %v; stderr: %s", err, stderr.String())
	}
	first, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(first, []byte("graphql_call_Query_ping")) {
		t.Fatalf("generated source lacks resolver wrapper: %s", first)
	}
	stdout.Reset()
	if err := run(append(args, "-check"), &stdout, &stderr); err != nil {
		t.Fatalf("run(-check) error = %v", err)
	}
	if !strings.Contains(stdout.String(), "is current") {
		t.Fatalf("check output = %q", stdout.String())
	}
	if err := os.WriteFile(outputPath, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := run(append(args, "-check"), &stdout, &stderr); err == nil || !strings.Contains(err.Error(), "stale") {
		t.Fatalf("run(stale -check) error = %v", err)
	}
}

func TestRunRejectsOversizedSchemaWithoutWriting(t *testing.T) {
	dir := t.TempDir()
	schemaPath := filepath.Join(dir, "large.graphql")
	outputPath := filepath.Join(dir, "graphql.gen.sl")
	if err := os.WriteFile(schemaPath, bytes.Repeat([]byte{' '}, maxSDLBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	err := run([]string{"-schema", schemaPath, "-out", outputPath}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "schema exceeds") {
		t.Fatalf("run() error = %v, want size limit", err)
	}
	if _, statErr := os.Stat(outputPath); !os.IsNotExist(statErr) {
		t.Fatalf("output should not exist after rejected input; stat error = %v", statErr)
	}
}
