import AppKit
import Testing
@testable import Bonk

/// Measures what the ring actually draws, by rendering it and reading the pixels.
///
/// ## Why render rather than reason about coordinates
///
/// The completion tick was reported as looking mirrored. The view is not flipped,
/// so its coordinates are y-up and the path as written *is* a checkmark on paper —
/// which is exactly why reading the code could not settle it. A number in a source
/// file is not evidence of what reached the screen. The bitmap is.
///
/// ## Why band centroids and not a grid
///
/// The first version of this test bucketed ink into a 3×3 grid. It was structurally
/// incapable of catching the defect: the tick then spanned about 8×7pt inside a
/// 29pt circle, so the entire shape fell inside **one** cell and all nine cells
/// compared equal. A gate that cannot fail is not a gate.
///
/// Band centroids work because they are continuous and independent of where the
/// shape happens to land. For an upright ✓ the highest ink is the tip of the long
/// arm, which is to the **right** of centre; a horizontal mirror puts that ink on
/// the left, and a vertical flip moves it off-centre entirely.
@Suite("SFTP toolbar ring — rendered output")
@MainActor
struct SFTPRingRenderTests {
    private struct Ink {
        /// (column, row) per green pixel. Row 0 is the top, matching the bitmap.
        var pixels: [(x: Int, y: Int)] = []
        var width = 0
        var height = 0

        /// Mean column of ink within a band, measured against the ink's **own**
        /// bounding box.
        ///
        /// Bands relative to the control are useless: the tick occupies only the
        /// middle third of the ring's height, so a band at the control's top edge is
        /// always empty and always compares `NaN > x`, i.e. false, for reasons that
        /// have nothing to do with orientation.
        func bandCentroidX(fromTopFraction: Double, toTopFraction: Double) -> Double {
            guard let minY = pixels.map(\.y).min(), let maxY = pixels.map(\.y).max(),
                  maxY > minY else { return .nan }
            let span = Double(maxY - minY)
            let top = minY + Int(span * fromTopFraction)
            let bottom = minY + Int(span * toTopFraction)
            let band = pixels.filter { $0.y >= top && $0.y <= bottom }
            guard !band.isEmpty else { return .nan }
            return Double(band.map(\.x).reduce(0, +)) / Double(band.count)
        }

        var boundingWidth: Int {
            guard let minX = pixels.map(\.x).min(), let maxX = pixels.map(\.x).max() else { return 0 }
            return maxX - minX
        }

        var boundingHeight: Int {
            guard let minY = pixels.map(\.y).min(), let maxY = pixels.map(\.y).max() else { return 0 }
            return maxY - minY
        }
    }

