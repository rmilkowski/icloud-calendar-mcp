// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Precision of a newly chosen set_on_commit timestamp, before provider entry.
/// Existing snapshots and preserve/restore timestamps must retain their exact value.
public enum ReminderCompletionTime {
    public static func onCommit(now: Date) -> Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }
}
