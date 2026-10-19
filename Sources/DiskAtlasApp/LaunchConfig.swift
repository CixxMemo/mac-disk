import Foundation

/// Komut satırı ve ortam değişkenleri. `--self-test` dışındaki bayraklar yalnızca geliştirme içindir.
struct LaunchConfig {
    var selfTest = false
    var scanRoot: String?
    var snapshotPath: String?
    var storeDirectory: String?
    var timeout: TimeInterval = 90

    static func parse(_ arguments: [String]) -> LaunchConfig {
        var config = LaunchConfig()
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--self-test": config.selfTest = true
            case "--scan-root": config.scanRoot = iterator.next()
            case "--snapshot": config.snapshotPath = iterator.next()
            case "--store-dir": config.storeDirectory = iterator.next()
            case "--timeout": config.timeout = iterator.next().flatMap(Double.init) ?? config.timeout
            default: break
            }
        }
        return config
    }
}
