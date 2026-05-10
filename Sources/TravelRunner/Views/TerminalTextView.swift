import SwiftUI
import AppKit

class TerminalNSTextView: NSTextView {
    var isMouseDragging = false
    private var scrollMonitor: Any?

    override func mouseDown(with event: NSEvent) {
        isMouseDragging = true

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] scrollEvent in
            self?.enclosingScrollView?.scrollWheel(with: scrollEvent)
            return nil
        }

        super.mouseDown(with: event)

        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        isMouseDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        autoscroll(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}

struct TerminalTextView: NSViewRepresentable {
    let entries: [LogEntry]
    let autoScroll: Bool
    let format: (LogEntry) -> (text: String, color: NSColor)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TerminalNSTextView.scrollableTextView()
        let textView = scrollView.documentView as! TerminalNSTextView

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.black.withAlphaComponent(0.9)
        scrollView.scrollerStyle = .overlay

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .white
        textView.insertionPointColor = .white

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        let prevCount = context.coordinator.lastEntryCount
        let prevID = context.coordinator.lastEntryID
        guard entries.count != prevCount || entries.last?.id != prevID else { return }

        if textView.isMouseDragging { return }

        let selectedRange = textView.selectedRange()
        let hasSelection = selectedRange.length > 0
        let wasAtBottom = context.coordinator.isAtBottom(scrollView)

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1

        let canIncrement = entries.count > prevCount
            && prevCount > 0
            && prevID != nil
            && entries[prevCount - 1].id == prevID

        if canIncrement {
            let newEntries = entries[prevCount...]
            let appended = NSMutableAttributedString()
            for entry in newEntries {
                let formatted = format(entry)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: formatted.color,
                    .paragraphStyle: paragraphStyle,
                ]
                appended.append(NSAttributedString(string: formatted.text + "\n", attributes: attrs))
            }
            textView.textStorage?.append(appended)
        } else {
            let attributed = NSMutableAttributedString()
            for entry in entries {
                let formatted = format(entry)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: formatted.color,
                    .paragraphStyle: paragraphStyle,
                ]
                attributed.append(NSAttributedString(string: formatted.text + "\n", attributes: attrs))
            }
            textView.textStorage?.setAttributedString(attributed)
        }

        context.coordinator.lastEntryCount = entries.count
        context.coordinator.lastEntryID = entries.last?.id

        if hasSelection {
            let maxRange = (textView.textStorage?.length ?? 0)
            let safeRange = NSRange(
                location: min(selectedRange.location, maxRange),
                length: min(selectedRange.length, maxRange - min(selectedRange.location, maxRange))
            )
            textView.setSelectedRange(safeRange)
        }

        let mouseIsDown = NSEvent.pressedMouseButtons != 0
        if autoScroll && !hasSelection && !mouseIsDown && (wasAtBottom || prevCount == 0) {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var textView: TerminalNSTextView?
        var scrollView: NSScrollView?
        var lastEntryCount: Int = 0
        var lastEntryID: UUID?

        @MainActor func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            guard let docView = scrollView.documentView else { return true }
            let visibleRect = scrollView.contentView.bounds
            let docHeight = docView.frame.height
            return visibleRect.maxY >= docHeight - 20
        }
    }
}
