package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const maxSDLBytes = 1 << 20

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "graphqlc:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("graphqlc", flag.ContinueOnError)
	flags.SetOutput(stderr)
	schemaPath := flags.String("schema", "schema.graphql", "GraphQL SDL input file")
	outputPath := flags.String("out", "graphql.gen.sl", "generated slang output file")
	contextType := flags.String("context", "graphql.Context", "Slang resolver context type")
	check := flags.Bool("check", false, "fail if the output file is stale; do not write it")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments; use -schema and -out")
	}

	input, err := os.Open(*schemaPath)
	if err != nil {
		return fmt.Errorf("open schema: %w", err)
	}
	defer input.Close()
	raw, err := io.ReadAll(io.LimitReader(input, maxSDLBytes+1))
	if err != nil {
		return fmt.Errorf("read schema: %w", err)
	}
	if len(raw) > maxSDLBytes {
		return fmt.Errorf("schema exceeds %d-byte limit", maxSDLBytes)
	}
	schema, err := parseSDL(string(raw))
	if err != nil {
		return err
	}
	generated, err := generate(schema, *contextType)
	if err != nil {
		return err
	}
	if *check {
		current, err := os.ReadFile(*outputPath)
		if err != nil {
			return fmt.Errorf("read generated output: %w", err)
		}
		if !bytes.Equal(current, []byte(generated)) {
			return fmt.Errorf("%s is stale; run graphqlc without -check", *outputPath)
		}
		fmt.Fprintln(stdout, "generated output is current")
		return nil
	}
	if err := writeAtomic(*outputPath, []byte(generated)); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "generated %s\n", *outputPath)
	return nil
}

func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".graphqlc-*.tmp")
	if err != nil {
		return fmt.Errorf("create output temporary file: %w", err)
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		tmp.Close()
		if !ok {
			os.Remove(tmpName)
		}
	}()
	if err := tmp.Chmod(0o644); err != nil {
		return fmt.Errorf("set output mode: %w", err)
	}
	if _, err := tmp.Write(data); err != nil {
		return fmt.Errorf("write generated output: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("sync generated output: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close generated output: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("replace generated output: %w", err)
	}
	ok = true
	return nil
}
