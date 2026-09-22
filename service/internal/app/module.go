// Package app wires the service together and owns its lifecycle.
package app

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/go-fuego/fuego"
	"go.uber.org/fx"
	"go.uber.org/fx/fxevent"

	"github.com/bwees/zulu/service/internal/apns"
	"github.com/bwees/zulu/service/internal/config"
	"github.com/bwees/zulu/service/internal/controller"
	"github.com/bwees/zulu/service/internal/database"
	"github.com/bwees/zulu/service/internal/httpapi"
	"github.com/bwees/zulu/service/internal/repository"
	"github.com/bwees/zulu/service/internal/secret"
	"github.com/bwees/zulu/service/internal/service"
	"github.com/bwees/zulu/service/internal/worker"
	"github.com/bwees/zulu/service/internal/zulip"
)

// deliveryLogRetention is how long a delivery record stays useful for
// deduplication. Zulip queues cannot redeliver anything older than their
// seven-day maximum lifetime.
const deliveryLogRetention = 8 * 24 * time.Hour

// Module is the whole application graph.
var Module = fx.Options(
	fx.Provide(
		config.Load,
		NewLogger,
		NewSealer,
		NewDatabase,
		repository.NewUserRepository,
		repository.NewDeviceRepository,
		repository.NewQueueRepository,
		repository.NewDeliveryRepository,
		zulip.NewClient,
		NewAPNsSender,
		service.NewDispatchService,
		NewSupervisor,
		AsServiceSupervisor,
		service.NewDeviceService,
		controller.NewDeviceController,
		controller.NewHealthController,
		httpapi.NewServer,
	),
	fx.Invoke(
		RunSupervisor,
		RunHTTPServer,
		PruneDeliveryLog,
	),
	// Send fx's own boot narration through the same structured logger, so a
	// deployment has one log format rather than two.
	fx.WithLogger(func(log *slog.Logger) fxevent.Logger {
		return &fxevent.SlogLogger{Logger: log.With("component", "fx")}
	}),
)

func NewLogger(cfg config.Config) *slog.Logger {
	level := slog.LevelInfo
	if err := level.UnmarshalText([]byte(cfg.LogLevel)); err != nil {
		level = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
}

func NewSealer(cfg config.Config) (*secret.Sealer, error) {
	return secret.NewSealer(cfg.KeyEncryptionKey)
}

func NewDatabase(lc fx.Lifecycle, cfg config.Config) (*sql.DB, error) {
	db, err := database.Open(context.Background(), cfg.DatabasePath)
	if err != nil {
		return nil, err
	}
	lc.Append(fx.Hook{
		OnStop: func(context.Context) error { return db.Close() },
	})
	return db, nil
}

// NewAPNsSender picks the real gateway or the dry-run logger. Dry run exists so
// the service can be run without an Apple developer account.
func NewAPNsSender(cfg config.Config, log *slog.Logger) (apns.Sender, error) {
	if cfg.APNs.DryRun {
		log.Warn("apns dry run: notifications will be logged, not delivered")
		return apns.NewDryRunSender(log), nil
	}
	return apns.NewClient(cfg.APNs)
}

func NewSupervisor(
	cfg config.Config,
	users *repository.UserRepository,
	queues *repository.QueueRepository,
	devices *repository.DeviceRepository,
	zulipClient *zulip.Client,
	dispatcher *service.DispatchService,
	log *slog.Logger,
) *worker.Supervisor {
	return worker.NewSupervisor(worker.Deps{
		Users:         users,
		Queues:        queues,
		Devices:       devices,
		Zulip:         zulipClient,
		Dispatcher:    dispatcher,
		DeliveryGrace: cfg.DeliveryGrace,
	}, cfg.ReconcileInterval, log)
}

// AsServiceSupervisor exposes the supervisor through the narrow interface the
// device service asks for, so the service layer never sees the worker package.
func AsServiceSupervisor(supervisor *worker.Supervisor) service.Supervisor { return supervisor }

// RunSupervisor starts the per-user event queue workers and stops them on
// shutdown, which also releases every Zulip queue.
func RunSupervisor(lc fx.Lifecycle, supervisor *worker.Supervisor, log *slog.Logger) {
	ctx, cancel := context.WithCancel(context.Background())
	lc.Append(fx.Hook{
		OnStart: func(context.Context) error {
			supervisor.Start(ctx)
			return nil
		},
		OnStop: func(context.Context) error {
			log.Info("stopping event queue workers")
			cancel()
			supervisor.Stop()
			return nil
		},
	})
}

func RunHTTPServer(lc fx.Lifecycle, server *fuego.Server, cfg config.Config, log *slog.Logger) error {
	listener, err := net.Listen("tcp", cfg.HTTPAddr)
	if err != nil {
		return err
	}

	server.Handler = server.Mux
	lc.Append(fx.Hook{
		OnStart: func(context.Context) error {
			// Generate the spec before serving so /swagger and the file on disk
			// are never a request behind the routes they describe.
			server.Engine.RegisterOpenAPIRoutes(server)
			server.Engine.OutputOpenAPISpec()
			go func() {
				log.Info("http server listening", "addr", listener.Addr().String())
				if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
					log.Error("http server stopped", "error", err)
				}
			}()
			return nil
		},
		OnStop: func(ctx context.Context) error {
			return server.Shutdown(ctx)
		},
	})
	return nil
}

// PruneDeliveryLog trims the deduplication log on boot. Doing it once per start
// is enough: the table only grows at the rate of delivered notifications.
func PruneDeliveryLog(lc fx.Lifecycle, deliveries *repository.DeliveryRepository, log *slog.Logger) {
	lc.Append(fx.Hook{
		OnStart: func(ctx context.Context) error {
			deleted, err := deliveries.Prune(ctx, time.Now().Add(-deliveryLogRetention))
			if err != nil {
				return err
			}
			if deleted > 0 {
				log.Info("pruned delivery log", "rows", deleted)
			}
			return nil
		},
	})
}
