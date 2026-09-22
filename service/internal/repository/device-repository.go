package repository

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/bwees/zulu/service/internal/domain"
)

type DeviceRepository struct {
	db *sql.DB
}

func NewDeviceRepository(db *sql.DB) *DeviceRepository {
	return &DeviceRepository{db: db}
}

const deviceColumns = `id, user_id, token, environment, platform, app_version, registered_at, last_seen_at`

// Upsert registers a device. The app re-posts its token on every launch because
// APNs may have reissued it, so this has to be idempotent on (token,
// environment) — and it has to move the row when a token is reassigned to a
// different account on the same handset.
func (r *DeviceRepository) Upsert(ctx context.Context, device domain.Device, secretHash []byte) (domain.Device, error) {
	const query = `INSERT INTO devices (id, user_id, token, environment, platform, app_version, secret_hash)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (token, environment) DO UPDATE SET
			user_id = excluded.user_id,
			platform = excluded.platform,
			app_version = excluded.app_version,
			secret_hash = excluded.secret_hash,
			registered_at = datetime('now'),
			last_seen_at = datetime('now')`
	_, err := r.db.ExecContext(ctx, query,
		device.ID, device.UserID, device.Token, device.Environment, device.Platform, device.AppVersion, secretHash)
	if err != nil {
		return domain.Device{}, fmt.Errorf("repository: upsert device: %w", err)
	}
	return r.getBy(ctx, `token = ? AND environment = ?`, device.Token, device.Environment)
}

func (r *DeviceRepository) Get(ctx context.Context, id string) (domain.Device, error) {
	return r.getBy(ctx, `id = ?`, id)
}

func (r *DeviceRepository) FindBySecretHash(ctx context.Context, secretHash []byte) (domain.Device, error) {
	return r.getBy(ctx, `secret_hash = ?`, secretHash)
}

func (r *DeviceRepository) ListByUser(ctx context.Context, userID int64) ([]domain.Device, error) {
	query := `SELECT ` + deviceColumns + ` FROM devices WHERE user_id = ? ORDER BY registered_at`
	rows, err := r.db.QueryContext(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("repository: list devices: %w", err)
	}
	defer rows.Close()

	var devices []domain.Device
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("repository: list devices: %w", err)
	}
	return devices, nil
}

func (r *DeviceRepository) Delete(ctx context.Context, id string) error {
	if _, err := r.db.ExecContext(ctx, `DELETE FROM devices WHERE id = ?`, id); err != nil {
		return fmt.Errorf("repository: delete device: %w", err)
	}
	return nil
}

func (r *DeviceRepository) TouchLastSeen(ctx context.Context, id string) error {
	const query = `UPDATE devices SET last_seen_at = datetime('now') WHERE id = ?`
	if _, err := r.db.ExecContext(ctx, query, id); err != nil {
		return fmt.Errorf("repository: touch device: %w", err)
	}
	return nil
}

func (r *DeviceRepository) getBy(ctx context.Context, where string, args ...any) (domain.Device, error) {
	query := `SELECT ` + deviceColumns + ` FROM devices WHERE ` + where
	device, err := scanDevice(r.db.QueryRowContext(ctx, query, args...))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Device{}, ErrNotFound
	}
	return device, err
}

func scanDevice(row rowScanner) (domain.Device, error) {
	var (
		device       domain.Device
		registeredAt string
		lastSeenAt   string
	)
	err := row.Scan(&device.ID, &device.UserID, &device.Token, &device.Environment,
		&device.Platform, &device.AppVersion, &registeredAt, &lastSeenAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Device{}, err
		}
		return domain.Device{}, fmt.Errorf("repository: scan device: %w", err)
	}
	device.RegisteredAt = parseTime(registeredAt)
	device.LastSeenAt = parseTime(lastSeenAt)
	return device, nil
}
