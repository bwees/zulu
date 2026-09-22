// Command zulu-notifyd is the Zulu notification service: it watches each
// registered user's Zulip event queue and turns the messages that would have
// notified them into Apple push notifications.
package main

import (
	"go.uber.org/fx"

	"github.com/bwees/zulu/service/internal/app"
)

func main() {
	fx.New(app.Module).Run()
}
