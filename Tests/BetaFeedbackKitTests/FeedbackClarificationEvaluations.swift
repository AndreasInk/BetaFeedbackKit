import Foundation
import Testing
@testable import BetaFeedbackKit

// Model evaluation is opt-in and lives in ImageClarificationEvaluations.swift.
// Historical text-only examples are archived separately in Evaluations/legacy-text-corpus.json.
private struct FeedbackClarificationEvaluationTests {
    @Test("Decision scoring distinguishes missing output from a deliberate stop")
    func decisionScoringContract() {
        #expect(imageEvaluationDecisionMatches(question: nil, expectsQuestion: false))
        #expect(!imageEvaluationDecisionMatches(question: nil, expectsQuestion: true))
        #expect(!imageEvaluationDecisionMatches(question: "", expectsQuestion: false))
        #expect(!imageEvaluationDecisionMatches(question: String(repeating: "a", count: 241), expectsQuestion: true))
        #expect(imageEvaluationDecisionMatches(question: "Please describe what happened.", expectsQuestion: true))
    }
}

func imageEvaluationDecisionMatches(question: String?, expectsQuestion: Bool) -> Bool {
    guard let question else { return !expectsQuestion }
    return expectsQuestion && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 240
}
