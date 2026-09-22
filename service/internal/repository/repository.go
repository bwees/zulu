// Package repository is the only place that talks SQL.
package repository

import (
	"errors"
	"time"
)

// ErrNotFound is returned instead of sql.ErrNoRows so callers above this layer
// do not have to import database/sql.
var ErrNotFound = errors.New("repository: not found")

const timeLayout = "2006-01-02 15:04:05"

// SQLite stores these timestamps as `datetime('now')` strings, which are UTC
// without a zone marker.
func parseTime(value string) time.Time {
	parsed, err := time.Parse(timeLayout, value)
	if err != nil {
		return time.Time{}
	}
	return parsed.UTC()
}

func formatTime(value time.Time) string {
	return value.UTC().Format(timeLayout)
}
