//
//  FilePath.swift
//  SingBoxPacketTunnel
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation

public enum FilePath {
    public static let packageName = {
        Bundle.main.infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String ?? "unknown"
    }()
}

public extension FilePath {
    static let groupName = "group.\(packageName)"

    private static let defaultSharedDirectory: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FilePath.groupName) {
            return url
        }
        // Фолбэк: если контейнер App Group недоступен — не роняем приложение нативно,
        // используем собственную Library-папку, чтобы старт дошёл до UI/диагностики.
        NSLog("OKNO: app group container is nil for \(FilePath.groupName), falling back to local Library dir")
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }()

    static let sharedDirectory = defaultSharedDirectory

    static let cacheDirectory = sharedDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)
}

public extension URL {
    var fileName: String {
        var path = relativePath
        if let index = path.lastIndex(of: "/") {
            path = String(path[path.index(index, offsetBy: 1)...])
        }
        return path
    }
}
