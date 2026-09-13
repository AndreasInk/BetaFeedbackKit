import CoreGraphics
import Foundation
import Testing
@testable import BetaFeedbackKit

@MainActor private final class CaptureCounter {
    var calls = 0
    var sheetWasAbsent = true
    weak var viewModel: BetaContentViewModel?
    let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                          bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    func capture() -> CGImage? {
        calls += 1
        sheetWasAbsent = viewModel?.presentedSheet == nil
        return image
    }
}

@Test @MainActor func sheetScreenshotCapturedBeforePresentationAndOnlyOnce() {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let counter = CaptureCounter()
    let vm = BetaContentViewModel(feedbackClarificationMode: .onDevice, feedbackScreenshotProvider: { counter.capture() })
    counter.viewModel = vm
    vm.presentTestFlightFeedbackPrompt()
    vm.presentTestFlightFeedbackPrompt()
    #expect(counter.calls == 1)
    #expect(counter.sheetWasAbsent)
    #expect(vm.activeSheetScreenshot === counter.image)
    vm.dismissPresentedSheet()
    #expect(vm.activeSheetScreenshot == nil)
    vm.presentTestFlightFeedbackPrompt()
    #expect(counter.calls == 2)
}

@Test @MainActor func screenshotReleasedWhenReportCompletes() {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let counter = CaptureCounter()
    let vm = BetaContentViewModel(feedbackClarificationMode: .onDevice, feedbackScreenshotProvider: { counter.capture() })
    vm.presentTestFlightFeedbackPrompt()
    let input = vm.makeFeedbackAnalysisInput(answer: "Original words", questionID: "test", questionTitle: "Feedback")
    let report = vm.completeFeedback(input, analysis: nil, clarificationResponse: nil)
    #expect(vm.activeSheetScreenshot == nil)
    #expect(report.originalFeedback == "Original words")
}

private actor CaptureAnalyzer: FeedbackAnalyzing {
    var calls = 0
    func analyze(_ input: FeedbackAnalysisInput, screenshot: CGImage?) async throws -> BetaFeedbackClarificationAnalysis? {
        calls += 1
        return nil
    }
}

@Test @MainActor func missingScreenshotSkipsModelWithoutLosingResponse() async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let analyzer = CaptureAnalyzer()
    let vm = BetaContentViewModel(feedbackClarificationMode: .onDevice, feedbackScreenshotProvider: { nil })
    vm.feedbackAnalyzer = analyzer
    vm.presentTestFlightFeedbackPrompt()
    let input = vm.makeFeedbackAnalysisInput(answer: "Original words", questionID: "test", questionTitle: "Feedback")
    #expect(try await vm.analyzeFeedback(input) == nil)
    #expect(await analyzer.calls == 0)
    #expect(vm.completeFeedback(input, analysis: nil, clarificationResponse: nil).originalFeedback == "Original words")
}

@Test @MainActor func automaticCaptureWithoutMountedWindowIsUnavailable() {
    let vm = BetaContentViewModel()
    #expect(vm.captureFeedbackScreenshot() == nil)
}

@Test @MainActor func resumedSheetDoesNotRecaptureUnrelatedScreen() {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let counter = CaptureCounter()
    let vm = BetaContentViewModel(feedbackClarificationMode: .onDevice, feedbackScreenshotProvider: { counter.capture() })
    vm.presentTestFlightFeedbackPrompt(capturedScreenshot: nil)
    #expect(counter.calls == 0)
    #expect(vm.activeSheetScreenshot == nil)
}