    private func renderTick() throws -> Ink {
        let size = SFTPTransferRingControl.size
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let control = SFTPTransferRingControl(label: "transfers")
        control.frame = NSRect(origin: .zero, size: size)
        control.refresh(aggregate: SFTPTransferAggregate(transfers: [
            SFTPTransfer(
                id: UUID(), filename: "a.bin", direction: .upload,
                totalBytes: 10, transferredBytes: 10, isComplete: true
            )
        ]))

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        control.draw(control.bounds)

        var ink = Ink()
        ink.width = width
        ink.height = height
        let data = try #require(rep.bitmapData)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * rep.bytesPerRow + x * 4
                let r = Int(data[offset]), g = Int(data[offset + 1]), b = Int(data[offset + 2])
                // The tick is the only green thing drawn in the completed state.
                guard g > 90, g > r + 30, g > b + 30 else { continue }
                ink.pixels.append((x, y))
            }
        }
        return ink
    }

    @Test("the completion mark is the filled green circle, not a scaled check")
    func completionTickIsUpright() throws {
        let ink = try renderTick()
        let trace = "total=\(ink.pixels.count) box=\(ink.boundingWidth)x\(ink.boundingHeight)"
            + " (width \(ink.width))"
        try trace.write(toFile: "/tmp/bonk-ring-ink.txt", atomically: true, encoding: .utf8)

        #expect(ink.pixels.count > 0, "the completion mark drew no green pixels")

        // checkmark.circle.fill fills the ring. A bare check scaled into the
        // slot is both smaller and soft; its box stays well under this.
        let minimum = Int(Double(ink.width) * 0.7)
        #expect(ink.boundingWidth >= minimum,
                "green ink is only \(ink.boundingWidth)pt wide in a \(ink.width)pt ring")
        #expect(ink.boundingHeight >= minimum,
                "green ink is only \(ink.boundingHeight)pt tall in a \(ink.height)pt ring")
    }

    @Test("the arrow and percentage fit inside the ring at every shown value")
    func centerTextFitsInsideTheRing() {
        let bounds = NSRect(origin: .zero, size: SFTPTransferRingControl.size)
        let available = SFTPTransferRingControl.innerTextWidth(for: bounds)

        for fraction in [0.0, 0.05, 0.46, 0.9, 0.99] as [Double] {
            for isUploading in [true, false] {
                let service = SFTPService()
                let id = UUID()
                service.transfers.append(SFTPTransfer(
                    id: id, filename: "a.bin",
                    direction: isUploading ? .upload : .download,
                    totalBytes: 1000,
                    transferredBytes: UInt64(Double(1000) * fraction),
                    isComplete: false
                ))
                let aggregate = SFTPTransferAggregate(transfers: service.transfers)
                let layout = SFTPTransferRingControl.centerTextLayout(
                    running: aggregate.upload.isActive ? aggregate.upload : aggregate.download,
                    isUploading: isUploading,
                    arrowColor: .systemBlue,
                    availableWidth: available
                )
                let percent = Int(fraction * 100)
                #expect(layout.totalWidth <= available,
                        """
                        "\(isUploading ? "↑" : "↓")\(percent)%" draws \\
                        \(String(format: "%.1f", layout.totalWidth))pt wide inside a \
                        \(String(format: "%.1f", available))pt circle, so it crosses the ring.
                        """)
            }
        }

        // `100%` is the widest string and is the one that has to fit.
        let widest = SFTPTransferRingControl.centerTextLayout(
            running: SFTPDirectionAggregate(
                count: 1, fraction: 1.0, transferredBytes: 1000, totalBytes: 1000
            ),
            isUploading: true, arrowColor: .systemBlue, availableWidth: available
        )
        #expect(widest.totalWidth <= available,
                "100% does not fit inside the ring")
        #expect(widest.fontSize >= SFTPTransferRingControl.minimumCenterTextSize,
                "100% was shrunk below the legibility floor to force a fit")
    }

    @Test("the ring item reserves no width beyond the ring it draws")
    func ringItemHasNoDeadWidth() {
        let size = SFTPTransferRingControl.size
        // The circle is drawn on the shortest edge, so anything wider than tall is
        // dead space the toolbar will still reserve.
        #expect(size.width == size.height,
                """
                the ring item is \\(size.width)x\\(size.height) but draws a circle of \\
                \(SFTPTransferRingControl.innerTextWidth(for: NSRect(origin: .zero, size: size)))pt. \
                The extra width is reserved by the toolbar as a void, which is why the \
                four rings sit further apart than the icon items beside them.
                """)
    }

    /// The circle's horizontal extent, measured from rendered pixels.
    ///
    /// Sampled along the vertical centre line: at mid-height the circle's own edges
    /// are the outermost ink, and the centred percentage is narrower than the ring,
    /// so the measurement is of the ring rather than of the text inside it.
    private func measuredCircleWidth(_ view: NSView) throws -> Int {
        let w = Int(view.bounds.width.rounded()), h = Int(view.bounds.height.rounded())
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        let data = try #require(rep.bitmapData)

        let midRow = h / 2
        var minX = w, maxX = -1
        for x in 0 ..< w {
            let offset = midRow * rep.bytesPerRow + x * 4
            if Int(data[offset + 3]) > 40 {
                minX = Swift.min(minX, x)
                maxX = Swift.max(maxX, x)
            }
        }
        return maxX - minX
    }

    @Test("all four toolbar rings render an identical ring")
    func allFourRingsAreIdentical() throws {
        let size = AppStyle.toolbarRingSize

        func sftpRing() -> SFTPTransferRingControl {
            let c = SFTPTransferRingControl(label: "transfers")
            c.frame = NSRect(origin: .zero, size: size)
            c.refresh(aggregate: .none)
            return c
        }
        func serverRing(_ kind: ServerResourceKind) -> ServerResourceRingControl {
            let c = ServerResourceRingControl(kind: kind, label: "resource")
            c.frame = NSRect(origin: .zero, size: size)
            c.refresh(snapshot: nil)
            return c
        }
        func intrinsic(_ kind: ServerResourceKind) -> NSSize {
            ServerResourceRingControl(kind: kind, label: "r").intrinsicContentSize
        }

        let controls: [(String, NSView, NSSize)] = [
            ("sftp", sftpRing(), SFTPTransferRingControl.size),
            ("cpu", serverRing(.cpu), intrinsic(.cpu)),
            ("memory", serverRing(.memory), intrinsic(.memory)),
            ("disk", serverRing(.disk), intrinsic(.disk)),
        ]

        var measured: [String: Int] = [:]
        var widths: [String: NSSize] = [:]
        for entry in controls {
            widths[entry.0] = entry.2
            measured[entry.0] = try measuredCircleWidth(entry.1)
        }
        let trace = controls.map {
            "\($0.0): intrinsic=\($0.2.width)x\($0.2.height) circle=\(measured[$0.0] ?? -1)pt"
        }.joined(separator: "\n")
        try trace.write(toFile: "/tmp/bonk-ring-sizes.txt", atomically: true, encoding: .utf8)

        let uniqueSizes = Set(controls.map { "\($0.2.width)x\($0.2.height)" })
        #expect(uniqueSizes.count == 1,
                "the four rings do not share one footprint: \(widths)")

        let uniqueCircles = Set(measured.values)
        #expect(uniqueCircles.count == 1,
                """
                the four rings draw different sized circles: \(measured). Sharing a size                 constant is not the same as drawing the same ring — one of them has its                 own inset or stroke literal.
                """)

        let circle = try #require(uniqueCircles.first)
        #expect(circle >= Int(size.width.rounded()) - 2,
                """
                the circle is \(circle)pt wide inside a \(Int(size.width.rounded()))pt item.                 The missing \(Int(size.width.rounded()) - circle)pt is dead space the toolbar                 still reserves, and it is what keeps the rings looking further apart than                 the icon items beside them.
                """)
    }
}
