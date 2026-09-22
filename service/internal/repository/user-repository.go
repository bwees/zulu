package repository

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"

	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/secret"
)

// UserRepository stores accounts and their Zulip API keys.
//
// Sealing happens here so that the ciphertext never leaves this layer and no
// caller can accidentally write a plaintext key to a column.
type UserRepository struct {
	db     *sql.DB
	sealer *secret.Sealer
}

func NewUserRepository(db *sql.DB, sealer *secret.Sealer) *UserRepository {
	return &UserRepository{db: db, sealer: sealer}
}

// Upsert stores an account's credentials, replacing any key already held for the
// same realm and Zulip user.
func (r *UserRepository) Upsert(ctx context.Context, creds domain.Credentials, zulipUserID int64) (domain.User, error) {
	box, err := r.sealer.Seal([]byte(creds.APIKey), credentialBinding(creds.RealmURL, zulipUserID))
	if err != nil {
		return domain.User{}, err
	}

	const query = `INSERT INTO users (realm_url, zulip_user_id, email, api_key_box, status, status_detail)
		VALUES (?, ?, ?, ?, ?, '')
		ON CONFLICT (realm_url, zulip_user_id) DO UPDATE SET
			email = excluded.email,
			api_key_box = excluded.api_key_box,
			status = excluded.status,
			status_detail = '',
			updated_at = datetime('now')`
	if _, err := r.db.ExecContext(ctx, query, creds.RealmURL, zulipUserID, creds.Email, box, string(domain.UserActive)); err != nil {
		return domain.User{}, fmt.Errorf("repository: upsert user: %w", err)
	}
	return r.getBy(ctx, `realm_url = ? AND zulip_user_id = ?`, creds.RealmURL, zulipUserID)
}

func (r *UserRepository) Get(ctx context.Context, id int64) (domain.User, error) {
	return r.getBy(ctx, `id = ?`, id)
}

// List returns every registered account. The supervisor uses it to decide which
// event queue workers should exist.
func (r *UserRepository) List(ctx context.Context) ([]domain.User, error) {
	const query = `SELECT id, realm_url, zulip_user_id, email, status, status_detail, created_at, updated_at
		FROM users ORDER BY id`
	rows, err := r.db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("repository: list users: %w", err)
	}
	defer rows.Close()

	var users []domain.User
	for rows.Next() {
		user, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		users = append(users, user)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("repository: list users: %w", err)
	}
	return users, nil
}

// Credentials unseals the stored API key.
func (r *UserRepository) Credentials(ctx context.Context, id int64) (domain.Credentials, error) {
	const query = `SELECT realm_url, zulip_user_id, email, api_key_box FROM users WHERE id = ?`
	var (
		realmURL    string
		zulipUserID int64
		email       string
		box         []byte
	)
	err := r.db.QueryRowContext(ctx, query, id).Scan(&realmURL, &zulipUserID, &email, &box)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Credentials{}, ErrNotFound
	}
	if err != nil {
		return domain.Credentials{}, fmt.Errorf("repository: read credentials: %w", err)
	}

	apiKey, err := r.sealer.Open(box, credentialBinding(realmURL, zulipUserID))
	if err != nil {
		return domain.Credentials{}, fmt.Errorf("repository: unseal credentials for user %d: %w", id, err)
	}
	return domain.Credentials{RealmURL: realmURL, Email: email, APIKey: string(apiKey)}, nil
}

func (r *UserRepository) SetStatus(ctx context.Context, id int64, status domain.UserStatus, detail string) error {
	const query = `UPDATE users SET status = ?, status_detail = ?, updated_at = datetime('now') WHERE id = ?`
	if _, err := r.db.ExecContext(ctx, query, string(status), detail, id); err != nil {
		return fmt.Errorf("repository: set user status: %w", err)
	}
	return nil
}

// Delete removes the account and, by cascade, its devices, queue state and
// delivery log. It is what "the user deregistered their last device" runs.
func (r *UserRepository) Delete(ctx context.Context, id int64) error {
	if _, err := r.db.ExecContext(ctx, `DELETE FROM users WHERE id = ?`, id); err != nil {
		return fmt.Errorf("repository: delete user: %w", err)
	}
	return nil
}

func (r *UserRepository) getBy(ctx context.Context, where string, args ...any) (domain.User, error) {
	query := `SELECT id, realm_url, zulip_user_id, email, status, status_detail, created_at, updated_at
		FROM users WHERE ` + where
	user, err := scanUser(r.db.QueryRowContext(ctx, query, args...))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.User{}, ErrNotFound
	}
	return user, err
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanUser(row rowScanner) (domain.User, error) {
	var (
		user      domain.User
		status    string
		createdAt string
		updatedAt string
	)
	err := row.Scan(&user.ID, &user.RealmURL, &user.ZulipUserID, &user.Email, &status, &user.StatusDetail, &createdAt, &updatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.User{}, err
		}
		return domain.User{}, fmt.Errorf("repository: scan user: %w", err)
	}
	user.Status = domain.UserStatus(status)
	user.CreatedAt = parseTime(createdAt)
	user.UpdatedAt = parseTime(updatedAt)
	return user, nil
}

// credentialBinding ties a sealed key to the row it belongs to, so a sealed key
// copied onto another row fails to open rather than granting access to the wrong
// account.
func credentialBinding(realmURL string, zulipUserID int64) []byte {
	return []byte(realmURL + "\x00" + strconv.FormatInt(zulipUserID, 10))
}
