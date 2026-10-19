extension Report {
    /// Arayüze gidecek hafif görünüm: ağaç `build_ui.py`'deki `compact_tree` gibi sıkıştırılır
    /// ve yalnızca karşılaştırma için gereken ağır alanlar çıkarılır.
    public func forDisplay() -> Report {
        var copy = self
        copy.tree = Self.compact(tree)
        copy.folderIndex = nil
        copy.unreadable = nil
        return copy
    }

    private static let keepLimit = 16
    private static let alwaysKeep = 3
    private static let smallThreshold: Int64 = 2 * 1024 * 1024

    private static func compact(_ node: Node) -> Node {
        var result = node
        result.children = nil
        guard let children = node.children, !children.isEmpty else { return result }
        let ordered = children.enumerated().sorted {
            $0.element.bytes != $1.element.bytes ? $0.element.bytes > $1.element.bytes : $0.offset < $1.offset
        }.map(\.element)
        var kept: [Node] = []
        var rest: [Node] = []
        for (index, child) in ordered.enumerated() {
            if index < keepLimit && (index < alwaysKeep || child.bytes >= smallThreshold) {
                kept.append(compact(child))
            } else {
                rest.append(child)
            }
        }
        if !rest.isEmpty {
            kept.append(Node(name: "Diğer \(rest.count) öğe", path: node.path,
                             bytes: rest.reduce(0) { $0 + $1.bytes }, logical: rest.reduce(0) { $0 + $1.logical },
                             category: node.category, aggregate: true, children: nil))
        }
        result.children = kept
        return result
    }
}
