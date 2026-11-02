// Command magnife-ingest receives OTLP on 127.0.0.1 and writes it to
// magnife.sqlite. The Magnife app starts it as a child process; see the
// "Helper protocol" section of docs/schema.sql.
package main

import (
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"

	"magnife/ingest/internal/helper"
)

func defaultDB() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "magnife.sqlite"
	}
	return filepath.Join(home, "Library", "Application Support", "Magnife", "magnife.sqlite")
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	var cfg helper.Config
	fs := flag.NewFlagSet("magnife-ingest", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&cfg.DBPath, "db", defaultDB(), "SQLite database `path` (its directory is created)")
	fs.StringVar(&cfg.GRPCAddr, "grpc", "127.0.0.1:4317", "OTLP/gRPC listen `address` (loopback only)")
	fs.StringVar(&cfg.HTTPAddr, "http", "127.0.0.1:4318", "OTLP/HTTP listen `address` (loopback only)")
	fs.Int64Var(&cfg.RetentionS, "retention", 86400, "keep traces and logs this many `seconds`")
	fs.BoolVar(&cfg.NoStdin, "no-stdin", false, "do not read stdin or exit on its EOF; stop with SIGINT or SIGTERM (for running without the app)")
	verbose := fs.Bool("v", false, "verbose logging on stderr")
	fs.Usage = func() {
		fmt.Fprintf(stderr, "usage: magnife-ingest [flags]\n\nProtocol lines go to stdout, logs to stderr. Exits when stdin closes, unless --no-stdin.\n\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: level})))
	return helper.Run(cfg, stdin, stdout)
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
