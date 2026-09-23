import Foundation

extension AppModel {
    /// Whether a notification about `destination` would only repeat what is on screen.
    /// A chat channel shows its one topic under the channel's own destination, so a
    /// message there counts as open when the channel is.
    func isShowing(_ destination: Destination) -> Bool {
        if self.destination == destination { return true }
        if case .topic(let channelID, _, _) = destination,
           case .channel(let openID) = self.destination, openID == channelID,
           channel(channelID)?.rendersAsForum == false {
            return true
        }
        return false
    }
}
