package repository

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/notify"
)

// QueueRepository persists each worker's event queue cursor and the settings
// mirror that belongs to it.
type QueueRepository struct {
	db *sql.DB
}

func NewQueueRepository(db *sql.DB) *QueueRepository {
	return &QueueRepository{db: db}
}

func (r *QueueRepository) Load(ctx context.Context, userID int64) (domain.QueueState, error) {
	const query = `SELECT queue_id, last_event_id, state, updated_at FROM queue_state WHERE user_id = ?`
	var (
		queueState domain.QueueState
		raw        string
		updatedAt  string
	)
	err := r.db.QueryRowContext(ctx, query, userID).Scan(&queueState.QueueID, &queueState.LastEventID, &raw, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.QueueState{}, ErrNotFound
	}
	if err != nil {
		return domain.QueueState{}, fmt.Errorf("repository: load queue state: %w", err)
	}

	state := notify.NewState()
	if err := json.Unmarshal([]byte(raw), state); err != nil {
		return domain.QueueState{}, fmt.Errorf("repository: decode queue state: %w", err)
	}
	queueState.State = state
	queueState.UpdatedAt = parseTime(updatedAt)
	return queueState, nil
}

func (r *QueueRepository) Save(ctx context.Context, userID int64, queueState domain.QueueState) error {
	raw, err := json.Marshal(queueState.State)
	if err != nil {
		return fmt.Errorf("repository: encode queue state: %w", err)
	}

	const query = `INSERT INTO queue_state (user_id, queue_id, last_event_id, state)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (user_id) DO UPDATE SET
			queue_id = excluded.queue_id,
			last_event_id = excluded.last_event_id,
			state = excluded.state,
			updated_at = datetime('now')`
	if _, err := r.db.ExecContext(ctx, query, userID, queueState.QueueID, queueState.LastEventID, string(raw)); err != nil {
		return fmt.Errorf("repository: save queue state: %w", err)
	}
	return nil
}

// Advance records progress without rewriting the settings mirror, which is the
// common case: most polls return messages and heartbeats, not settings changes.
func (r *QueueRepository) Advance(ctx context.Context, userID, lastEventID int64) error {
	const query = `UPDATE queue_state SET last_event_id = ?, updated_at = datetime('now') WHERE user_id = ?`
	if _, err := r.db.ExecContext(ctx, query, lastEventID, userID); err != nil {
		return fmt.Errorf("repository: advance queue cursor: %w", err)
	}
	return nil
}

func (r *QueueRepository) Clear(ctx context.Context, userID int64) error {
	if _, err := r.db.ExecContext(ctx, `DELETE FROM queue_state WHERE user_id = ?`, userID); err != nil {
		return fmt.Errorf("repository: clear queue state: %w", err)
	}
	return nil
}
