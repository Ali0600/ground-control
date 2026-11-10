import os

/// The app's diagnostics, under its own subsystem so they can be pulled out of the
/// unified log on their own:
///
///     log show --last 10m --predicate 'subsystem == "com.launchddash.groundcontrol"'
///
/// (NSLog lines from the app launched by Finder never showed up in `log show`; these do.)
/// Interpolated values are redacted as <private> unless marked public — everything logged
/// here is about this Mac's own dashboard, so it is marked public on purpose.
enum Log {
    static let app = Logger(subsystem: "com.launchddash.groundcontrol", category: "app")
}
