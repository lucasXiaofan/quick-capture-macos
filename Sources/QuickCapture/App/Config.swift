import Foundation

enum Paths {
    private static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    static let home = support.appendingPathComponent("Quick Capture", isDirectory: true)
    /// Before 3.1 the app was called "Obsidian Quick Capture" and kept its data in a folder of that name.
    private static let legacyHome = support.appendingPathComponent("Obsidian Quick Capture", isDirectory: true)

    /// Moves the old data folder (config, recovery copies, plugin data) to the new name, once.
    static func migrateLegacyHome() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyHome.path), !fm.fileExists(atPath: home.path) else { return }
        try? fm.moveItem(at: legacyHome, to: home)
    }
    static let config = home.appendingPathComponent("config.json")
    static let legacyAgent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.obsidian.quickcapture.plist")

    /// A plugin's private folder for files it keeps between launches.
    static func data(for pluginID: String) -> URL {
        home.appendingPathComponent(pluginID, isDirectory: true)
    }

    /// A file a plugin ships in Resources/<plugin id>/.
    static func resource(_ name: String, plugin pluginID: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent(pluginID).appendingPathComponent(name)
            .resolvingSymlinksInPath()
    }
}

/// A plugin's typed settings. Stored as extra keys next to "enabled" and "hotkeys" in the
/// plugin's object in config.json. Missing keys fall back to the values from `init()`.
protocol PluginSettings: Codable, Equatable {
    init()
}

/// config.json:
///
///     { "plugins": { "<plugin id>": { "enabled": true, "hotkeys": { "<action id>": "<cmd>+<shift>+i" }, …settings } } }
///
/// Unknown keys are kept, so a file edited by a newer version survives an older one.
struct AppConfig: Equatable {
    static let reservedKeys: Set<String> = ["enabled", "hotkeys"]

    var plugins: [String: [String: JSONValue]] = [:]
    var other: [String: JSONValue] = [:]

    init() {}

    init(json root: [String: JSONValue]) throws {
        var root = root
        if let plugins = root.removeValue(forKey: "plugins") {
            guard let dict = plugins.object else { throw AppError("\"plugins\" must be an object.") }
            for (id, value) in dict {
                guard let object = value.object else { throw AppError("\"plugins.\(id)\" must be an object.") }
                self.plugins[id] = object
            }
        }
        other = root
        migrateLegacyFormat()
    }

    /// Before plugins existed, the Obsidian capture settings lived at the top level.
    private mutating func migrateLegacyFormat() {
        let legacyKeys = ["vault", "obsidian", "diary_folder", "diary_format", "template", "destination_mode", "hotkeys"]
        guard legacyKeys.contains(where: { other[$0] != nil }) else { return }
        var capture = plugins["obsidian_capture"] ?? [:]
        for key in legacyKeys {
            if let value = other.removeValue(forKey: key), capture[key] == nil { capture[key] = value }
        }
        if capture["enabled"] == nil { capture["enabled"] = .bool(true) }
        plugins["obsidian_capture"] = capture
    }

    // MARK: Plugin accessors

    @MainActor func isEnabled(_ plugin: Plugin) -> Bool {
        plugins[plugin.id]?["enabled"]?.bool ?? plugin.enabledByDefault
    }

    @MainActor mutating func setEnabled(_ on: Bool, for plugin: Plugin) {
        plugins[plugin.id, default: [:]]["enabled"] = .bool(on)
    }

    /// nil when the action has no shortcut. An empty string in the file means "no shortcut".
    @MainActor func shortcutString(_ action: PluginAction, of plugin: Plugin) -> String? {
        let raw = plugins[plugin.id]?["hotkeys"]?.object?[action.id]
        guard let raw else { return action.defaultShortcut }
        guard let s = raw.string, !s.isEmpty else { return nil }
        return s
    }

    @MainActor func shortcut(_ action: PluginAction, of plugin: Plugin) -> Shortcut? {
        shortcutString(action, of: plugin).flatMap(Shortcut.init(config:))
    }

    @MainActor mutating func setShortcut(_ shortcut: Shortcut?, for action: PluginAction, of plugin: Plugin) {
        var hotkeys = plugins[plugin.id]?["hotkeys"]?.object ?? [:]
        hotkeys[action.id] = .string(shortcut?.configString ?? "")
        plugins[plugin.id, default: [:]]["hotkeys"] = .object(hotkeys)
    }

    @MainActor mutating func resetShortcuts(of plugin: Plugin) {
        plugins[plugin.id]?["hotkeys"] = nil
    }

    func settings<T: PluginSettings>(_ type: T.Type, for pluginID: String) throws -> T {
        var merged = (try? JSONValue(encoding: T()))?.object ?? [:]
        for (key, value) in plugins[pluginID] ?? [:] where !AppConfig.reservedKeys.contains(key) {
            merged[key] = value
        }
        do { return try JSONValue.object(merged).decode(T.self) } catch {
            throw AppError("Settings for “\(pluginID)” have a value of the wrong type: \(error.localizedDescription)")
        }
    }

    mutating func setSettings<T: PluginSettings>(_ settings: T, for pluginID: String) {
        guard let object = (try? JSONValue(encoding: settings))?.object else { return }
        for (key, value) in object { plugins[pluginID, default: [:]][key] = value }
    }

    /// Writes every registered plugin's defaults into the file, so all options are visible to people editing it.
    @MainActor func normalized(for registered: [Plugin]) -> AppConfig {
        var next = self
        for plugin in registered {
            var entry = next.plugins[plugin.id] ?? [:]
            if entry["enabled"] == nil, plugin.id != CorePlugin.pluginID { entry["enabled"] = .bool(plugin.enabledByDefault) }
            var hotkeys = entry["hotkeys"]?.object ?? [:]
            for action in plugin.actions where hotkeys[action.id] == nil {
                hotkeys[action.id] = .string(action.defaultShortcut ?? "")
            }
            if !plugin.actions.isEmpty { entry["hotkeys"] = .object(hotkeys) }
            for (key, value) in plugin.defaultSettings() where entry[key] == nil { entry[key] = value }
            next.plugins[plugin.id] = entry
        }
        return next
    }

    // MARK: Persistence

    static func load() throws -> AppConfig {
        let data = try Data(contentsOf: Paths.config)
        let root: JSONValue
        do { root = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw AppError("config.json is not valid JSON: \(error.localizedDescription)") }
        guard let object = root.object else { throw AppError("config.json must contain a JSON object.") }
        return try AppConfig(json: object)
    }

    func encoded() -> Data {
        var root = other
        root["plugins"] = .object(plugins.mapValues { .object($0) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(JSONValue.object(root))).map { $0 + Data("\n".utf8) } ?? Data()
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
