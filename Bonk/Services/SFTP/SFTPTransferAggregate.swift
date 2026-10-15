//
//  SFTPTransferAggregate.swift
//  Bonk
//
//  Aggregates in-flight SFTP transfers across every session, so a single
//  indicator can stand in for progress the user cannot otherwise see.
//
//  ## Why this is separate from the view
//
//  The arithmetic is the part with edges — transfers that completed, were
//  cancelled, failed, or report an unknown size — and those edges are what decide
//  whether the ring is honest. A ring that shows a confident percentage while one
//  of its inputs is unknowable is worse than no ring, because it looks like
//  information. Keeping the arithmetic here makes it testable without a window.
//

import Foundation

/// Combined progress for one direction of transfer.
struct SFTPDirectionAggregate: Equatable, Sendable {
    let count: Int
    /// `nil` when a byte total cannot be computed honestly.
    let fraction: Double?
    let transferredBytes: UInt64
    let totalBytes: UInt64

    var isActive: Bool { count > 0 }
    var isDeterminate: Bool { fraction != nil }

    static let none = SFTPDirectionAggregate(
        count: 0, fraction: nil, transferredBytes: 0, totalBytes: 0
    )
}

/// Combined progress of every active SFTP transfer in the app, split by direction.
struct SFTPTransferAggregate: Equatable, Sendable {
    let upload: SFTPDirectionAggregate
    let download: SFTPDirectionAggregate
    /// Transfers that finished cleanly and are still visible.
    ///
    /// The ring needs to distinguish "finished" from "never started". Both have no
    /// active transfers, so without this a completed upload and an idle toolbar
    /// look identical — and the user is left watching a bar that is not moving and
    /// cannot tell whether the transfer finished or stalled.
    let completedCount: Int

    /// Transfers still running across both directions.
    var activeCount: Int { upload.count + download.count }
    var isActive: Bool { activeCount > 0 }
    /// Whether *either* direction can show a determinate arc.
    var isDeterminate: Bool { upload.isDeterminate || download.isDeterminate }
    /// True while finished transfers are still on screen awaiting removal.
    var hasJustCompleted: Bool { completedCount > 0 }

    static let none = SFTPTransferAggregate(transfers: [])

    /// Fold a set of transfers from every session into one aggregate.
    ///
    /// Internal rather than public: `SFTPTransfer` is internal, and a public
    /// initialiser taking it would not compile — so the aggregate's own visibility
    /// is lowered to match instead of widening the model's.
    init(transfers: [SFTPTransfer]) {
        let usable = transfers.filter { !$0.isCancelled && $0.error == nil }
        let active = usable.filter { !$0.isComplete }
        upload = Self.fold(active.filter { $0.direction == .upload })
        download = Self.fold(active.filter { $0.direction == .download })
        completedCount = usable.count - active.count
    }

    private static func fold(_ active: [SFTPTransfer]) -> SFTPDirectionAggregate {
        guard !active.isEmpty else { return .none }
        let sized = active.filter { ($0.totalBytes ?? 0) > 0 }
        let transferred = sized.reduce(0) { $0 + $1.transferredBytes }
        let total = sized.reduce(0) { $0 + ($1.totalBytes ?? 0) }

        // Unknown size is not a reason to guess: a percentage whose denominator
        // omits one of the files is wrong in a way the user cannot detect.
        let fraction: Double? = if sized.count == active.count, total > 0 {
            // Clamped: the final chunk can land before the completion flag is set,
            // and an arc drawn past 360° renders as a stray line.
            min(max(Double(transferred) / Double(total), 0), 1)
        } else {
            nil
        }
        return SFTPDirectionAggregate(
            count: active.count, fraction: fraction,
            transferredBytes: transferred, totalBytes: total
        )
    }
}