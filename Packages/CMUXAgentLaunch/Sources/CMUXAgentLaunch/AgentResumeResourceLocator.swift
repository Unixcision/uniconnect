import Foundation

/// Finds deployed SwiftPM resources without the generated accessor's fatal build-path fallback.
struct AgentResumeResourceLocator {
    let mainBundleURL: URL
    let mainResourceURL: URL?
    let executableURL: URL?
    let imageBundleURL: URL

    // Bundle identity only: this token owns no runtime state or NSObject/KVO behavior.
    private final class ModuleToken {}

    init(
        mainBundleURL: URL = Bundle.main.bundleURL,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL,
        imageBundleURL: URL? = nil
    ) {
        self.mainBundleURL = mainBundleURL
        self.mainResourceURL = mainResourceURL
        self.executableURL = executableURL
        self.imageBundleURL = imageBundleURL ?? Bundle(for: ModuleToken.self).bundleURL
    }

    func resourceURL() -> URL? {
        var roots = [mainResourceURL].compactMap { $0 }
        // A hosted macOS test's main bundle belongs to xctest, not this module.
        // The image bundle also handles package code linked into a framework.
        for container in [mainBundleURL, imageBundleURL] {
            roots.append(container)
            if let resources = Bundle(url: container)?.resourceURL {
                roots.append(resources)
            }
            if ["app", "xctest", "framework"].contains(container.pathExtension) {
                roots.append(container.deletingLastPathComponent())
            }
        }
        if let executableURL {
            let directory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            roots.append(directory)
            let resources = directory.deletingLastPathComponent()
            let contents = resources.deletingLastPathComponent()
            if directory.lastPathComponent == "bin",
               resources.lastPathComponent == "Resources",
               contents.lastPathComponent == "Contents",
               contents.deletingLastPathComponent().pathExtension == "app" {
                // Xcode's Copy CLI phase moves only the binary into Resources/bin;
                // the app's SwiftPM resource bundle remains in Resources.
                roots.append(resources)
            }
        }
        for root in roots {
            for name in ["CMUXAgentLaunch_CMUXAgentLaunch.bundle", "CMUXAgentLaunch_CMUXAgentLaunch.resources"] {
                if let bundle = Bundle(url: root.appendingPathComponent(name)),
                   let url = bundle.url(forResource: "agent-resume-v1", withExtension: "json") {
                    return url
                }
            }
        }
        return nil
    }
}
