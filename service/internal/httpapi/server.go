// Package httpapi wires the controllers onto a fuego server, which generates the
// OpenAPI description the app's client is built from.
package httpapi

import (
	"log/slog"
	"net/http"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/go-fuego/fuego"

	"github.com/bwees/zulu/service/internal/config"
	"github.com/bwees/zulu/service/internal/controller"
)

const securitySchemeName = "deviceSecret"

// NewServer builds the server and registers every route. It does not listen;
// the lifecycle hook in the application module does that.
func NewServer(
	cfg config.Config,
	devices *controller.DeviceController,
	health *controller.HealthController,
	log *slog.Logger,
) *fuego.Server {
	server := fuego.NewServer(
		fuego.WithAddr(cfg.HTTPAddr),
		fuego.WithLogHandler(log.Handler()),
		fuego.WithoutStartupMessages(),
		fuego.WithSecurity(openapi3.SecuritySchemes{
			securitySchemeName: &openapi3.SecuritySchemeRef{
				Value: openapi3.NewSecurityScheme().
					WithType("http").
					WithScheme("bearer").
					WithDescription("The device secret returned by POST /v1/devices."),
			},
		}),
		fuego.WithEngineOptions(fuego.WithOpenAPIConfig(fuego.OpenAPIConfig{
			JSONFilePath:     cfg.OpenAPIFile,
			DisableLocalSave: cfg.OpenAPIFile == "",
			DisableMessages:  true,
			PrettyFormatJSON: true,
			Info: &openapi3.Info{
				Title:       "Zulu notification service",
				Version:     "1.0.0",
				Description: "Registers Apple devices for Zulip push notifications.",
			},
		})),
	)

	authenticated := fuego.OptionSecurity(openapi3.SecurityRequirement{securitySchemeName: []string{}})

	fuego.Post(server, "/v1/devices", devices.Register,
		fuego.OptionTags("devices"),
		fuego.OptionSummary("Register a device for notifications"),
		fuego.OptionDescription("Verifies the Zulip credentials, stores them encrypted, and starts watching the account's Zulip events."),
		fuego.OptionDefaultStatusCode(http.StatusCreated),
		fuego.OptionAddError(http.StatusBadRequest, "The request is malformed"),
		fuego.OptionAddError(http.StatusUnauthorized, "Zulip rejected the credentials"),
	)

	fuego.Get(server, "/v1/devices", devices.List,
		fuego.OptionTags("devices"),
		fuego.OptionSummary("List the account's registered devices"),
		authenticated,
		fuego.OptionAddError(http.StatusUnauthorized, "Unknown device secret"),
	)

	fuego.Delete(server, "/v1/devices/{deviceId}", devices.Deregister,
		fuego.OptionTags("devices"),
		fuego.OptionSummary("Deregister a device"),
		fuego.OptionDescription("Removing the last device also deletes the stored API key and releases the Zulip event queue."),
		fuego.OptionPath("deviceId", "Device to remove"),
		authenticated,
		fuego.OptionAddError(http.StatusUnauthorized, "Unknown device secret"),
		fuego.OptionAddError(http.StatusNotFound, "No such device on this account"),
	)

	fuego.Get(server, "/v1/status", devices.Status,
		fuego.OptionTags("devices"),
		fuego.OptionSummary("Report whether notifications are working"),
		authenticated,
		fuego.OptionAddError(http.StatusUnauthorized, "Unknown device secret"),
	)

	fuego.Get(server, "/healthz", health.Health,
		fuego.OptionTags("health"),
		fuego.OptionSummary("Liveness probe"),
		fuego.OptionAddError(http.StatusServiceUnavailable, "The database is not reachable"),
	)

	return server
}
