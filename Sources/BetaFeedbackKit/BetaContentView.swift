//
//  ScreenshotBetaFeedbackView.swift
//  BetaFeedbackKit
//
//  Created by Andreas Ink on 2/6/26.
//

import SwiftUI

struct BetaScreenshotGuidance: Equatable {
    let title: String
    let message: String

    static func make(
        notificationConversationExpected: Bool,
        notificationMode: BetaFeedbackNotificationMode,
        customTitle: String,
        customMessage: String
    ) -> Self {
        if notificationConversationExpected {
            return Self(
                title: "What feedback do you have?",
                message: "Tap the screenshot thumbnail. Then press and hold the notification, then tap Reply. The app may ask one optional follow-up to help improve the app."
            )
        }
        if notificationMode == .onScreenshot {
            return Self(
                title: "Share through TestFlight",
                message: "Tap the screenshot preview, tap the checkmark, then choose Share Beta Feedback."
            )
        }
        return Self(title: customTitle, message: customMessage)
    }
}

struct BetaScreenshotContextSummary: Equatable {
    let text: String

    static func make(from context: [String: String]) -> Self? {
        let screen = firstReadableValue(
            context["screen_summary"],
            context["screen"]
        )
        let feature = readableValue(context["feature"])

        if let screen { return Self(text: screen) }
        if let feature {
            return Self(text: feature)
        }
        return nil
    }

    private static func firstReadableValue(_ values: String?...) -> String? {
        values.compactMap(readableValue).first
    }

    private static func readableValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
    }
}

private struct BetaScreenshotPopoverView: View {
    let guidance: BetaScreenshotGuidance
    let context: BetaScreenshotContextSummary?
    let backgroundMaterial: Material?

