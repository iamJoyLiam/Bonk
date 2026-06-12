//
//  SplitPaneView.swift
//  Bonk
//

import SwiftUI

/// Renders a split pane tree with draggable dividers.
struct SplitPaneView: View {
    @Binding var pane: SplitPane
    @Binding var activePaneID: UUID?
    let terminalBuilder: (UUID) -> AnyView

    var body: some View {
        switch pane {
        case let .single(terminalPane):
            terminalBuilder(terminalPane.id)
                .onTapGesture {
                    activePaneID = terminalPane.id
                }
                .overlay(alignment: .topTrailing) {
                    if activePaneID == terminalPane.id {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .padding(1)
                    }
                }

        case let .horizontal(left, right, ratio):
            SplitPaneContainer(
                direction: .horizontal,
                ratio: Binding(
                    get: { ratio },
                    set: { newRatio in
                        pane = .horizontal(left: left, right: right, ratio: newRatio)
                    }
                ),
                leading: SplitPaneView(
                    pane: Binding(
                        get: { left },
                        set: { newLeft in
                            pane = .horizontal(left: newLeft, right: right, ratio: ratio)
                        }
                    ),
                    activePaneID: $activePaneID,
                    terminalBuilder: terminalBuilder
                ),
                trailing: SplitPaneView(
                    pane: Binding(
                        get: { right },
                        set: { newRight in
                            pane = .horizontal(left: left, right: newRight, ratio: ratio)
                        }
                    ),
                    activePaneID: $activePaneID,
                    terminalBuilder: terminalBuilder
                )
            )

        case let .vertical(top, bottom, ratio):
            SplitPaneContainer(
                direction: .vertical,
                ratio: Binding(
                    get: { ratio },
                    set: { newRatio in
                        pane = .vertical(top: top, bottom: bottom, ratio: newRatio)
                    }
                ),
                leading: SplitPaneView(
                    pane: Binding(
                        get: { top },
                        set: { newTop in
                            pane = .vertical(top: newTop, bottom: bottom, ratio: ratio)
                        }
                    ),
                    activePaneID: $activePaneID,
                    terminalBuilder: terminalBuilder
                ),
                trailing: SplitPaneView(
                    pane: Binding(
                        get: { bottom },
                        set: { newBottom in
                            pane = .vertical(top: top, bottom: newBottom, ratio: ratio)
                        }
                    ),
                    activePaneID: $activePaneID,
                    terminalBuilder: terminalBuilder
                )
            )
        }
    }
}
