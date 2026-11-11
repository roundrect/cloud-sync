import Foundation

/// A key both sides changed, differently.
public struct KeyedConflict<Key: Sendable, Value: Sendable>: Sendable {
    public var key: Key
    /// `nil` means the key is absent on that side (deleted, or never added).
    public var local: Value?
    public var remote: Value?
    /// The merge kept the remote value: an edit beats a delete.
    public var tookRemote: Bool

    public init(key: Key, local: Value?, remote: Value?, tookRemote: Bool) {
        self.key = key
        self.local = local
        self.remote = remote
        self.tookRemote = tookRemote
    }
}

extension KeyedConflict: Equatable where Key: Equatable, Value: Equatable {}

public struct KeyedMergeResult<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public var resolved: [Key: Value]
    public var conflicts: [KeyedConflict<Key, Value>]
    /// Keys only this Mac changed, and keys only the other side changed.
    public var localOnly: [Key]
    public var remoteOnly: [Key]
}

/// Three-way merge of two documents flattened into keyed values, against their common ancestor. Pure.
/// Two Macs that edit different keys never conflict. A document whose meaning depends on order needs
/// its own merge: a key has no position here.
public enum KeyedMerge {
    /// `order` sorts the keys, so results never depend on dictionary order.
    public static func merge<Key: Hashable & Sendable, Value: Equatable & Sendable>(
        base: [Key: Value], local: [Key: Value], remote: [Key: Value], order: (Key, Key) -> Bool
    ) -> KeyedMergeResult<Key, Value> {
        var result = KeyedMergeResult<Key, Value>(resolved: [:], conflicts: [], localOnly: [], remoteOnly: [])
        for key in Set(base.keys).union(local.keys).union(remote.keys).sorted(by: order) {
            let baseValue = base[key], localValue = local[key], remoteValue = remote[key]
            let chosen: Value?
            if localValue == remoteValue {
                chosen = localValue
            } else if localValue == baseValue {
                result.remoteOnly.append(key)
                chosen = remoteValue
            } else if remoteValue == baseValue {
                result.localOnly.append(key)
                chosen = localValue
            } else {
                // Both changed it, differently. Local wins, except that an edit beats a delete.
                let takeRemote = localValue == nil
                result.conflicts.append(KeyedConflict(key: key, local: localValue, remote: remoteValue, tookRemote: takeRemote))
                chosen = takeRemote ? remoteValue : localValue
            }
            result.resolved[key] = chosen
        }
        return result
    }
}
