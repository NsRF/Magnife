// Package store owns magnife.sqlite: it applies the schema from
// docs/schema.sql and writes batches of spans and logs in one transaction.
package store

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"modernc.org/sqlite"
)

// SchemaSQL is a byte-for-byte copy of docs/schema.sql (checked by a test).
//
//go:embed schema.sql
var SchemaSQL string

// SchemaVersion is the PRAGMA user_version this helper writes.
const SchemaVersion = 1

// driverName is modernc's driver with persistent WAL on every connection.
// SQLite deletes the -wal file when the last connection closes, and the app's
// read-only connection cannot open a WAL database without it, so after a quit
// the app would wait for the helper before it could show stored traces. With
// SQLITE_FCNTL_PERSIST_WAL the checkpointed -wal (and -shm) stay, and the app
// reads the database at launch, before the helper is up (S-008).
const driverName = "magnife-sqlite"

var registerDriver sync.Once

func register() {
	registerDriver.Do(func() {
		d := &sqlite.Driver{}
		d.RegisterConnectionHook(func(c sqlite.ExecQuerierContext, _ string) error {
			fc, ok := c.(sqlite.FileControl)
			if !ok {
				return errors.New("sqlite connection has no file control")
			}
			if _, err := fc.FileControlPersistWAL("main", 1); err != nil {
				return fmt.Errorf("persist WAL: %w", err)
			}
			return nil
		})
		sql.Register(driverName, d)
	})
}

// Store is the single writer of the database. It is not safe for concurrent
// use; the Writer goroutine owns it.
type Store struct {
	db      *sql.DB
	lastSeq int64

	// Now returns the wall clock in Unix nanoseconds; tests replace it.
	Now func() int64

	resourceIDs map[string]int64 // resources are never deleted, so the cache stays valid
	stmts       statements
}

// Open creates the directory and the database if needed, applies the schema
// and sets meta schema_version.
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create database directory: %w", err)
	}
	q := url.Values{}
	// A 16 MiB page cache commits as fast as 64 MiB (BenchmarkCommit) and keeps
	// the helper near 55 MB at 5,000 spans/s instead of 160 MB.
	for _, p := range []string{"journal_mode(WAL)", "synchronous(NORMAL)", "foreign_keys(OFF)", "busy_timeout(5000)", "cache_size(-16384)", "temp_store(MEMORY)"} {
		q.Add("_pragma", p)
	}
	q.Set("_txlock", "immediate")
	register()
	db, err := sql.Open(driverName, "file:"+path+"?"+q.Encode())
	if err != nil {
		return nil, err
	}
	// One connection: every statement runs on the writer goroutine anyway, and
	// a single connection keeps prepared statements and temp state in one place.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)

	s := &Store{db: db, Now: func() int64 { return time.Now().UnixNano() }, resourceIDs: map[string]int64{}}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	if err := s.stmts.prepare(db); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate() error {
	ctx := context.Background()
	var mode string
	if err := s.db.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&mode); err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	if mode != "wal" {
		return fmt.Errorf("open database: journal_mode is %q, want wal", mode)
	}
	var version int
	if err := s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version > SchemaVersion {
		return fmt.Errorf("database schema version %d is newer than this helper (%d)", version, SchemaVersion)
	}
	if _, err := s.db.ExecContext(ctx, SchemaSQL); err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}
	if _, err := s.db.ExecContext(ctx,
		"INSERT INTO meta (key, value) VALUES ('schema_version', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
		strconv.Itoa(SchemaVersion)); err != nil {
		return err
	}
	var last sql.NullString
	err := s.db.QueryRowContext(ctx, "SELECT value FROM meta WHERE key = 'last_seq'").Scan(&last)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if last.Valid {
		// Seqs keep growing across helper restarts, so "first_seq > paused seq" stays true.
		s.lastSeq, _ = strconv.ParseInt(last.String, 10, 64)
	}
	return nil
}

// LastSeq is the seq of the last committed batch.
func (s *Store) LastSeq() int64 { return s.lastSeq }

// DB exposes the handle for tests and read-only queries.
func (s *Store) DB() *sql.DB { return s.db }

// SetMeta writes one meta key.
func (s *Store) SetMeta(key, value string) error {
	_, err := s.db.Exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, value)
	return err
}

// Close closes the database, which checkpoints the WAL. The -wal and -shm
// files stay (persistent WAL), so a read-only reader can open it afterwards.
func (s *Store) Close() error {
	s.stmts.close()
	return s.db.Close()
}
