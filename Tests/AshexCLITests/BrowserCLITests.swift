@testable import AshexCLI
import Foundation
import Testing

@Test func browserCLIHelpMentionsFetchAndDoctor() {
    #expect(BrowserCLI.helpText.contains("ashex browser fetch <url>"))
    #expect(BrowserCLI.helpText.contains("ashex browser doctor"))
}

@Test func configCLIHelpMentionsConfigSet() {
    #expect(ConfigCLI.helpText.contains("ashex config set"))
}
