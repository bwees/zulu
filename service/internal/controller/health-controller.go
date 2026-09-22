package controller

import (
	"context"
	"database/sql"

	"github.com/go-fuego/fuego"
)

// HealthController answers the liveness probe. It is the only unauthenticated
// route that touches the database, and it reports nothing about any account.
type HealthController struct {
	db *sql.DB
}

func NewHealthController(db *sql.DB) *HealthController {
	return &HealthController{db: db}
}

func (c *HealthController) Health(ctx fuego.ContextNoBody) (HealthResponse, error) {
	if err := c.ping(ctx.Context()); err != nil {
		return HealthResponse{}, fuego.HTTPError{
			Status: 503,
			Title:  "Unavailable",
			Detail: "The database is not reachable.",
			Err:    err,
		}
	}
	return HealthResponse{Status: "ok"}, nil
}

func (c *HealthController) ping(ctx context.Context) error {
	return c.db.PingContext(ctx)
}
