// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Thread-safe generic LRU (Least Recently Used) cache container.
///
/// Implemented via a doubly-linked list with a hash map guarded by `os_unfair_lock` for nanosecond access.
public final class ExplorerLRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public let capacity: Int
    
    private final class Node: @unchecked Sendable {
        let key: Key
        var value: Value
        weak var prev: Node?
        var next: Node?
        
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }
    
    private struct State: @unchecked Sendable {
        var map: [Key: Node] = [:]
        var head: Node?
        var tail: Node?
        
        mutating func addToHead(_ node: Node) {
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
            if tail == nil {
                tail = node
            }
        }
        
        mutating func removeNode(_ node: Node) {
            let prev = node.prev
            let next = node.next
            
            if let p = prev {
                p.next = next
            } else {
                head = next
            }
            
            if let n = next {
                n.prev = prev
            } else {
                tail = prev
            }
            
            node.prev = nil
            node.next = nil
        }
        
        mutating func moveToHead(_ node: Node) {
            guard head !== node else { return }
            removeNode(node)
            addToHead(node)
        }
        
        mutating func removeTail() -> Node? {
            guard let t = tail else { return nil }
            removeNode(t)
            return t
        }
        
        mutating func removeAll() {
            var current = head
            while let node = current {
                let next = node.next
                node.prev = nil
                node.next = nil
                current = next
            }
            map.removeAll(keepingCapacity: true)
            head = nil
            tail = nil
        }
    }
    
    private let state: OSAllocatedUnfairLock<State>
    
    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
        self.state = OSAllocatedUnfairLock(initialState: State())
    }
    
    public var count: Int {
        state.withLock { $0.map.count }
    }
    
    public func get(_ key: Key) -> Value? {
        state.withLock { s in
            guard let node = s.map[key] else { return nil }
            s.moveToHead(node)
            return node.value
        }
    }
    
    public func set(_ key: Key, value: Value) {
        state.withLock { s in
            if let existing = s.map[key] {
                existing.value = value
                s.moveToHead(existing)
                return
            }
            
            let newNode = Node(key: key, value: value)
            s.map[key] = newNode
            s.addToHead(newNode)
            
            if s.map.count > capacity {
                if let lruNode = s.removeTail() {
                    s.map.removeValue(forKey: lruNode.key)
                }
            }
        }
    }
    
    @discardableResult
    public func remove(_ key: Key) -> Value? {
        state.withLock { s in
            guard let node = s.map.removeValue(forKey: key) else { return nil }
            s.removeNode(node)
            return node.value
        }
    }
    
    public func removeAll() {
        state.withLock { s in
            s.removeAll()
        }
    }
}
