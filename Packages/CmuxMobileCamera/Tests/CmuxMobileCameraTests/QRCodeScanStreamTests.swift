import Testing
@testable import CmuxMobileCamera

@Suite struct QRCodeScanStreamTests {
    @Test func yieldsCodesInOrderThenFinishes() async {
        let stream = QRCodeScanStream()
        stream.yield("uniconnect://one")
        stream.yield("uniconnect://two")
        stream.finish()

        var seen: [String] = []
        for await code in stream.codes {
            seen.append(code)
        }
        #expect(seen == ["uniconnect://one", "uniconnect://two"])
    }

    @Test func finishWithoutYieldProducesEmptySequence() async {
        let stream = QRCodeScanStream()
        stream.finish()

        var seen: [String] = []
        for await code in stream.codes {
            seen.append(code)
        }
        #expect(seen.isEmpty)
    }
}
