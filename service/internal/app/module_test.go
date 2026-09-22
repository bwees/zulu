package app_test

import (
	"bytes"
	"encoding/base64"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"go.uber.org/fx"
	"go.uber.org/fx/fxtest"

	"github.com/bwees/zulu/service/internal/app"
	"github.com/bwees/zulu/service/internal/config"
)

func configureEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv(config.EnvKeyEncryptionKey, base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)))
	t.Setenv(config.EnvDatabasePath, filepath.Join(t.TempDir(), "test.db"))
	t.Setenv(config.EnvHTTPAddr, "127.0.0.1:0")
	t.Setenv(config.EnvAPNsDryRun, "true")
}

// A missing provider or a dependency cycle is a boot-time failure, which is too
// late to find out in production.
func TestModuleGraphIsComplete(t *testing.T) {
	configureEnvironment(t)

	require.NoError(t, fx.ValidateApp(app.Module))
}

func TestApplicationStartsAndStops(t *testing.T) {
	configureEnvironment(t)

	application := fxtest.New(t, app.Module)

	application.RequireStart()
	application.RequireStop()
}
