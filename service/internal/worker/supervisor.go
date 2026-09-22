// Package worker runs one Zulip event queue per registered user.
package worker

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/bwees/zulu/service/internal/domain"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/zulip"
)

// Deps are the collaborators every worker shares.
type Deps struct {
	Users         *repository.UserRepository
	Queues        *repository.QueueRepository
	Devices       *repository.DeviceRepository
	Zulip         *zulip.Client
	Dispatcher    Dispatcher
	DeliveryGrace time.Duration
}

// Supervisor keeps the set of running workers matching the set of registered
// users. Nothing about a worker is durable except its queue cursor and settings
// mirror, so a restart rebuilds the whole set from the database.
type Supervisor struct {
	deps     Deps
	interval time.Duration
	log      *slog.Logger

	mu      sync.Mutex
	running map[int64]*handle

	wake chan struct{}
	done chan struct{}
	wg   sync.WaitGroup
}

type handle struct {
	worker *Worker
	cancel context.CancelFunc
}

func NewSupervisor(deps Deps, interval time.Duration, log *slog.Logger) *Supervisor {
	return &Supervisor{
		deps:     deps,
		interval: interval,
		log:      log,
		running:  map[int64]*handle{},
		wake:     make(chan struct{}, 1),
		done:     make(chan struct{}),
	}
}

// Start begins reconciling in the background. It returns immediately.
func (s *Supervisor) Start(ctx context.Context) {
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.loop(ctx)
	}()
}

// Stop cancels every worker and waits for them. Each one deletes its Zulip queue
// on the way out, which both frees server memory and lets Zulip resume its own
// notifications.
func (s *Supervisor) Stop() {
	close(s.done)
	s.mu.Lock()
	for _, running := range s.running {
		running.cancel()
	}
	s.running = map[int64]*handle{}
	s.mu.Unlock()
	s.wg.Wait()
}

// Reconcile asks for an immediate pass. It never blocks: a pass is already
// pending if the channel is full.
func (s *Supervisor) Reconcile() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *Supervisor) Health(userID int64) domain.WorkerHealth {
	s.mu.Lock()
	running, ok := s.running[userID]
	s.mu.Unlock()
	if !ok {
		return domain.WorkerHealth{}
	}
	return running.worker.Health()
}

func (s *Supervisor) loop(ctx context.Context) {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()

	for {
		if err := s.reconcile(ctx); err != nil {
			s.log.Error("reconcile workers", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		case <-ticker.C:
		case <-s.wake:
		}
	}
}

func (s *Supervisor) reconcile(ctx context.Context) error {
	users, err := s.deps.Users.List(ctx)
	if err != nil {
		return err
	}

	wanted := map[int64]domain.User{}
	for _, user := range users {
		if user.Status != domain.UserActive {
			continue
		}
		devices, err := s.deps.Devices.ListByUser(ctx, user.ID)
		if err != nil {
			return err
		}
		if len(devices) > 0 {
			wanted[user.ID] = user
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	for userID, running := range s.running {
		if _, keep := wanted[userID]; !keep {
			running.cancel()
			delete(s.running, userID)
		}
	}
	for userID, user := range wanted {
		if _, already := s.running[userID]; already {
			continue
		}
		s.start(ctx, user)
	}
	return nil
}

// start launches a worker. The caller holds the lock.
func (s *Supervisor) start(ctx context.Context, user domain.User) {
	workerCtx, cancel := context.WithCancel(ctx)
	worker := newWorker(user, s.deps, s.log)
	s.running[user.ID] = &handle{worker: worker, cancel: cancel}

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer cancel()
		worker.Run(workerCtx)

		// A worker that returns on its own (no devices left, or a dead key) must
		// not be left in the running set, or reconcile will never restart it if
		// the user comes back.
		s.mu.Lock()
		if current, ok := s.running[user.ID]; ok && current.worker == worker {
			delete(s.running, user.ID)
		}
		s.mu.Unlock()
	}()
}
