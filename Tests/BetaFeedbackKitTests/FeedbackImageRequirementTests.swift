import CoreGraphics
import Testing
@testable import BetaFeedbackKit

@Test func modernAnalyzerDoesNotAnalyzeWithoutCapturedImage() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let input = FeedbackAnalysisInput(
        originalFeedback: "This is confusing.", questionID: "screen",
        questionTitle: "What happened?", metadata: [:], developerContext: [:]
    )
    for variant in FeedbackPromptVariant.allCases {
        let analyzer = OnDeviceFeedbackAnalyzer(promptVariant: variant)
        #expect(try await analyzer.analyze(input, screenshot: nil) == nil)
        #expect(try await analyzer.analyzeConversation(input, screenshot: nil) == nil)
        #expect(try await analyzer.analyzeConversationForEvaluation(input, screenshot: nil) == nil)
    }
}
