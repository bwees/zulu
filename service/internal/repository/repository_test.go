package repository_test

import (
	"bytes"
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/database"
	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/notify"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/secret"
)

func newDatabase(t *testing.T) *sql.DB {
	t.Helper()
	db, err := database.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })
	return db
}

func newSealer(t *testing.T) *secret.Sealer {
	t.Helper()
	sealer, err := secret.NewSealer(bytes.Repeat([]byte{3}, 32))
	require.NoError(t, err)
	return sealer
}

func testCredentials() domain.Credentials {
	return domain.Credentials{RealmURL: "https://chat.example.com", Email: "user@example.com", APIKey: "key-one"}
}

func TestUserRepositoryStoresKeysEncrypted(t *testing.T) {
	ctx := context.Background()
	db := newDatabase(t)
	users := repository.NewUserRepository(db, newSealer(t))

	user, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)

	var stored []byte
	require.NoError(t, db.QueryRowContext(ctx, `SELECT api_key_box FROM users WHERE id = ?`, user.ID).Scan(&stored))
	assert.NotContains(t, string(stored), "key-one", "the key is never at rest in plaintext")

	creds, err := users.Credentials(ctx, user.ID)
	require.NoError(t, err)
	assert.Equal(t, testCredentials(), creds)
}

// Zulip issues one API key per account, so re-registering replaces the copy held
// here rather than adding a second account row.
func TestUserRepositoryUpsertReplacesTheKey(t *testing.T) {
	ctx := context.Background()
	users := repository.NewUserRepository(newDatabase(t), newSealer(t))
	first, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)

	rotated := testCredentials()
	rotated.APIKey = "key-two"
	second, err := users.Upsert(ctx, rotated, 12)
	require.NoError(t, err)

	assert.Equal(t, first.ID, second.ID)
	creds, err := users.Credentials(ctx, second.ID)
	require.NoError(t, err)
	assert.Equal(t, "key-two", creds.APIKey)
}

// A sealed key is bound to its row, so moving the ciphertext elsewhere in the
// database does not yield a usable credential.
func TestUserRepositoryRejectsAMovedCiphertext(t *testing.T) {
	ctx := context.Background()
	db := newDatabase(t)
	users := repository.NewUserRepository(db, newSealer(t))
	victim, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)
	attacker, err := users.Upsert(ctx, domain.Credentials{
		RealmURL: "https://chat.example.com",
		Email:    "other@example.com",
		APIKey:   "key-other",
	}, 13)
	require.NoError(t, err)

	_, err = db.ExecContext(ctx,
		`UPDATE users SET api_key_box = (SELECT api_key_box FROM users WHERE id = ?) WHERE id = ?`,
		victim.ID, attacker.ID)
	require.NoError(t, err)

	_, err = users.Credentials(ctx, attacker.ID)
	assert.Error(t, err)
}

func TestUserRepositoryStatusAndDelete(t *testing.T) {
	ctx := context.Background()
	users := repository.NewUserRepository(newDatabase(t), newSealer(t))
	user, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)

	require.NoError(t, users.SetStatus(ctx, user.ID, domain.UserAuthFailed, "key rejected"))
	reloaded, err := users.Get(ctx, user.ID)
	require.NoError(t, err)
	assert.Equal(t, domain.UserAuthFailed, reloaded.Status)
	assert.Equal(t, "key rejected", reloaded.StatusDetail)

	require.NoError(t, users.Delete(ctx, user.ID))
	_, err = users.Get(ctx, user.ID)
	assert.ErrorIs(t, err, repository.ErrNotFound)
}

func TestDeviceRepositoryUpsertIsIdempotentPerToken(t *testing.T) {
	ctx := context.Background()
	db := newDatabase(t)
	users := repository.NewUserRepository(db, newSealer(t))
	devices := repository.NewDeviceRepository(db)
	user, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)

	first, err := devices.Upsert(ctx, domain.Device{
		ID: "device-1", UserID: user.ID, Token: "abcd", Environment: domain.EnvironmentProduction, Platform: domain.PlatformIOS,
	}, []byte("hash-1"))
	require.NoError(t, err)

	second, err := devices.Upsert(ctx, domain.Device{
		ID: "device-2", UserID: user.ID, Token: "abcd", Environment: domain.EnvironmentProduction, Platform: domain.PlatformIOS,
		AppVersion: "1.1",
	}, []byte("hash-2"))
	require.NoError(t, err)

	assert.Equal(t, first.ID, second.ID, "the app re-posts its token on every launch")
	assert.Equal(t, "1.1", second.AppVersion)

	listed, err := devices.ListByUser(ctx, user.ID)
	require.NoError(t, err)
	assert.Len(t, listed, 1)

	found, err := devices.FindBySecretHash(ctx, []byte("hash-2"))
	require.NoError(t, err)
	assert.Equal(t, first.ID, found.ID)
	_, err = devices.FindBySecretHash(ctx, []byte("hash-1"))
	assert.ErrorIs(t, err, repository.ErrNotFound, "the replaced secret stops working")
}

