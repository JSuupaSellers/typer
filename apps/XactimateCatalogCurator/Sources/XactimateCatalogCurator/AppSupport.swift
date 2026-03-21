import Foundation

enum AppSupport {
    static let appFolderName = "XactimateCatalogCurator"

    static func applicationSupportDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = root.appendingPathComponent(appFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory
    }

    static func databaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("catalog.sqlite", isDirectory: false)
    }
}

