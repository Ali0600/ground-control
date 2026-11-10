import Foundation

/// Pages the app sends people to. Pinned by `RepoContractTests`: the setup guide's
/// anchor must be a heading the README still has.
public enum ProjectLinks {
    public static let repository = URL(string: "https://github.com/Ali0600/ground-control")!
    /// The README section that installs `com.launchddash.server`.
    public static let setupGuideAnchor = "run-it-as-an-always-on-agent"
    public static let setupGuide = URL(string: "\(repository.absoluteString)#\(setupGuideAnchor)")!
}
