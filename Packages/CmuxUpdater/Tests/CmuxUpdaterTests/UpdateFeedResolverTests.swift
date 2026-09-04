import Testing
@testable import CmuxUpdater

@Suite struct UpdateFeedResolverTests {
    @Test func missingInfoFeedURLDisablesUpdater() {
        let resolution = UpdateFeedResolver().resolve(infoFeedURL: nil)

        #expect(resolution.url == nil)
        #expect(!resolution.isEnabled)
        #expect(!resolution.rejectedConfiguredURL)
    }

    @Test func sourceBuildPlaceholderDisablesUpdater() {
        let resolution = UpdateFeedResolver().resolve(infoFeedURL: "about:blank")

        #expect(resolution.url == nil)
        #expect(!resolution.isEnabled)
        #expect(!resolution.rejectedConfiguredURL)
    }

    @Test func exactStableFeedIsAllowed() {
        let resolution = UpdateFeedResolver().resolve(
            infoFeedURL: UpdateFeedResolver.stableFeedURL
        )

        #expect(resolution.url == UpdateFeedResolver.stableFeedURL)
        #expect(resolution.isEnabled)
        #expect(!resolution.isNightly)
    }

    @Test func exactNightlyFeedIsAllowed() {
        let resolution = UpdateFeedResolver().resolve(
            infoFeedURL: UpdateFeedResolver.nightlyFeedURL
        )

        #expect(resolution.url == UpdateFeedResolver.nightlyFeedURL)
        #expect(resolution.isEnabled)
        #expect(resolution.isNightly)
    }

    @Test(arguments: [
        "http://github.com/Unixcision/uniconnect/releases/latest/download/appcast.xml",
        "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml",
        "https://example.com/Unixcision/uniconnect/releases/latest/download/appcast.xml",
        "https://github.com/Unixcision/uniconnect/releases/latest/download/appcast.xml?redirect=1",
    ])
    func foreignOrModifiedFeedIsRejected(candidate: String) {
        let resolution = UpdateFeedResolver().resolve(infoFeedURL: candidate)

        #expect(resolution.url == nil)
        #expect(!resolution.isEnabled)
        #expect(resolution.rejectedConfiguredURL)
    }
}
