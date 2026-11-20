import Combine
import Foundation

/// Clocks the screens refresh from. They are shared and made once. A timer kept as a property of a view is
/// made afresh every time the window redraws, and the app redraws several times a second while it is tracking,
/// so such a timer was thrown away before it could ever fire: a screen waiting for the helper's answer
/// (linking, "Who are you?") then never noticed the answer had arrived.
enum Ticker {
    static let every1 = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    static let every2 = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    static let every3 = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
}
