// Package config reads the service's settings from the environment.
package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"time"
)

const (
	// KeyEncryptionKeyLength is the AES-256 key size. The key-encryption key is
	// read from the environment and never written to the database.
	KeyEncryptionKeyLength = 32

	EnvDatabasePath     = "ZULU_DATABASE_PATH"
	EnvHTTPAddr         = "ZULU_HTTP_ADDR"
	EnvKeyEncryptionKey = "ZULU_KEY_ENCRYPTION_KEY"
	EnvOpenAPIFile      = "ZULU_OPENAPI_FILE"
	EnvLogLevel         = "ZULU_LOG_LEVEL"
	EnvReconcile        = "ZULU_RECONCILE_INTERVAL"
	EnvDeliveryGrace    = "ZULU_DELIVERY_GRACE"

	EnvAPNsKeyFile  = "ZULU_APNS_KEY_FILE"
	EnvAPNsKeyID    = "ZULU_APNS_KEY_ID"
	EnvAPNsTeamID   = "ZULU_APNS_TEAM_ID"
	EnvAPNsBundleID = "ZULU_APNS_BUNDLE_ID"
	EnvAPNsDryRun   = "ZULU_APNS_DRY_RUN"
)

type Config struct {
	DatabasePath string
	HTTPAddr     string
	LogLevel     string
	// OpenAPIFile, when set, is where the generated spec is written on boot.
	OpenAPIFile string
	// KeyEncryptionKey unwraps the stored Zulip API keys. Losing it means every
	// stored credential is unreadable and every user must register again.
	KeyEncryptionKey []byte
	// ReconcileInterval is how often the supervisor re-reads the user list.
	ReconcileInterval time.Duration
	// DeliveryGrace is how long every push to a user may keep failing before the
	// service drops its event queue and lets Zulip notify the user again.
	DeliveryGrace time.Duration
	APNs          APNs
}

type APNs struct {
	KeyFile  string
	KeyID    string
	TeamID   string
	BundleID string
	// DryRun logs pushes instead of sending them, for local runs without an
	// Apple developer account.
	DryRun bool
}

func Load() (Config, error) {
	cfg := Config{
		DatabasePath:      env(EnvDatabasePath, "zulu.db"),
		HTTPAddr:          env(EnvHTTPAddr, ":8080"),
		LogLevel:          env(EnvLogLevel, "info"),
		OpenAPIFile:       os.Getenv(EnvOpenAPIFile),
		ReconcileInterval: 60 * time.Second,
		DeliveryGrace:     15 * time.Minute,
		APNs: APNs{
			KeyFile:  os.Getenv(EnvAPNsKeyFile),
			KeyID:    os.Getenv(EnvAPNsKeyID),
			TeamID:   os.Getenv(EnvAPNsTeamID),
			BundleID: os.Getenv(EnvAPNsBundleID),
			DryRun:   os.Getenv(EnvAPNsDryRun) == "true",
		},
	}

	key, err := loadKeyEncryptionKey()
	if err != nil {
		return Config{}, err
	}
	cfg.KeyEncryptionKey = key

	if cfg.ReconcileInterval, err = duration(EnvReconcile, cfg.ReconcileInterval); err != nil {
		return Config{}, err
	}
	if cfg.DeliveryGrace, err = duration(EnvDeliveryGrace, cfg.DeliveryGrace); err != nil {
		return Config{}, err
	}
	if err := cfg.APNs.validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (a APNs) validate() error {
	if a.DryRun {
		return nil
	}
	missing := []string{}
	for name, value := range map[string]string{
		EnvAPNsKeyFile:  a.KeyFile,
		EnvAPNsKeyID:    a.KeyID,
		EnvAPNsTeamID:   a.TeamID,
		EnvAPNsBundleID: a.BundleID,
	} {
		if value == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("apns is not configured: set %v, or %s=true to log pushes instead", missing, EnvAPNsDryRun)
	}
	return nil
}

func loadKeyEncryptionKey() ([]byte, error) {
	raw := os.Getenv(EnvKeyEncryptionKey)
	if raw == "" {
		return nil, fmt.Errorf("%s is required: %d random bytes, base64 encoded", EnvKeyEncryptionKey, KeyEncryptionKeyLength)
	}
	key, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("%s is not valid base64: %w", EnvKeyEncryptionKey, err)
	}
	if len(key) != KeyEncryptionKeyLength {
		return nil, fmt.Errorf("%s decodes to %d bytes, want %d", EnvKeyEncryptionKey, len(key), KeyEncryptionKeyLength)
	}
	return key, nil
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func duration(name string, fallback time.Duration) (time.Duration, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", name, err)
	}
	if parsed <= 0 {
		return 0, errors.New(name + " must be positive")
	}
	return parsed, nil
}
