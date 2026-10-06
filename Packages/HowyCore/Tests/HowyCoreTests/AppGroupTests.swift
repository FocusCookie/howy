import Testing
@testable import HowyCore

@Suite struct AppGroupTests {
    @Test func usesInfoPlistValueWhenPresent() {
        #expect(HowyAppGroup.resolve(infoValue: "ABCDE12345.io.lichtwart.howy") == "ABCDE12345.io.lichtwart.howy")
    }

    @Test(arguments: [nil, "", "   ", "$(TeamIdentifierPrefix)io.lichtwart.howy", "group.io.lichtwart.howy"])
    func fallsBackToConstantForMissingOrUnexpandedValues(value: String?) {
        #expect(HowyAppGroup.resolve(infoValue: value) == HowyAppGroup.fallbackIdentifier)
    }

    @Test func fallbackIsTeamPrefixedNeverGroupPrefixed() {
        #expect(!HowyAppGroup.fallbackIdentifier.hasPrefix("group."))
        #expect(HowyAppGroup.fallbackIdentifier == "GQ9M79TF33.io.lichtwart.howy")
    }
}
