package repository

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Delivery statuses.
const (
	DeliveryPending = "pending"
	DeliverySent    = "sent"
	DeliveryFailed  = "failed"
)

// DeliveryRepository is the record of which message has already been pushed to
// which device.
type DeliveryRepository struct {
	db *sql.DB
}

func NewDeliveryRepository(db *sql.DB) *DeliveryRepository {
	return &DeliveryRepository{db: db}
}

// Claim reserves one (user, device, message) push and reports whether this
// caller is the one that got it. Zulip redelivers events whose acknowledgement
// was lost, so without this a flaky connection turns into duplicate pushes.
func (r *DeliveryRepository) Claim(ctx context.Context, userID int64, deviceID string, messageID int64, trigger string) (bool, error) {
	const query = `INSERT OR IGNORE INTO deliveries (user_id, device_id, message_id, trigger, status)
		VALUES (?, ?, ?, ?, ?)`
	result, err := r.db.ExecContext(ctx, query, userID, deviceID, messageID, trigger, DeliveryPending)
	if err != nil {
		return false, fmt.Errorf("repository: claim delivery: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("repository: claim delivery: %w", err)
	}
	return affected == 1, nil
}

func (r *DeliveryRepository) Complete(ctx context.Context, userID int64, deviceID string, messageID int64, status, detail string) error {
	const query = `UPDATE deliveries SET status = ?, detail = ?
		WHERE user_id = ? AND device_id = ? AND message_id = ?`
	if _, err := r.db.ExecContext(ctx, query, status, detail, userID, deviceID, messageID); err != nil {
		return fmt.Errorf("repository: complete delivery: %w", err)
	}
	return nil
}

// Release drops a claim so a later attempt can retry the same message.
func (r *DeliveryRepository) Release(ctx context.Context, userID int64, deviceID string, messageID int64) error {
	const query = `DELETE FROM deliveries WHERE user_id = ? AND device_id = ? AND message_id = ?`
	if _, err := r.db.ExecContext(ctx, query, userID, deviceID, messageID); err != nil {
		return fmt.Errorf("repository: release delivery: %w", err)
	}
	return nil
}

// Prune keeps the log from growing without bound. Rows older than a Zulip queue
// can possibly redeliver are no longer doing any deduplication work.
func (r *DeliveryRepository) Prune(ctx context.Context, before time.Time) (int64, error) {
	const query = `DELETE FROM deliveries WHERE created_at < ?`
	result, err := r.db.ExecContext(ctx, query, formatTime(before))
	if err != nil {
		return 0, fmt.Errorf("repository: prune deliveries: %w", err)
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("repository: prune deliveries: %w", err)
	}
	return deleted, nil
}
