//
//  InlineCandidatePopover.swift
//  Bonk
//
//  Native macOS NSPopover presenting inline candidate completions near the cursor.
//  Uses system vibrancy popover material, adaptive width for long commands,
//  keyboard and mouse selection, and non-stealing focus behavior.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class InlineCandidatePopoverState {
    var items: [String] = []
    var selectedIndex: Int? = nil

    func preferredSize(font: NSFont, maxAvailableWidth: CGFloat = 650) -> NSSize {
        guard !items.isEmpty else { return .zero }
        let itemWidths = items.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let maxTextWidth = itemWidths.max() ?? 200
        // Horizontal padding: sparkle icon (16) + spacing (8) + text + trailing padding (16) + margins (16)
        let neededWidth = maxTextWidth + 56
        let clampedWidth = min(max(neededWidth, 240), max(300, maxAvailableWidth))
        let height = CGFloat(items.count) * 26 + 12
        return NSSize(width: clampedWidth, height: height)
    }
}

struct InlineCandidatePopoverView: View {
    @Bindable var state: InlineCandidatePopoverState
    var onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                let isSelected = state.selectedIndex == index
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.5))
                        .frame(width: 12)

                    Text(item)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(index)
                }
            }
        }
        .padding(6)
    }
}

@MainActor
final class InlineCandidatePopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private let state = InlineCandidatePopoverState()
    private weak var ownerView: NSView?
    private var onSelectHandler: ((Int) -> Void)?

    init(owner: NSView, onSelect: @escaping (Int) -> Void) {
        self.ownerView = owner
        self.onSelectHandler = onSelect
        super.init()
    }

    func show(items: [String], selectedIndex: Int?, cursorRect: NSRect, font: NSFont) {
        guard let owner = ownerView, owner.window?.firstResponder === owner else {
            hide()
            return
        }

        let capped = Array(items.prefix(5))
        state.items = capped
        state.selectedIndex = selectedIndex

        let maxAvailableWidth = (owner.window?.frame.width ?? 800) - 40
        let contentSize = state.preferredSize(font: font, maxAvailableWidth: maxAvailableWidth)

        if let existing = popover, existing.isShown {
            existing.animates = false
            existing.contentSize = contentSize
            existing.positioningRect = cursorRect
            return
        }

        let pop = NSPopover()
        pop.behavior = .semitransient
        pop.animates = false
        pop.delegate = self

        let view = InlineCandidatePopoverView(state: state) { [weak self] index in
            self?.onSelectHandler?(index)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        let vc = NSViewController()
        vc.view = hosting

        pop.contentViewController = vc
        pop.contentSize = contentSize
        pop.show(relativeTo: cursorRect, of: owner, preferredEdge: .maxY)
        popover = pop

        // Ensure key focus remains firmly on the terminal
        owner.window?.makeFirstResponder(owner)
    }

    func updateCursorRect(_ rect: NSRect) {
        guard let pop = popover, pop.isShown else { return }
        pop.positioningRect = rect
    }

    func hide() {
        popover?.close()
        popover = nil
    }

    func isShown() -> Bool {
        popover?.isShown == true
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}
