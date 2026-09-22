// Package database opens the SQLite file and applies the schema.
package database

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"net/url"
	"path/filepath"
	"sort"
	"strings"

	_ "modernc.org/sqlite" // pure-Go driver, so the release image needs no libc
)

//go:embed migrations/*.sql
var migrations embed.FS

// Open returns a connection pool for the SQLite file at path.
//
// The pool is capped at one connection: SQLite takes a single writer anyway, and
// a service this size gains nothing from concurrent readers but would gain
// SQLITE_BUSY retries to handle.
func Open(ctx context.Context, path string) (*sql.DB, error) {
	dsn := dataSourceName(path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("database: open %s: %w", path, err)
	}
	db.SetMaxOpenConns(1)

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("database: ping %s: %w", path, err)
	}
	if err := Migrate(ctx, db); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func dataSourceName(path string) string {
	pragmas := url.Values{}
	pragmas.Add("_pragma", "journal_mode(WAL)")
	pragmas.Add("_pragma", "synchronous(NORMAL)")
	pragmas.Add("_pragma", "foreign_keys(ON)")
	pragmas.Add("_pragma", "busy_timeout(5000)")
	return "file:" + filepath.ToSlash(path) + "?" + pragmas.Encode()
}

// Migrate applies every embedded migration that has not run yet, in file-name
// order.
func Migrate(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		name TEXT PRIMARY KEY,
		applied_at TEXT NOT NULL DEFAULT (datetime('now'))
	)`); err != nil {
		return fmt.Errorf("database: create schema_migrations: %w", err)
	}

	entries, err := migrations.ReadDir("migrations")
	if err != nil {
		return fmt.Errorf("database: read migrations: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		applied, err := isApplied(ctx, db, name)
		if err != nil {
			return err
		}
		if applied {
			continue
		}
		statements, err := migrations.ReadFile("migrations/" + name)
		if err != nil {
			return fmt.Errorf("database: read migration %s: %w", name, err)
		}
		if err := applyMigration(ctx, db, name, string(statements)); err != nil {
			return err
		}
	}
	return nil
}

func isApplied(ctx context.Context, db *sql.DB, name string) (bool, error) {
	var count int
	err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE name = ?`, name).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("database: check migration %s: %w", name, err)
	}
	return count > 0, nil
}

func applyMigration(ctx context.Context, db *sql.DB, name, statements string) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("database: begin migration %s: %w", name, err)
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, statements); err != nil {
		return fmt.Errorf("database: apply migration %s: %w", name, err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations (name) VALUES (?)`, name); err != nil {
		return fmt.Errorf("database: record migration %s: %w", name, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("database: commit migration %s: %w", name, err)
	}
	return nil
}
