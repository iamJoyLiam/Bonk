//
//  SplitDivider.swift
//  Bonk
//
//  Visible divider between split panes.
//

import SwiftUI

/// A visible divider between split panes.
struct SplitDivider: View {
    enum Direction { case horizontal, vertical }

    let direction: Direction

    var body: some View {
        switch direction {
        case .horizontal:
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        case .vertical:
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }
}
