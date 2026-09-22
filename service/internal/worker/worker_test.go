package worker

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/database"
	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/notify"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/secret"
	"github.com/bwees/zulu/service/internal/service"
	"github.com/bwees/zulu/service/internal/zulip"
)

const messageEvent = `{"result":"success","events":[{"id":1,"type":"message","flags":["mentioned"],
	"message":{"id":501,"type":"stream","sender_id":42,"sender_full_name":"Ada",
	"stream_id":9,"subject":"deploys","display_recipient":"engineering","content":"ship it"}}]}`

const badQueue = `{"result":"error","code":"BAD_EVENT_QUEUE_ID","msg":"Bad event queue ID: q1","queue_id":"q1"}`

// fakeZulip scripts the /events responses; anything past the script blocks, the
// way a real long poll does.
type fakeZulip struct {
	server *httptest.Server

	mu        sync.Mutex
	registers int
	polls     int
	deletes   int
	script    []scriptedResponse
	blocked   chan struct{}
}

type scriptedResponse struct {
	status int
	body   string
}

func newFakeZulip(t *testing.T, script ...scriptedResponse) *fakeZulip {
	t.Helper()
	fake := &fakeZulip{script: script, blocked: make(chan struct{})}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.handle))
	t.Cleanup(func() {
		close(fake.blocked)
		fake.server.Close()
	})
	return fake
}

func (f *fakeZulip) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/api/v1/register":
		f.mu.Lock()
		f.registers++
		f.mu.Unlock()
		io.WriteString(w, `{"result":"success","queue_id":"q1","last_event_id":0,
			"user_settings":{"enable_stream_push_notifications":true},
			"subscriptions":[{"stream_id":9,"is_muted":false}]}`)

	case r.Method == http.MethodDelete && r.URL.Path == "/api/v1/events":
		f.mu.Lock()
		f.deletes++
		f.mu.Unlock()
		io.WriteString(w, `{"result":"success"}`)

	case r.Method == http.MethodGet && r.URL.Path == "/api/v1/events":
		f.mu.Lock()
		call := f.polls
		f.polls++
		var response scriptedResponse
		if call < len(f.script) {
			response = f.script[call]
		}
		f.mu.Unlock()

		if response.body == "" {
			select {
			case <-f.blocked:
			case <-r.Context().Done():
			}
			return
		}
		w.WriteHeader(response.status)
		io.WriteString(w, response.body)

	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *fakeZulip) counts() (registers, polls, deletes int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.registers, f.polls, f.deletes
}

// recordingDispatcher stands in for the push fan-out.
type recordingDispatcher struct {
	mu       sync.Mutex
	messages []zulip.MessageEvent
	result   service.DispatchResult
}

func (d *recordingDispatcher) Dispatch(_ context.Context, _ domain.User, event zulip.MessageEvent, _ notify.Decision) (service.DispatchResult, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.messages = append(d.messages, event)
	return d.result, nil
}

func (d *recordingDispatcher) count() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.messages)
}

type workerFixture struct {
	worker     *Worker
	users      *repository.UserRepository
	queues     *repository.QueueRepository
	dispatcher *recordingDispatcher
	user       domain.User
}

