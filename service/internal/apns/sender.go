package apns

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"

	"github.com/bwees/zulu/service/internal/config"
	"github.com/bwees/zulu/service/internal/domain"
)

// Client sends through Apple's gateway with token (p8/JWT) auth.
//
// One client per environment is held for the process lifetime: APNs binds a team
// and its bundle ids to a connection on the first push, and reconnecting per
// push would both break that binding and lose the HTTP/2 multiplexing.
type Client struct {
	production *apns2.Client
	sandbox    *apns2.Client
	topic      string
}

func NewClient(cfg config.APNs) (*Client, error) {
	keyBytes, err := os.ReadFile(cfg.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("apns: read auth key: %w", err)
	}
	authKey, err := token.AuthKeyFromBytes(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("apns: parse auth key: %w", err)
	}

	// The library regenerates this JWT every 50 minutes, inside Apple's 20-to-60
	// minute refresh window, so nothing here has to schedule it.
	authToken := &token.Token{AuthKey: authKey, KeyID: cfg.KeyID, TeamID: cfg.TeamID}

	return &Client{
		production: apns2.NewTokenClient(authToken).Production(),
		sandbox:    apns2.NewTokenClient(authToken).Development(),
		topic:      cfg.BundleID,
	}, nil
}

func (c *Client) Push(ctx context.Context, notification Notification) (Receipt, error) {
	client := c.production
	if notification.Environment == domain.EnvironmentSandbox {
		client = c.sandbox
	}

	response, err := client.PushWithContext(ctx, &apns2.Notification{
		DeviceToken: notification.Token,
		Topic:       c.topic,
		CollapseID:  notification.CollapseID,
		PushType:    apns2.PushTypeAlert,
		Priority:    apns2.PriorityHigh,
		Payload:     notification.Payload,
	})
	if err != nil {
		return Receipt{}, fmt.Errorf("apns: push: %w", err)
	}

	return Receipt{
		Sent:       response.Sent(),
		StatusCode: response.StatusCode,
		Reason:     response.Reason,
		Timestamp:  response.Timestamp.Time,
	}, nil
}

// DryRunSender logs what would be sent. It exists so the service can be run
// locally, and in tests, without an Apple developer account.
type DryRunSender struct {
	log *slog.Logger
}

func NewDryRunSender(log *slog.Logger) *DryRunSender {
	return &DryRunSender{log: log}
}

func (s *DryRunSender) Push(_ context.Context, notification Notification) (Receipt, error) {
	s.log.Info("apns dry run",
		"environment", notification.Environment,
		"collapse_id", notification.CollapseID,
		"title", notification.Payload.Title,
		"subtitle", notification.Payload.Subtitle)
	return Receipt{Sent: true, StatusCode: 200}, nil
}
