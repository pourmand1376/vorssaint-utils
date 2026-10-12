// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

final class SettingsUserDefaults: UserDefaults {
    private static let sharedStore: SettingsUserDefaults = {
        guard let container = PrivateFileStore.containerURL else {
            fatalError("Settings storage requires an app bundle identifier")
        }
        let folder = container.appendingPathComponent("Settings", isDirectory: true)
        return SettingsUserDefaults(
            storageURL: folder.appendingPathComponent("Preferences.plist"),
            domainName: Bundle.main.bundleIdentifier,
            legacyDefaults: UserDefaults.standard,
            containerURL: container)
    }()

    override class var standard: UserDefaults {
        sharedStore
    }

    static var settings: SettingsUserDefaults {
        sharedStore
    }

    private let storageURL: URL
    private let domainName: String?
    private let legacyDefaults: UserDefaults
    private let containerURL: URL?
    private let lock = NSRecursiveLock()
    private var values: [String: Any]
    private var registeredValues: [String: Any] = [:]
    private var batchDepth = 0
    private var hasUnwrittenChanges = false

    init(storageURL: URL,
         domainName: String?,
         legacyDefaults: UserDefaults,
         containerURL: URL? = nil) {
        self.storageURL = storageURL
        self.domainName = domainName
        self.legacyDefaults = legacyDefaults
        self.containerURL = containerURL
        values = [:]
        super.init(suiteName: "com.vorssaint.utils.folder-defaults.\(UUID().uuidString)")!
        loadOrMigrate()
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        let value = values[defaultName] ?? registeredValues[defaultName]
        lock.unlock()
        return value ?? super.object(forKey: defaultName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        if let value {
            guard PropertyListSerialization.propertyList(value, isValidFor: .xml) else {
                lock.unlock()
                return
            }
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
        hasUnwrittenChanges = true
        if batchDepth == 0 {
            persistLocked()
        }
        lock.unlock()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock()
        values.removeValue(forKey: defaultName)
        hasUnwrittenChanges = true
        if batchDepth == 0 {
            persistLocked()
        }
        lock.unlock()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.lock()
        registeredValues.merge(registrationDictionary) { _, new in new }
        lock.unlock()
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        var result = super.dictionaryRepresentation()
        result.merge(registeredValues) { current, _ in current }
        result.merge(values) { _, saved in saved }
        lock.unlock()
        return result
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        guard domainName == self.domainName else {
            return super.persistentDomain(forName: domainName)
        }
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard domainName == self.domainName else {
            super.setPersistentDomain(domain, forName: domainName)
            return
        }
        guard PropertyListSerialization.propertyList(domain, isValidFor: .xml) else { return }
        lock.lock()
        values = domain
        hasUnwrittenChanges = true
        if batchDepth == 0 {
            persistLocked()
        }
        lock.unlock()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func removePersistentDomain(forName domainName: String) {
        guard domainName == self.domainName else {
            super.removePersistentDomain(forName: domainName)
            return
        }
        setPersistentDomain([:], forName: domainName)
    }

    override func synchronize() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return persistLocked()
    }

    func withBatchUpdates<T>(_ updates: () throws -> T) rethrows -> T {
        lock.lock()
        batchDepth += 1
        lock.unlock()
        defer {
            lock.lock()
            batchDepth -= 1
            if batchDepth == 0, hasUnwrittenChanges {
                persistLocked()
            }
            lock.unlock()
        }
        return try updates()
    }

    private func loadOrMigrate() {
        let fileManager = FileManager.default
        let existingDomain = domainName.flatMap {
            legacyDefaults.persistentDomain(forName: $0)
        }
        if fileManager.fileExists(atPath: storageURL.path) {
            if let data = try? Data(contentsOf: storageURL),
               let saved = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] {
                values = saved
                removeLegacyDomainIfNeeded(existingDomain)
                return
            }
            values = existingDomain ?? [:]
            hasUnwrittenChanges = true
            guard persistLocked() else { return }
            removeLegacyDomainIfNeeded(existingDomain)
            return
        }

        values = existingDomain ?? [:]
        guard PrivateFileStore.createDirectory(
            at: storageURL.deletingLastPathComponent(), container: containerURL),
              persistLocked()
        else { return }
        removeLegacyDomainIfNeeded(existingDomain)
    }

    private func removeLegacyDomainIfNeeded(_ domain: [String: Any]?) {
        guard domain != nil, let domainName else { return }
        legacyDefaults.removePersistentDomain(forName: domainName)
        legacyDefaults.synchronize()
    }

    @discardableResult
    private func persistLocked() -> Bool {
        guard hasUnwrittenChanges || !FileManager.default.fileExists(atPath: storageURL.path) else {
            return true
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: values, format: .xml, options: 0),
              PrivateFileStore.createDirectory(
                at: storageURL.deletingLastPathComponent(), container: containerURL),
              PrivateFileStore.write(data, to: storageURL)
        else { return false }
        hasUnwrittenChanges = false
        return true
    }
}
