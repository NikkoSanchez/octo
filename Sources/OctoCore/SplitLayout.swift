import CoreGraphics
import Foundation

/// Where a new pane goes relative to the pane it splits, as in Ghostty's `new_split`.
public enum SplitDirection: Equatable, Sendable { case right, down, left, up }

/// A focus move between panes, as in Ghostty's `goto_split`.
public enum SplitFocusTarget: Equatable, Sendable { case previous, next, left, right, up, down }

/// `horizontal` places children side by side; `vertical` stacks them.
public enum SplitAxis: Equatable, Sendable { case horizontal, vertical }

public indirect enum SplitNode<Leaf: Hashable>: Equatable {
    case leaf(Leaf)
    /// `ratio` is the share of `first` (the left or top child).
    case split(SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

    public var leaves: [Leaf] {
        switch self {
        case let .leaf(leaf): return [leaf]
        case let .split(_, _, first, second): return first.leaves + second.leaves
        }
    }
}

/// A divider between two children of the split at `path` (0 = first, 1 = second at each level).
public struct SplitDivider: Equatable {
    public let path: [Int]
    public let axis: SplitAxis
    public let ratio: Double
    /// The gap between the two children.
    public let frame: CGRect
    /// The split's whole frame; a drag's position along `axis` maps into it.
    public let container: CGRect
}

/// A pane tree after Ghostty's macOS `SplitTree`: the same insertion, removal, spatial focus,
/// resize and equalize rules, so bindings behave as they do in Ghostty itself.
public struct SplitLayout<Leaf: Hashable>: Equatable {
    public private(set) var root: SplitNode<Leaf>
    /// One pane shown over the whole area; the others stay mounted behind it.
    public var zoomed: Leaf? {
        didSet { if let zoomed, !contains(zoomed) { self.zoomed = nil } }
    }
    public static var minimumRatio: Double { 0.1 }

    public init(_ leaf: Leaf) { root = .leaf(leaf) }
    public var leaves: [Leaf] { root.leaves }
    public var isSplit: Bool { if case .split = root { return true } else { return false } }
    public func contains(_ leaf: Leaf) -> Bool { path(to: leaf) != nil }

    /// Splits `target` in half and places `leaf` in `direction`. Clears any zoom.
    @discardableResult public mutating func insert(_ leaf: Leaf, beside target: Leaf, direction: SplitDirection) -> Bool {
        guard !contains(leaf), let path = path(to: target) else { return false }
        let new = SplitNode.leaf(leaf), old = SplitNode.leaf(target)
        let node: SplitNode<Leaf>
        switch direction {
        case .right: node = .split(.horizontal, ratio: 0.5, first: old, second: new)
        case .left: node = .split(.horizontal, ratio: 0.5, first: new, second: old)
        case .down: node = .split(.vertical, ratio: 0.5, first: old, second: new)
        case .up: node = .split(.vertical, ratio: 0.5, first: new, second: old)
        }
        root = Self.replacing(root, at: path[...], with: node)
        zoomed = nil
        return true
    }

    /// Removes a pane; its sibling takes the parent's place. The last pane cannot be removed.
    @discardableResult public mutating func remove(_ leaf: Leaf) -> Bool {
        guard let path = path(to: leaf), let side = path.last else { return false }
        let parent = Array(path.dropLast())
        guard case let .split(_, _, first, second) = node(at: parent) else { return false }
        root = Self.replacing(root, at: parent[...], with: side == 0 ? second : first)
        if zoomed == leaf { zoomed = nil }
        return true
    }

    public func focusTarget(_ target: SplitFocusTarget, from leaf: Leaf) -> Leaf? {
        let all = leaves
        guard let index = all.firstIndex(of: leaf) else { return nil }
        switch target {
        case .previous: return all.count > 1 ? all[(index - 1 + all.count) % all.count] : nil
        case .next: return all.count > 1 ? all[(index + 1) % all.count] : nil
        default: break
        }
        // Ghostty compares a grid where each pane counts as one cell, not the pixel layout.
        var frames: [Leaf: CGRect] = [:]
        Self.walk(root, in: CGRect(origin: .zero, size: Self.dimensions(root)), gap: 0, rounded: false, path: []) { node, frame, _ in
            if case let .leaf(leaf) = node { frames[leaf] = frame }
        }
        guard let from = frames[leaf] else { return nil }
        let epsilon = 1e-9
        let candidates = frames.filter { other, frame in
            guard other != leaf else { return false }
            switch target {
            case .left: return frame.maxX <= from.minX + epsilon
            case .right: return frame.minX >= from.maxX - epsilon
            case .up: return frame.maxY <= from.minY + epsilon
            case .down: return frame.minY >= from.maxY - epsilon
            case .previous, .next: return false
            }
        }
        // Nearest by top-left corner; ties fall back to tree order so the result is stable.
        func distance(_ frame: CGRect) -> Double { hypot(frame.minX - from.minX, frame.minY - from.minY) }
        return candidates.min { a, b in
            let da = distance(a.value), db = distance(b.value)
            if abs(da - db) > epsilon { return da < db }
            return (all.firstIndex(of: a.key) ?? 0) < (all.firstIndex(of: b.key) ?? 0)
        }?.key
    }

    /// Moves the nearest enclosing divider on the matching axis by `points`, as `resize_split` does.
    /// Clears any zoom.
    @discardableResult public mutating func resize(_ leaf: Leaf, direction: SplitDirection, by points: Double, in bounds: CGRect) -> Bool {
        guard let path = path(to: leaf) else { return false }
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        for length in stride(from: path.count - 1, through: 0, by: -1) {
            let parent = Array(path.prefix(length))
            guard case let .split(splitAxis, ratio, _, _) = node(at: parent), splitAxis == axis,
                  let divider = dividers(in: bounds).first(where: { $0.path == parent }) else { continue }
            let extent = axis == .horizontal ? divider.container.width : divider.container.height
            guard extent > 0 else { return false }
            let delta = points / extent * (direction == .left || direction == .up ? -1 : 1)
            setRatio(ratio + delta, at: parent)
            zoomed = nil
            return true
        }
        return false
    }

    /// Gives every pane along each axis an equal share, as `equalize_splits` does.
    public mutating func equalize() { root = Self.equalized(root) }

    public mutating func setRatio(_ ratio: Double, at path: [Int]) {
        guard case let .split(axis, _, first, second) = node(at: path) else { return }
        let clamped = min(1 - Self.minimumRatio, max(Self.minimumRatio, ratio))
        root = Self.replacing(root, at: path[...], with: .split(axis, ratio: clamped, first: first, second: second))
    }

    /// Pane frames within `bounds`, with `gap` points between siblings for their divider.
    public func frames(in bounds: CGRect, gap: CGFloat = 0) -> [Leaf: CGRect] {
        var result: [Leaf: CGRect] = [:]
        Self.walk(root, in: bounds, gap: gap, rounded: true, path: []) { node, frame, _ in
            if case let .leaf(leaf) = node { result[leaf] = frame }
        }
        return result
    }

    public func dividers(in bounds: CGRect, gap: CGFloat = 0) -> [SplitDivider] {
        var result: [SplitDivider] = []
        Self.walk(root, in: bounds, gap: gap, rounded: true, path: []) { node, frame, path in
            guard case let .split(axis, ratio, _, _) = node else { return }
            let (first, _) = Self.divide(frame, axis: axis, ratio: ratio, gap: gap, rounded: true)
            let divider = axis == .horizontal
                ? CGRect(x: first.maxX, y: frame.minY, width: gap, height: frame.height)
                : CGRect(x: frame.minX, y: first.maxY, width: frame.width, height: gap)
            result.append(SplitDivider(path: path, axis: axis, ratio: ratio, frame: divider, container: frame))
        }
        return result
    }

    // MARK: Tree helpers

    func path(to leaf: Leaf) -> [Int]? {
        func search(_ node: SplitNode<Leaf>, _ path: [Int]) -> [Int]? {
            switch node {
            case let .leaf(value): return value == leaf ? path : nil
            case let .split(_, _, first, second): return search(first, path + [0]) ?? search(second, path + [1])
            }
        }
        return search(root, [])
    }
    func node(at path: [Int]) -> SplitNode<Leaf>? {
        var node = root
        for side in path {
            guard case let .split(_, _, first, second) = node else { return nil }
            node = side == 0 ? first : second
        }
        return node
    }
    private static func replacing(_ node: SplitNode<Leaf>, at path: ArraySlice<Int>, with replacement: SplitNode<Leaf>) -> SplitNode<Leaf> {
        guard let side = path.first else { return replacement }
        guard case let .split(axis, ratio, first, second) = node else { return node }
        let rest = path.dropFirst()
        return side == 0
            ? .split(axis, ratio: ratio, first: replacing(first, at: rest, with: replacement), second: second)
            : .split(axis, ratio: ratio, first: first, second: replacing(second, at: rest, with: replacement))
    }
    /// Pixel layouts round to whole points; the focus grid must not, or neighbouring edges drift apart.
    private static func divide(_ frame: CGRect, axis: SplitAxis, ratio: Double, gap: CGFloat, rounded: Bool) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let available = max(0, frame.width - gap), width = rounded ? (available * ratio).rounded() : available * ratio
            return (CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height),
                    CGRect(x: frame.minX + width + gap, y: frame.minY, width: available - width, height: frame.height))
        case .vertical:
            let available = max(0, frame.height - gap), height = rounded ? (available * ratio).rounded() : available * ratio
            return (CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height),
                    CGRect(x: frame.minX, y: frame.minY + height + gap, width: frame.width, height: available - height))
        }
    }
    private static func walk(_ node: SplitNode<Leaf>, in frame: CGRect, gap: CGFloat, rounded: Bool, path: [Int],
                             _ visit: (SplitNode<Leaf>, CGRect, [Int]) -> Void) {
        visit(node, frame, path)
        guard case let .split(axis, ratio, first, second) = node else { return }
        let (a, b) = divide(frame, axis: axis, ratio: ratio, gap: gap, rounded: rounded)
        walk(first, in: a, gap: gap, rounded: rounded, path: path + [0], visit)
        walk(second, in: b, gap: gap, rounded: rounded, path: path + [1], visit)
    }
    /// Columns and rows needed when each pane is one cell.
    private static func dimensions(_ node: SplitNode<Leaf>) -> CGSize {
        switch node {
        case .leaf: return CGSize(width: 1, height: 1)
        case let .split(axis, _, first, second):
            let a = dimensions(first), b = dimensions(second)
            return axis == .horizontal ? CGSize(width: a.width + b.width, height: max(a.height, b.height))
                                       : CGSize(width: max(a.width, b.width), height: a.height + b.height)
        }
    }
    private static func weight(_ node: SplitNode<Leaf>, along axis: SplitAxis) -> Int {
        guard case let .split(splitAxis, _, first, second) = node, splitAxis == axis else { return 1 }
        return weight(first, along: axis) + weight(second, along: axis)
    }
    private static func equalized(_ node: SplitNode<Leaf>) -> SplitNode<Leaf> {
        guard case let .split(axis, _, first, second) = node else { return node }
        let a = weight(first, along: axis), b = weight(second, along: axis)
        return .split(axis, ratio: Double(a) / Double(a + b), first: equalized(first), second: equalized(second))
    }
}
