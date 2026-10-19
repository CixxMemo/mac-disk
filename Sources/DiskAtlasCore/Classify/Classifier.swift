public struct Classifier: Sendable {
    private let rules: RuleSet
    private let dataVolumePrefix: String

    public init(rules: RuleSet, dataVolumePrefix: String = "/System/Volumes/Data") {
        self.rules = rules
        self.dataVolumePrefix = dataVolumePrefix
    }

    /// Veri volume önekini atar; kökün kendisi "/" olur.
    public func displayPath(_ path: String) -> String {
        if path == dataVolumePrefix { return "/" }
        if path.hasPrefix(dataVolumePrefix + "/") {
            let rest = String(path.dropFirst(dataVolumePrefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return path
    }

    /// `scanner.py` içindeki `classify` ile aynı sırayı uygular.
    public func classify(path: String, inherited: DiskCategory?) -> DiskCategory {
        if let inherited, rules.stickyCategories.contains(inherited) { return inherited }
        let name = Self.baseName(path).lowercased()
        let lower = displayPath(path).lowercased()
        for rule in rules.rules where matches(rule, name: name, lower: lower) {
            return rule.category
        }
        return inherited ?? rules.fallback
    }

    private func matches(_ rule: Rule, name: String, lower: String) -> Bool {
        if let under = rule.appBundleUnder {
            return lower.contains(under) && (name.hasSuffix(".app") || lower.contains(".app/"))
        }
        if let needles = rule.pathContainsAny { return needles.contains { lower.contains($0) } }
        if let names = rule.nameIn { return names.contains(name) }
        if let prefixes = rule.pathPrefixAny {
            return prefixes.contains { lower == $0 || lower.hasPrefix($0 + "/") }
        }
        return false
    }

    private static func baseName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
