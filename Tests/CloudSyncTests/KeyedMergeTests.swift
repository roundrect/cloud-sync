import Testing
@testable import CloudSync

@Suite("KeyedMerge")
struct KeyedMergeTests {
    private func merge(base: [String: String] = [:], local: [String: String] = [:], remote: [String: String] = [:],
                       order: (String, String) -> Bool = { $0 < $1 }) -> KeyedMergeResult<String, String> {
        KeyedMerge.merge(base: base, local: local, remote: remote, order: order)
    }

    @Test func keysChangedOnOnlyOneSideNeverConflict() {
        let result = merge(
            base: ["a": "1", "b": "1", "c": "1"],
            local: ["a": "2", "b": "1", "c": "1"],
            remote: ["a": "1", "b": "3", "c": "1"])
        #expect(result.resolved == ["a": "2", "b": "3", "c": "1"])
        #expect(result.conflicts.isEmpty)
        #expect(result.localOnly == ["a"])
        #expect(result.remoteOnly == ["b"])
    }

    @Test func keysAddedOrRemovedOnOneSideCarryOver() {
        let result = merge(
            base: ["gone-local": "1", "gone-remote": "1"],
            local: ["new-local": "x", "gone-remote": "1"],
            remote: ["new-remote": "y", "gone-local": "1"])
        #expect(result.resolved == ["new-local": "x", "new-remote": "y"])
        #expect(result.conflicts.isEmpty)
        #expect(result.localOnly == ["gone-local", "new-local"])
        #expect(result.remoteOnly == ["gone-remote", "new-remote"])
    }

    @Test func theSameChangeOnBothSidesIsNotAConflictOrAChange() {
        let result = merge(base: ["a": "1", "b": "1", "c": "1"], local: ["a": "2", "c": "9", "d": "new"], remote: ["a": "2", "b": "1", "c": "9", "d": "new"])
        // b: local deleted, remote kept it as it was -> deletion; a, c, d: both agree.
        #expect(result.resolved == ["a": "2", "c": "9", "d": "new"])
        #expect(result.conflicts.isEmpty)
        #expect(!result.localOnly.contains("a") && !result.remoteOnly.contains("a"))
        #expect(!result.localOnly.contains("d") && !result.remoteOnly.contains("d"))
    }

    @Test func bothDeletingTheSameKeyDeletesIt() {
        let result = merge(base: ["a": "1"], local: [:], remote: [:])
        #expect(result.resolved.isEmpty)
        #expect(result.conflicts.isEmpty)
    }

    @Test func bothChangingTheSameKeyDifferentlyKeepsLocalAndReportsIt() {
        let result = merge(base: ["a": "1"], local: ["a": "local"], remote: ["a": "remote"])
        #expect(result.resolved == ["a": "local"])
        #expect(result.conflicts == [KeyedConflict(key: "a", local: "local", remote: "remote", tookRemote: false)])
        #expect(result.localOnly.isEmpty && result.remoteOnly.isEmpty)
    }

    @Test func bothAddingTheSameKeyDifferentlyIsAConflictToo() {
        let result = merge(local: ["a": "local"], remote: ["a": "remote"])
        #expect(result.resolved == ["a": "local"])
        #expect(result.conflicts == [KeyedConflict(key: "a", local: "local", remote: "remote", tookRemote: false)])
    }

    @Test func anEditBeatsADeleteWhenThisMacDeleted() {
        let result = merge(base: ["a": "1"], local: [:], remote: ["a": "edited"])
        #expect(result.resolved == ["a": "edited"])
        #expect(result.conflicts == [KeyedConflict(key: "a", local: nil, remote: "edited", tookRemote: true)])
    }

    @Test func anEditBeatsADeleteWhenTheOtherMacDeleted() {
        let result = merge(base: ["a": "1"], local: ["a": "edited"], remote: [:])
        #expect(result.resolved == ["a": "edited"])
        #expect(result.conflicts == [KeyedConflict(key: "a", local: "edited", remote: nil, tookRemote: false)])
    }

    @Test func conflictsComeBackInTheOrderGiven() {
        let keys = ["delta", "alpha", "charlie", "bravo", "echo"]
        let base = Dictionary(uniqueKeysWithValues: keys.map { ($0, "0") })
        let local = Dictionary(uniqueKeysWithValues: keys.map { ($0, "L") })
        let remote = Dictionary(uniqueKeysWithValues: keys.map { ($0, "R") })
        // Dictionaries hash differently from run to run; the answer must not.
        for _ in 0..<25 {
            #expect(merge(base: base, local: local, remote: remote).conflicts.map(\.key) == ["alpha", "bravo", "charlie", "delta", "echo"])
            #expect(merge(base: base, local: local, remote: remote, order: >).conflicts.map(\.key) == ["echo", "delta", "charlie", "bravo", "alpha"])
        }
    }

    @Test func theChangedKeyListsFollowTheOrderToo() {
        let base = ["z": "0", "m": "0", "a": "0"]
        let result = merge(base: base, local: ["z": "1", "m": "1", "a": "1"], remote: base)
        #expect(result.localOnly == ["a", "m", "z"])
        #expect(merge(base: base, local: ["z": "1", "m": "1", "a": "1"], remote: base, order: >).localOnly == ["z", "m", "a"])
    }

    @Test func mergingAnythingWithItselfChangesNothing() {
        let document = ["a": "1", "b": "2"]
        let result = merge(base: document, local: document, remote: document)
        #expect(result.resolved == document)
        #expect(result.conflicts.isEmpty && result.localOnly.isEmpty && result.remoteOnly.isEmpty)
    }

    @Test func aMissingBaseTreatsEverythingAsAdded() {
        let result = merge(local: ["a": "1", "b": "2"], remote: ["b": "2", "c": "3"])
        #expect(result.resolved == ["a": "1", "b": "2", "c": "3"])
        #expect(result.conflicts.isEmpty)
    }
}
