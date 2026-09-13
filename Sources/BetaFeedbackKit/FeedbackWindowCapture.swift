import SwiftUI
import CoreGraphics
#if os(iOS)
import UIKit
typealias FeedbackNativeWindow = UIWindow
#elseif os(macOS)
import AppKit
typealias FeedbackNativeWindow = NSWindow
#endif

/// Only windows hosting this particular feedback view model are eligible.
@MainActor
final class FeedbackWindowCapture {
    private final class Entry {
        weak var window: FeedbackNativeWindow?
        init(_ window: FeedbackNativeWindow) { self.window = window }
    }
    private var windows: [UUID: Entry] = [:]

    func register(_ window: FeedbackNativeWindow?, owner: UUID) {
        windows[owner] = window.map(Entry.init)
    }

    var registeredWindow: FeedbackNativeWindow? {
        let live = windows.values.compactMap(\.window)
        let unique = Dictionary(live.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        // Multiple mounted windows are ambiguous; never guess which screen was reported.
        return unique.count == 1 ? unique.values.first : nil
    }

    func capture() -> CGImage? {
        guard let window = registeredWindow else { return nil }
#if os(iOS)
        guard !window.isHidden, window.windowScene?.activationState == .foregroundActive,
              !window.bounds.isEmpty else { return nil }
        var didDraw = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            didDraw = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return didDraw ? image.cgImage : nil
#elseif os(macOS)
        guard window.isVisible, let content = window.contentView,
              !content.bounds.isEmpty,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        return bitmap.cgImage
#endif
    }
}

#if os(iOS)
struct FeedbackWindowRegistration: UIViewRepresentable {
    let capture: FeedbackWindowCapture
    func makeUIView(context: Context) -> RegistrationView { RegistrationView(capture: capture) }
    func updateUIView(_ uiView: RegistrationView, context: Context) {}
    static func dismantleUIView(_ uiView: RegistrationView, coordinator: ()) { uiView.unregister() }
    final class RegistrationView: UIView {
        let capture: FeedbackWindowCapture
        let owner = UUID()
        init(capture: FeedbackWindowCapture) {
            self.capture = capture
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            capture.register(window, owner: owner)
        }
        func unregister() { capture.register(nil, owner: owner) }
    }
}
#elseif os(macOS)
struct FeedbackWindowRegistration: NSViewRepresentable {
    let capture: FeedbackWindowCapture
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(capture: capture) }
    func updateNSView(_ nsView: RegistrationView, context: Context) {}
    static func dismantleNSView(_ nsView: RegistrationView, coordinator: ()) { nsView.unregister() }
    final class RegistrationView: NSView {
        let capture: FeedbackWindowCapture
        let owner = UUID()
        init(capture: FeedbackWindowCapture) {
            self.capture = capture
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            capture.register(window, owner: owner)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func unregister() { capture.register(nil, owner: owner) }
    }
}
#endif

/// Transient image handoff across permission/guidance awaits. A superseded operation
/// can neither consume nor release a newer screenshot.
struct FeedbackScreenshotCaptureBuffer {
    private(set) var generation: UInt64?
    private(set) var image: CGImage?

    mutating func record(_ image: CGImage?, generation: UInt64) {
        self.generation = generation
        self.image = image
    }

    mutating func take(for generation: UInt64) -> CGImage? {
        guard self.generation == generation else { return nil }
        let captured = image
        discard(for: generation)
        return captured
    }

    mutating func discard(for generation: UInt64) {
        guard self.generation == generation else { return }
        self.generation = nil
        image = nil
    }
}
