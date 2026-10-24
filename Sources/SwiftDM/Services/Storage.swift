import Foundation
import Security
import SwiftDMCore

enum Persistence {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("SwiftDM", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var downloadsFile: URL { supportDirectory.appendingPathComponent("downloads.json") }
    private static let ioQueue = DispatchQueue(label: "swiftdm.persistence", qos: .utility)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func loadDownloads() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: downloadsFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DownloadRecord].self, from: data)) ?? []
    }

    static func saveDownloads(_ records: [DownloadRecord], synchronously: Bool = false) {
        guard let data = try? encoder.encode(records) else { return }
        let file = downloadsFile
        let write = {
            try? data.write(to: file, options: [.atomic])
            // The list can hold cookies from the browser, so keep it private to this user.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if synchronously { ioQueue.sync(execute: write) } else { ioQueue.async(execute: write) }
    }
}

/// Passwords for downloads and site logins. Nothing secret goes into the JSON files.
enum Keychain {
    private static let service = "app.swiftdm.credentials"

    static func set(_ password: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func downloadAccount(_ id: UUID) -> String { "download:\(id.uuidString)" }
}

enum FFmpeg {
    static var path: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