@Test @MainActor func disabledClarificationDoesNotCaptureScreenshot() {
    let counter = CaptureCounter()
    let vm = BetaContentViewModel(feedbackScreenshotProvider: { counter.capture() })
    vm.presentTestFlightFeedbackPrompt()
    #expect(counter.calls == 0)
}

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor private func makeCaptureTestWindow() -> FeedbackNativeWindow {
#if os(macOS)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                          styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
#else
    return UIWindow(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
#endif
}

@Test @MainActor func windowRegistrationDeduplicatesAndRejectsAmbiguity() {
    let capture = FeedbackWindowCapture()
    let first = makeCaptureTestWindow()
    let second = makeCaptureTestWindow()
    let firstOwner = UUID(), duplicateOwner = UUID(), secondOwner = UUID()
    capture.register(first, owner: firstOwner)
    capture.register(first, owner: duplicateOwner)
    #expect(capture.registeredWindow === first)
    capture.register(second, owner: secondOwner)
    #expect(capture.registeredWindow == nil)
    #expect(capture.capture() == nil)
    capture.register(nil, owner: secondOwner)
    #expect(capture.registeredWindow === first)
    capture.register(nil, owner: firstOwner)
    #expect(capture.registeredWindow === first)
    capture.register(nil, owner: duplicateOwner)
    #expect(capture.registeredWindow == nil)
}

@Test @MainActor func mountedRegistrationReleasesWindowOnTeardown() {
    let capture = FeedbackWindowCapture()
    let window = makeCaptureTestWindow()
    let registration = FeedbackWindowRegistration.RegistrationView(capture: capture)
#if os(macOS)
    window.contentView?.addSubview(registration)
#elseif os(iOS)
    window.addSubview(registration)
#endif
    #expect(capture.registeredWindow === window)
    registration.removeFromSuperview()
    #expect(capture.registeredWindow == nil)
}

@Test @MainActor func oldSheetDisappearanceCannotReleaseNewSheetImage() {
    let first = CaptureCounter(), second = CaptureCounter()
    let vm = BetaContentViewModel()
    vm.presentTestFlightFeedbackPrompt(capturedScreenshot: first.image)
    let firstID = vm.activeSheetCaptureID
    vm.dismissPresentedSheet()
    vm.presentTestFlightFeedbackPrompt(capturedScreenshot: second.image)
    let secondID = vm.activeSheetCaptureID
    vm.releaseSheetScreenshot(ifCurrent: firstID)
    #expect(vm.activeSheetCaptureID == secondID)
    #expect(vm.activeSheetScreenshot === second.image)
    vm.releaseSheetScreenshot(ifCurrent: secondID)
    #expect(vm.activeSheetScreenshot == nil)
}

@Test @MainActor func supersededScreenshotCannotConsumeOrClearNewImage() {
    let first = CaptureCounter(), second = CaptureCounter()
    var buffer = FeedbackScreenshotCaptureBuffer()
    buffer.record(first.image, generation: 1)
    buffer.record(second.image, generation: 2)
    #expect(buffer.take(for: 1) == nil)
    buffer.discard(for: 1)
    #expect(buffer.generation == 2)
    #expect(buffer.image === second.image)
    #expect(buffer.take(for: 2) === second.image)
    #expect(buffer.image == nil)
    #expect(buffer.generation == nil)
    #expect(buffer.take(for: 2) == nil)
}

@Test @MainActor func failedNewCaptureNeverReusesPreviousImage() {
    let first = CaptureCounter()
    var buffer = FeedbackScreenshotCaptureBuffer()
    buffer.record(first.image, generation: 1)
    buffer.record(nil, generation: 2)
    #expect(buffer.take(for: 2) == nil)
    #expect(buffer.take(for: 1) == nil)
    #expect(buffer.image == nil)
}

@Test @MainActor func staleSheetCannotAnalyzeWithReplacementImage() async throws {
    let first = CaptureCounter(), second = CaptureCounter()
    let analyzer = CaptureAnalyzer()
    let vm = BetaContentViewModel(feedbackClarificationMode: .onDevice)
    vm.feedbackAnalyzer = analyzer
    vm.presentTestFlightFeedbackPrompt(capturedScreenshot: first.image)
    let firstID = try #require(vm.activeSheetCaptureID)
    vm.dismissPresentedSheet()
    vm.presentTestFlightFeedbackPrompt(capturedScreenshot: second.image)
    let input = vm.makeFeedbackAnalysisInput(answer: "Original screen", questionID: "test", questionTitle: "Feedback")
    do {
        _ = try await vm.analyzeFeedback(input, screenshotSessionID: firstID)
        Issue.record("A superseded sheet should cancel analysis")
    } catch is CancellationError {}
    #expect(await analyzer.calls == 0)
    #expect(vm.activeSheetScreenshot === second.image)
}