func newWorkerFixture(t *testing.T, realmURL string, withDevice bool) workerFixture {
	t.Helper()
	ctx := context.Background()

	db, err := database.Open(ctx, filepath.Join(t.TempDir(), "test.db"))
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })

	sealer, err := secret.NewSealer(bytes.Repeat([]byte{1}, 32))
	require.NoError(t, err)

	users := repository.NewUserRepository(db, sealer)
	devices := repository.NewDeviceRepository(db)
	queues := repository.NewQueueRepository(db)

	user, err := users.Upsert(ctx, domain.Credentials{RealmURL: realmURL, Email: "user@example.com", APIKey: "key"}, 7)
	require.NoError(t, err)

	if withDevice {
		_, err = devices.Upsert(ctx, domain.Device{
			ID: "device-1", UserID: user.ID, Token: "abcd",
			Environment: domain.EnvironmentProduction, Platform: domain.PlatformIOS,
		}, []byte("hash"))
		require.NoError(t, err)
	}

	dispatcher := &recordingDispatcher{result: service.DispatchResult{Attempted: 1, Delivered: 1}}
	deps := Deps{
		Users:         users,
		Queues:        queues,
		Devices:       devices,
		Zulip:         zulip.NewClient(),
		Dispatcher:    dispatcher,
		DeliveryGrace: time.Minute,
	}

	return workerFixture{
		worker:     newWorker(user, deps, slog.New(slog.NewTextHandler(io.Discard, nil))),
		users:      users,
		queues:     queues,
		dispatcher: dispatcher,
		user:       user,
	}
}

func runWorker(t *testing.T, worker *Worker) context.CancelFunc {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		worker.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("worker did not stop")
		}
	})
	return cancel
}

func TestWorkerRegistersPollsAndDispatches(t *testing.T) {
	zulipServer := newFakeZulip(t, scriptedResponse{status: 200, body: messageEvent})
	fixture := newWorkerFixture(t, zulipServer.server.URL, true)

	runWorker(t, fixture.worker)

	require.Eventually(t, func() bool { return fixture.dispatcher.count() == 1 }, 5*time.Second, 10*time.Millisecond)
	assert.Equal(t, int64(501), fixture.dispatcher.messages[0].Message.ID)

	require.Eventually(t, func() bool {
		stored, err := fixture.queues.Load(context.Background(), fixture.user.ID)
		return err == nil && stored.LastEventID == 1
	}, 5*time.Second, 10*time.Millisecond, "the cursor is durable, so a restart resumes rather than re-registering")

	assert.True(t, fixture.worker.Health().Connected)
}

// A collected queue is routine: the worker registers a new one and carries on.
func TestWorkerReRegistersOnBadEventQueueID(t *testing.T) {
	zulipServer := newFakeZulip(t,
		scriptedResponse{status: 400, body: badQueue},
		scriptedResponse{status: 200, body: messageEvent},
	)
	fixture := newWorkerFixture(t, zulipServer.server.URL, true)

	runWorker(t, fixture.worker)

	require.Eventually(t, func() bool { return fixture.dispatcher.count() == 1 }, 5*time.Second, 10*time.Millisecond)
	registers, _, _ := zulipServer.counts()
	assert.Equal(t, 2, registers)
}

// One key per account: when Zulip rejects it, no amount of retrying helps.
func TestWorkerStopsWhenTheKeyIsRejected(t *testing.T) {
	zulipServer := newFakeZulip(t, scriptedResponse{
		status: 401,
		body:   `{"result":"error","code":"UNAUTHORIZED","msg":"Invalid API key"}`,
	})
	fixture := newWorkerFixture(t, zulipServer.server.URL, true)

	fixture.worker.Run(context.Background())

	user, err := fixture.users.Get(context.Background(), fixture.user.ID)
	require.NoError(t, err)
	assert.Equal(t, domain.UserAuthFailed, user.Status)
	assert.NotEmpty(t, user.StatusDetail)
	_, _, deletes := zulipServer.counts()
	assert.Equal(t, 1, deletes, "the queue is handed back so Zulip notifies the user itself again")
}

// With nothing to notify, holding the queue would only keep Zulip's own
// notifications suppressed.
func TestWorkerStopsWhenThereAreNoDevices(t *testing.T) {
	zulipServer := newFakeZulip(t)
	fixture := newWorkerFixture(t, zulipServer.server.URL, false)

	fixture.worker.Run(context.Background())

	registers, polls, _ := zulipServer.counts()
	assert.Zero(t, registers)
	assert.Zero(t, polls)
	assert.False(t, fixture.worker.Health().Running)
}
