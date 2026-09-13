//
//  TestFlightFeedbackSheetView.swift
//  BetaFeedbackKit
//
//  Created by Andreas Ink on 2/6/26.
//

import SwiftUI

struct TestFlightFeedbackSheetView: View {
    let screenshotSessionID: UUID?

    init(screenshotSessionID: UUID? = nil) {
        self.screenshotSessionID = screenshotSessionID
    }

    @Environment(BetaContentViewModel.self) private var vm: BetaContentViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: FeedbackField?

    @AppStorage("testFlightFeedbackQuestionId") private var storedQuestionId = ""
    @AppStorage("testFlightFeedbackQuestionDay") private var storedQuestionDay = 0

    @State private var answer: String = ""
    @State private var clarificationResponse: String = ""
    @State private var analysis: BetaFeedbackClarificationAnalysis?
    @State private var submissionInput: FeedbackAnalysisInput?
    @State private var analysisTask: Task<Void, Never>?
    @State private var isAnalyzing = false
    @State private var didComplete = false
    @State private var didCopyFeedback = false

    private var availableQuestions: [TestFlightFeedbackQuestion] {
        let configured = vm.feedbackQuestions
        return configured.isEmpty ? TestFlightFeedbackQuestion.defaultQuestions : configured
    }

    private var question: TestFlightFeedbackQuestion {
        if let stored = availableQuestions.first(where: { $0.id == storedQuestionId }) {
            return stored
        }
        return TestFlightFeedbackQuestion.questionForToday(in: availableQuestions)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                FeedbackIntroHeader(
                    developerProfileImageURL: vm.developerProfileImageURL
                )

                if let clarificationQuestion = analysis?.clarificationQuestion {
                    FeedbackClarificationEditor(
                        question: clarificationQuestion,
                        response: $clarificationResponse,
                        focusedField: $focusedField
                    )

                    FeedbackClarificationActions(
                        canSubmitResponse: !clarificationResponseTrimmed.isEmpty,
                        submitResponse: { submitClarification() },
                        skipQuestion: { submitWithoutClarification() }
                    )
                } else {
                    FeedbackQuestionEditor(
                        question: question,
                        answer: $answer,
                        focusedField: $focusedField
                    )

                    FeedbackInitialActions(
                        canSubmit: !answerTrimmed.isEmpty,
                        isAnalyzing: isAnalyzing,
                        allowsPasteboardExport: vm.allowsFeedbackPasteboardExport,
                        didCopyFeedback: didCopyFeedback,
                        submit: { beginSubmission() },
                        submitImmediately: { submitWithoutClarification() },
                        copyFeedback: { copyFeedback() },
                        skipFeedback: { skipFeedback() }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .onAppear {
            ensureQuestionForToday()
            AnalyticsManager.logEvent("TestFlight.Feedback.View", info: [
                "questionId": question.id,
                "screen": "testflight_feedback_sheet"
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                focusedField = .answer
            }
        }
        .onDisappear {
            analysisTask?.cancel()
            if !didComplete {
                markCompleted(reason: "dismiss")
            }
        }
    }
}

private extension Color {
    static var promptSecondaryBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var promptBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

private extension TestFlightFeedbackSheetView {
    var answerTrimmed: String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var clarificationResponseTrimmed: String {
        clarificationResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ensureQuestionForToday() {
        let calendar = Calendar.current
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: Date()) ?? 1
        guard storedQuestionDay != dayOfYear || storedQuestionId.isEmpty else { return }
        let todayQuestion = TestFlightFeedbackQuestion.questionForToday(in: availableQuestions)
        storedQuestionDay = dayOfYear
        storedQuestionId = todayQuestion.id
    }

    func beginSubmission() {
        guard !answerTrimmed.isEmpty, !isAnalyzing, submissionInput == nil else { return }
        let input = vm.makeFeedbackAnalysisInput(
            answer: answerTrimmed,
            questionID: question.id,
            questionTitle: question.title
        )
        submissionInput = input

        guard vm.feedbackClarificationMode == .onDevice else {
            finishSubmission(input: input, analysis: nil, clarificationResponse: nil, outcome: "disabled")
            return
        }

        isAnalyzing = true
        focusedField = nil
        analysisTask = Task {
            do {
                let result = try await vm.analyzeFeedback(input, screenshotSessionID: screenshotSessionID)
                guard !Task.isCancelled else { return }
                isAnalyzing = false

                guard let result else {
                    finishSubmission(input: input, analysis: nil, clarificationResponse: nil, outcome: "unavailable")
                    return
                }

                if result.clarificationQuestion == nil {
                    finishSubmission(input: input, analysis: result, clarificationResponse: nil, outcome: "no_question")
                    return
                }

                analysis = result
                AnalyticsManager.logEvent("TestFlight.Feedback.ClarificationShown", info: [
                    "category": result.category.rawValue,
                    "questionId": question.id,
                    "screen": "testflight_feedback_sheet"
                ])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focusedField = .clarification
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isAnalyzing = false
                finishSubmission(input: input, analysis: nil, clarificationResponse: nil, outcome: "error")
            }
        }
    }

    func submitClarification() {
        guard !clarificationResponseTrimmed.isEmpty,
              let input = submissionInput,
              let analysis else {
            return
        }
        finishSubmission(
            input: input,
            analysis: analysis,
            clarificationResponse: clarificationResponseTrimmed,
            outcome: "answered"
        )
    }

    func submitWithoutClarification() {
        guard let input = submissionInput else { return }
        analysisTask?.cancel()
        isAnalyzing = false
        finishSubmission(
            input: input,
            analysis: analysis,
            clarificationResponse: nil,
            outcome: analysis == nil ? "submitted_immediately" : "question_skipped"
        )
    }

    func finishSubmission(
        input: FeedbackAnalysisInput,
        analysis: BetaFeedbackClarificationAnalysis?,
        clarificationResponse: String?,
        outcome: String
    ) {
        guard !didComplete else { return }
        _ = vm.completeFeedback(
            input,
            analysis: analysis,
            clarificationResponse: clarificationResponse
        )
        didComplete = true

        AnalyticsManager.logEvent("TestFlight.Feedback.Submit", info: [
            "clarificationOutcome": outcome,
            "didClarify": clarificationResponse == nil ? "false" : "true",
            "questionId": input.questionID,
            "screen": "testflight_feedback_sheet"
        ])
        dismiss()
    }

    func copyFeedback() {
        didCopyFeedback = vm.copyFeedbackToPasteboard(
            answer: answerTrimmed,
            questionId: question.id,
            questionTitle: question.title
        )
        if didCopyFeedback {
            AnalyticsManager.logEvent("TestFlight.Feedback.CopyToPasteboard", info: [
                "questionId": question.id,
                "screen": "testflight_feedback_sheet"
            ])
        }
    }

    func skipFeedback() {
        markCompleted(reason: "skip")
        dismiss()
    }

    func markCompleted(reason: String) {
        guard !didComplete else { return }
        vm.hasShownTestFlightFeedbackPrompt = true
        didComplete = true
        AnalyticsManager.logEvent("TestFlight.Feedback.Skip", info: [
            "reason": reason,
            "questionId": question.id,
            "screen": "testflight_feedback_sheet"
        ])
    }
}

private enum FeedbackField: Hashable {
    case answer
    case clarification
}

private struct FeedbackIntroHeader: View {
    let developerProfileImageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProfileStackView(
                appIcon: true,
                remoteProfileURL: developerProfileImageURL,
                fallbackImageNames: ["andreas_pfp"],
                size: 54,
                overlap: 16
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Thank you for testing this :)")
                    .font(.title3.weight(.semibold))
                Text("Your quick feedback really helps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FeedbackQuestionEditor: View {
    let question: TestFlightFeedbackQuestion
    @Binding var answer: String
    var focusedField: FocusState<FeedbackField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PromptHeaderView(
                title: "Quick TestFlight question",
                subtitle: question.title,
                titleFont: .title2.weight(.bold),
                subtitleFont: .callout,
                titleColor: .primary,
                subtitleColor: .secondary,
                spacing: 6
            )

            PromptCardView(background: AnyShapeStyle(Color.promptSecondaryBackground), cornerRadius: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.helperText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(question.placeholder, text: $answer, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.promptBackground)
                        )
                        .focused(focusedField, equals: .answer)
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct FeedbackClarificationEditor: View {
    let question: String
    @Binding var response: String
    var focusedField: FocusState<FeedbackField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PromptHeaderView(
                title: "One quick question",
                subtitle: question,
                titleFont: .title2.weight(.bold),
                subtitleFont: .callout,
                titleColor: .primary,
                subtitleColor: .secondary,
                spacing: 6
            )

            PromptCardView(background: AnyShapeStyle(Color.promptSecondaryBackground), cornerRadius: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A short answer can make this report much easier to act on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("What happened?", text: $response, axis: .vertical)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Clarification response")
                        .accessibilityHint(question)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.promptBackground)
                        )
                        .focused(focusedField, equals: .clarification)
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct FeedbackInitialActions: View {
    let canSubmit: Bool
    let isAnalyzing: Bool
    let allowsPasteboardExport: Bool
    let didCopyFeedback: Bool
    let submit: () -> Void
    let submitImmediately: () -> Void
    let copyFeedback: () -> Void
    let skipFeedback: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isAnalyzing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking whether one detail would help...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                Button(action: { submitImmediately() }) {
                    Text("Submit without clarification")
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { submit() }) {
                    Label {
                        Text("Submit")
                    } icon: {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(BetaButtonStyle())
                .disabled(!canSubmit)

                if allowsPasteboardExport {
                    Button(action: { copyFeedback() }) {
                        Label {
                            Text(didCopyFeedback ? "Copied" : "Copy response + context")
                        } icon: {
                            Image(systemName: didCopyFeedback ? "checkmark" : "doc.on.doc")
                        }
                    }
                    .disabled(!canSubmit)
                }

                Button(action: { skipFeedback() }) {
                    Text("Skip")
                }
                .buttonStyle(.plain)
                .opacity(0.6)
            }
        }
        .padding(.top, 4)
    }
}

private struct FeedbackClarificationActions: View {
    let canSubmitResponse: Bool
    let submitResponse: () -> Void
    let skipQuestion: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: { submitResponse() }) {
                Label {
                    Text("Submit feedback")
                } icon: {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(BetaButtonStyle())
            .disabled(!canSubmitResponse)

            Button(action: { skipQuestion() }) {
                Text("Skip question and submit")
            }
            .buttonStyle(.plain)
            .opacity(0.7)
        }
        .padding(.top, 4)
    }
}

#Preview {
    TestFlightFeedbackSheetView()
        .environment(BetaContentViewModel())
}

#Preview("One-question clarification") {
    FeedbackClarificationPreview()
}

private struct FeedbackClarificationPreview: View {
    @State private var response = "Nothing happened. The button highlighted, but I stayed on Checkout."
    @FocusState private var focusedField: FeedbackField?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                FeedbackIntroHeader(developerProfileImageURL: nil)
                FeedbackClarificationEditor(
                    question: "When you tapped Continue, did nothing happen, or did you see an error?",
                    response: $response,
                    focusedField: $focusedField
                )
                FeedbackClarificationActions(
                    canSubmitResponse: !response.isEmpty,
                    submitResponse: {},
                    skipQuestion: {}
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }
}
