import Foundation

/// A least-recently-used cache bounded by total cost and by count.
///
/// Lookups, insertions and evictions are O(1). It is deliberately not
/// thread-safe: each cache is owned by one actor (in practice the main actor,
/// where decoded images are handed to the interface).
final class LRUCache<Key: Hashable, Value> {

    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        /// Towards the most recently used end.
        weak var newer: Node?
        /// Towards the least recently used end.
        var older: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private var nodes: [Key: Node] = [:]
    /// Most recently used.
    private var newest: Node?
    /// Least recently used — the next to be evicted.
    private weak var oldest: Node?

    private(set) var totalCost = 0

    var costLimit: Int {
        didSet { trim() }
    }

    var countLimit: Int {
        didSet { trim() }
    }

    init(costLimit: Int = .max, countLimit: Int = .max) {
        self.costLimit = max(0, costLimit)
        self.countLimit = max(0, countLimit)
    }

    var count: Int { nodes.count }
    var isEmpty: Bool { nodes.isEmpty }

    /// Look up a value and mark it as recently used.
    func value(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToFront(node)
        return node.value
    }

    /// Look up a value without changing its position.
    func peek(_ key: Key) -> Value? {
        nodes[key]?.value
    }

    func contains(_ key: Key) -> Bool {
        nodes[key] != nil
    }

    /// Insert or replace a value, evicting the least recently used entries until
    /// the limits are met. A value costlier than the whole budget is not kept.
    func insert(_ value: Value, forKey key: Key, cost: Int = 1) {
        let cost = max(0, cost)
        if let node = nodes[key] {
            totalCost += cost - node.cost
            node.value = value
            node.cost = cost
            moveToFront(node)
        } else {
            let node = Node(key: key, value: value, cost: cost)
            nodes[key] = node
            totalCost += cost
            attachAtFront(node)
        }
        trim()
    }

    @discardableResult
    func removeValue(forKey key: Key) -> Value? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        detach(node)
        totalCost -= node.cost
        return node.value
    }

    func removeAll() {
        // Unlink iteratively so a long chain is not released recursively.
        var node = newest
        while let current = node {
            node = current.older
            current.older = nil
            current.newer = nil
        }
        nodes.removeAll()
        newest = nil
        oldest = nil
        totalCost = 0
    }

    /// Evict least recently used entries until the total cost is at most `limit`.
    func trim(toCost limit: Int) {
        while totalCost > limit, let victim = oldest {
            removeValue(forKey: victim.key)
        }
    }

    /// Keys from most to least recently used.
    var keysByRecency: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(nodes.count)
        var node = newest
        while let current = node {
            keys.append(current.key)
            node = current.older
        }
        return keys
    }

    // MARK: Linked list

    private func trim() {
        while (totalCost > costLimit || nodes.count > countLimit), let victim = oldest {
            removeValue(forKey: victim.key)
        }
    }

    private func attachAtFront(_ node: Node) {
        node.newer = nil
        node.older = newest
        newest?.newer = node
        newest = node
        if oldest == nil { oldest = node }
    }

    private func detach(_ node: Node) {
        let newer = node.newer
        let older = node.older
        if let newer {
            newer.older = older
        } else {
            newest = older
        }
        if let older {
            older.newer = newer
        } else {
            oldest = newer
        }
        node.newer = nil
        node.older = nil
    }

    private func moveToFront(_ node: Node) {
        guard newest !== node else { return }
        detach(node)
        attachAtFront(node)
    }
}