// The same token can move to another account when a handset is handed over.
func TestDeviceRepositoryTokenMovesBetweenAccounts(t *testing.T) {
	ctx := context.Background()
	db := newDatabase(t)
	users := repository.NewUserRepository(db, newSealer(t))
	devices := repository.NewDeviceRepository(db)
	first, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)
	other := testCredentials()
	other.Email = "second@example.com"
	second, err := users.Upsert(ctx, other, 13)
	require.NoError(t, err)

	_, err = devices.Upsert(ctx, domain.Device{
		ID: "device-1", UserID: first.ID, Token: "abcd", Environment: domain.EnvironmentProduction, Platform: domain.PlatformIOS,
	}, []byte("hash-1"))
	require.NoError(t, err)
	_, err = devices.Upsert(ctx, domain.Device{
		ID: "device-2", UserID: second.ID, Token: "abcd", Environment: domain.EnvironmentProduction, Platform: domain.PlatformIOS,
	}, []byte("hash-2"))
	require.NoError(t, err)

	firstDevices, err := devices.ListByUser(ctx, first.ID)
	require.NoError(t, err)
	secondDevices, err := devices.ListByUser(ctx, second.ID)
	require.NoError(t, err)
	assert.Empty(t, firstDevices)
	assert.Len(t, secondDevices, 1)
}

func TestDeletingAUserRemovesEverythingItOwns(t *testing.T) {
	ctx := context.Background()
	db := newDatabase(t)
	users := repository.NewUserRepository(db, newSealer(t))
	devices := repository.NewDeviceRepository(db)
	queues := repository.NewQueueRepository(db)
	user, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)
	_, err = devices.Upsert(ctx, domain.Device{
		ID: "device-1", UserID: user.ID, Token: "abcd", Environment: domain.EnvironmentSandbox, Platform: domain.PlatformMacOS,
	}, []byte("hash-1"))
	require.NoError(t, err)
	require.NoError(t, queues.Save(ctx, user.ID, domain.QueueState{QueueID: "q", LastEventID: 1, State: notify.NewState()}))

	require.NoError(t, users.Delete(ctx, user.ID))

	remaining, err := devices.ListByUser(ctx, user.ID)
	require.NoError(t, err)
	assert.Empty(t, remaining)
	_, err = queues.Load(ctx, user.ID)
	assert.ErrorIs(t, err, repository.ErrNotFound)
}

func TestQueueRepositoryRoundTrip(t *testing.T) {
	ctx := context.Background()
	db := newDatabase(t)
	users := repository.NewUserRepository(db, newSealer(t))
	queues := repository.NewQueueRepository(db)
	user, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)

	state := notify.NewState()
	state.SetTopicPolicy(3, "Deploys", notify.PolicyFollowed)
	require.NoError(t, queues.Save(ctx, user.ID, domain.QueueState{QueueID: "queue-1", LastEventID: 17, State: state}))

	require.NoError(t, queues.Advance(ctx, user.ID, 23))

	loaded, err := queues.Load(ctx, user.ID)
	require.NoError(t, err)
	assert.Equal(t, "queue-1", loaded.QueueID)
	assert.Equal(t, int64(23), loaded.LastEventID, "a restart resumes where the cursor left off")
	assert.Equal(t, notify.PolicyFollowed, loaded.State.TopicPolicy(3, "deploys"))

	require.NoError(t, queues.Clear(ctx, user.ID))
	_, err = queues.Load(ctx, user.ID)
	assert.ErrorIs(t, err, repository.ErrNotFound)
}

func TestDeliveryRepositoryClaimsOnce(t *testing.T) {
	ctx := context.Background()
	db := newDatabase(t)
	users := repository.NewUserRepository(db, newSealer(t))
	devices := repository.NewDeviceRepository(db)
	deliveries := repository.NewDeliveryRepository(db)
	user, err := users.Upsert(ctx, testCredentials(), 12)
	require.NoError(t, err)
	device, err := devices.Upsert(ctx, domain.Device{
		ID: "device-1", UserID: user.ID, Token: "abcd", Environment: domain.EnvironmentProduction, Platform: domain.PlatformIOS,
	}, []byte("hash-1"))
	require.NoError(t, err)

	first, err := deliveries.Claim(ctx, user.ID, device.ID, 500, "mentioned")
	require.NoError(t, err)
	second, err := deliveries.Claim(ctx, user.ID, device.ID, 500, "mentioned")
	require.NoError(t, err)

	assert.True(t, first)
	assert.False(t, second, "a replayed event must not push twice")

	require.NoError(t, deliveries.Release(ctx, user.ID, device.ID, 500))
	third, err := deliveries.Claim(ctx, user.ID, device.ID, 500, "mentioned")
	require.NoError(t, err)
	assert.True(t, third, "releasing a failed claim allows a retry")

	require.NoError(t, deliveries.Complete(ctx, user.ID, device.ID, 500, repository.DeliverySent, ""))
	deleted, err := deliveries.Prune(ctx, time.Now().Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, int64(1), deleted)
}