    @ViewBuilder
    var body: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            Label(guidance.title, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .symbolRenderingMode(.hierarchical)

            Text(guidance.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let context {
                Divider()
                Label(context.text, systemImage: "viewfinder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(16)
        .frame(idealWidth: 280, maxWidth: 300, alignment: .leading)
        .accessibilityElement(children: .combine)

        if let backgroundMaterial {
            content.presentationBackground(backgroundMaterial)
        } else {
            content
        }
    }
}

public struct BetaContentView<Content: View>: View {

    @Bindable var viewModel: BetaContentViewModel
    @State private var screenshotContext: [String: String] = [:]
    @State private var screenshotOverlayDismissalID = 0

    var backgroundMaterial: Material?
    var backgroundCardView: Content
    var foregroundCardStyle: Color = Color.white
    var screenshotPromptTitle: String
    var screenshotPromptSubtitle: String
    var triggerAction: (() -> Void)?


    public init(viewModel: BetaContentViewModel,
                backgroundMaterial: Material?,
                foregroundCardStyle: Color = Color.white,
                screenshotPromptTitle: String = "Want to share quick beta feedback?",
                screenshotPromptSubtitle: String = "Take a screenshot and we’ll guide you from there.",
                triggerAction: (() -> Void)? = nil,
                @ViewBuilder background: @escaping () -> Content) {
        self.viewModel = viewModel
        self.backgroundMaterial = backgroundMaterial
        self.triggerAction = triggerAction
        self.foregroundCardStyle = foregroundCardStyle
        self.screenshotPromptTitle = screenshotPromptTitle
        self.screenshotPromptSubtitle = screenshotPromptSubtitle
        self.backgroundCardView = background()
    }
    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
#if os(iOS)
                screenshotPreviewAnchor
                    .allowsHitTesting(false)
                    .popover(
                        isPresented: screenshotPopoverBinding,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .bottom
                    ) {
                        screenshotPopoverContent
                            .presentationCompactAdaptation(.popover)
                    }
#else
                if let backgroundMaterial {
                    Rectangle()
                        .foregroundStyle(backgroundMaterial)
                        .ignoresSafeArea()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(screenshotPromptTitle)
                        .font(.headline)
                    Text(screenshotPromptSubtitle)
                        .font(.callout)
                }
                .foregroundStyle(foregroundCardStyle)
                .minimumScaleFactor(0.3)
                .padding(18)
                .background {
                    backgroundCardView
                }
                .frame(width: geometry.size.width / 3,
                       height: geometry.size.height / 3)
                .padding(.leading, 12)
                .padding(.bottom, geometry.size.height / 3.5)
                .scaleEffect(0.65)
                .blur(radius: viewModel.showScreenshotOverlay ? 0 : 20)
                .offset(x: viewModel.showScreenshotOverlay ? 0 : -100)
                .opacity(viewModel.showScreenshotOverlay ? 1 : 0)
#endif
            }
            .background { FeedbackWindowRegistration(capture: viewModel.feedbackWindowCapture) }
            .sheet(item: presentedSheetBinding) { sheet in
                switch sheet {
                case .testFlightFeedbackPrompt:
                    let captureID = viewModel.activeSheetCaptureID
                    TestFlightFeedbackSheetView(screenshotSessionID: captureID)
                        .id(captureID)
                        .onDisappear { viewModel.releaseSheetScreenshot(ifCurrent: captureID) }
                        .environment(viewModel)
                        .presentationDetents([.medium])
                case .testFlightScreenshotTip:
                    TestFlightScreenshotTipView()
                        .environment(viewModel)
                        .presentationDetents([.medium])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .betaFeedbackKitTestFlightScreenshotTaken)) { notification in
                guard BetaContentViewModel.isDebugOrTestFlight() else { return }
                if let notificationConversationExpected = notification.userInfo?[
                    BetaFeedbackKitScreenshotEventKey.notificationConversationExpected
                ] as? Bool {
                    viewModel.screenshotNotificationConversationExpected = notificationConversationExpected
                }
                screenshotContext = viewModel.feedbackContextProvider()
                withAnimation {
                    viewModel.showScreenshotOverlay = true
                }
                screenshotOverlayDismissalID &+= 1
            }
            .task(id: screenshotOverlayDismissalID) {
                guard screenshotOverlayDismissalID > 0 else { return }
                do {
                    try await Task.sleep(for: .seconds(6))
                } catch {
                    return
                }
                withAnimation {
                    viewModel.showScreenshotOverlay = false
                }
            }
            .environment(viewModel)
        }
    }

#if os(iOS)
    private var screenshotPreviewAnchor: some View {
        Color.clear
            .frame(width: 96, height: 172)
            .padding(.leading, 12)
            .padding(.bottom, 32)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var screenshotPopoverContent: some View {
        let guidance = BetaScreenshotGuidance.make(
            notificationConversationExpected: viewModel.screenshotNotificationConversationExpected,
            notificationMode: viewModel.feedbackNotificationMode,
            customTitle: screenshotPromptTitle,
            customMessage: screenshotPromptSubtitle
        )
        BetaScreenshotPopoverView(
            guidance: guidance,
            context: BetaScreenshotContextSummary.make(from: screenshotContext),
            backgroundMaterial: backgroundMaterial
        )
    }

    private var screenshotPopoverBinding: Binding<Bool> {
        Binding {
            viewModel.showScreenshotOverlay
        } set: { isPresented in
            viewModel.showScreenshotOverlay = isPresented
        }
    }
#endif

    private var presentedSheetBinding: Binding<BetaContentViewModel.PresentedSheet?> {
        Binding {
            viewModel.presentedSheet
        } set: { newValue in
            viewModel.presentedSheet = newValue
        }
    }
}

#Preview {
    @Previewable @State var viewModel = BetaContentViewModel(
        feedbackContextProvider: {
            [
                "screen_summary": "home 2.0 scaffold dashboard",
                "feature": "home_experiment",
            ]
        },
        feedbackNotificationMode: .onScreenshot
    )
    VStack(spacing: 12) {
        Text("Parent view remains visible")
            .font(.title2.weight(.semibold))
        Text("BetaContentView is attached as an overlay.")
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.08))
    .beta(
        viewModel: viewModel,
        backgroundMaterial: .thickMaterial,
        foregroundCardStyle: .blue
    )
    .task {
        try? await Task.sleep(for: .milliseconds(250))
        NotificationCenter.default.post(
            name: .betaFeedbackKitTestFlightScreenshotTaken,
            object: nil,
            userInfo: [
                BetaFeedbackKitScreenshotEventKey.notificationConversationExpected: true
            ]
        )
    }
}

#Preview("Screenshot popover") {
    BetaScreenshotPopoverView(
        guidance: BetaScreenshotGuidance.make(
            notificationConversationExpected: true,
            notificationMode: .onScreenshot,
            customTitle: "",
            customMessage: ""
        ),
        context: BetaScreenshotContextSummary(
            text: "Home 2.0 scaffold dashboard"
        ),
        backgroundMaterial: .regularMaterial
    )
    .padding(24)
    .background(Color.secondary.opacity(0.08))
}
