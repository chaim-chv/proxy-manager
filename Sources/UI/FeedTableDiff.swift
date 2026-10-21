import Foundation

/// Structural diff between two feed snapshots.
///
/// The feed is newest-first, so a completion or a new connection normally
/// changes only a handful of row identities. Applying those changes with
/// `NSTableView`'s `beginUpdates`/`removeRows`/`insertRows` keeps cells alive
/// and does not reset the scroll position.
///
/// Returns `nil` when there is nothing to do (`old == new`) or when the rows
/// that survive are reordered (a filter/sort change); the caller must then
/// fall back to `reloadData()`.
struct FeedTableDiff {
    /// Indexes into the old row array, to be removed in descending order.
    let removed: IndexSet
    /// Indexes into the new row array, to be inserted in ascending order.
    let inserted: IndexSet

    /// Computes the diff, or `nil` when a structural update is not possible.
    static func compute(old: [UUID], new: [UUID]) -> FeedTableDiff? {
        guard old != new else { return nil }

        var oldCounts: [UUID: Int] = [:]
        for id in old { oldCounts[id, default: 0] += 1 }
        var newCounts: [UUID: Int] = [:]
        for id in new { newCounts[id, default: 0] += 1 }

        // Rows with the same id are distinguishable only by occurrence.
        var sharedCounts: [UUID: Int] = [:]
        for (id, count) in oldCounts {
            sharedCounts[id] = min(count, newCounts[id] ?? 0)
        }

        guard commonOrder(in: old, sharedCounts: sharedCounts)
            == commonOrder(in: new, sharedCounts: sharedCounts) else {
            return nil
        }

        var removed = IndexSet()
        var matchedOld: [UUID: Int] = [:]
        for (index, id) in old.enumerated() {
            let occurrence = (matchedOld[id] ?? 0) + 1
            if occurrence <= (sharedCounts[id] ?? 0) {
                matchedOld[id] = occurrence
            } else {
                removed.insert(index)
            }
        }

        var inserted = IndexSet()
        var matchedNew: [UUID: Int] = [:]
        for (index, id) in new.enumerated() {
            let occurrence = (matchedNew[id] ?? 0) + 1
            if occurrence <= (sharedCounts[id] ?? 0) {
                matchedNew[id] = occurrence
            } else {
                inserted.insert(index)
            }
        }

        return FeedTableDiff(removed: removed, inserted: inserted)
    }

    private static func commonOrder(in ids: [UUID], sharedCounts: [UUID: Int]) -> [UUID] {
        var seen: [UUID: Int] = [:]
        var result: [UUID] = []
        for id in ids {
            let occurrence = (seen[id] ?? 0) + 1
            seen[id] = occurrence
            if occurrence <= (sharedCounts[id] ?? 0) {
                result.append(id)
            }
        }
        return result
    }
}
