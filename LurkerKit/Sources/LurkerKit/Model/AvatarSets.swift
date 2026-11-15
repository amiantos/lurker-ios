// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What a letter, a silhouette or a placeholder glyph is drawn in over a tile's colour: near-white
/// or near-black, whichever reads on it. Mirrors `avatarInk` in the web's `shared/avatarTiles.ts`.
public enum AvatarInk: String, Equatable, Sendable {
    case light
    case dark

    /// Above this relative luminance a tile's colour takes dark ink, at or below it light. The two
    /// built-in nick palettes sit either side (the dark theme's pastels start at 0.305, the light
    /// theme's stop at 0.274), so each keeps the ink it was drawn for. The dark theme's muted grey
    /// (#939293, 0.289), which the apps put under a server line's mark, is above it too.
    public static let luminanceThreshold = 0.28

    /// WCAG 2 relative luminance of an sRGB colour, channels 0...1 (clamped), 0 (black) ... 1 (white).
    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            let c = min(max(channel, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The ink for a tile of this sRGB colour, channels 0...1.
    public static func on(red: Double, green: Double, blue: Double) -> AvatarInk {
        relativeLuminance(red: red, green: green, blue: blue) > luminanceThreshold ? .dark : .light
    }
}

/// One set generated avatars can draw from (lurker#607): a bundled one, or one the user uploaded
/// on the web. Mirrors `shared/avatarTiles.ts`'s `BUILTIN_AVATAR_SETS` plus the rows of
/// `GET /api/avatar-sets`.
public struct AvatarSet: Equatable, Sendable, Identifiable {
    /// Static image files under `baseUrl` (server-relative), numbered `000.<ext>` up to `count`.
    /// Zero tiles means the manifest hasn't been read yet: draw colour only.
    public struct Tiles: Equatable, Sendable {
        public let baseUrl: String
        public let count: Int
        public let ext: String

        public init(baseUrl: String, count: Int = 0, ext: String = "webp") {
            self.baseUrl = baseUrl
            self.count = count
            self.ext = ext
        }

        /// The directory's name under `/avatars`, which is what its manifest is read and kept by.
        var dir: String? { baseUrl.split(separator: "/").last.map(String.init) }

        /// These tiles counted by their own manifest, where it has been read.
        func counted(by manifests: [String: AvatarSetManifest]) -> Tiles {
            guard let dir, let manifest = manifests[dir] else { return self }
            return Tiles(baseUrl: baseUrl, count: manifest.count, ext: manifest.ext.isEmpty ? ext : manifest.ext)
        }
    }

    public enum Kind: Equatable, Sendable {
        case tiles(Tiles)
        /// One silhouette kept in both inks, each its own directory of tiles with its own
        /// manifest: the tile's colour says which (`AvatarInk.on`).
        case plain(light: Tiles, dark: Tiles)
        /// No files: the first letter of the shown name.
        case initial

        /// The tiles a nick on `ink` draws from, nil for a set with no files.
        func tiles(ink: AvatarInk) -> Tiles? {
            switch self {
            case .tiles(let tiles): tiles
            case .plain(let light, let dark): ink == .light ? light : dark
            case .initial: nil
            }
        }

        /// Every directory of tiles the set has.
        var directories: [Tiles] {
            switch self {
            case .tiles(let tiles): [tiles]
            case .plain(let light, let dark): [light, dark]
            case .initial: []
            }
        }

        func counted(by manifests: [String: AvatarSetManifest]) -> Kind {
            switch self {
            case .tiles(let tiles): .tiles(tiles.counted(by: manifests))
            case .plain(let light, let dark): .plain(light: light.counted(by: manifests), dark: dark.counted(by: manifests))
            case .initial: .initial
            }
        }
    }

    /// A bundled id, or an uploaded set's numeric id as a decimal string — what
    /// `look.avatars.set` holds.
    public let id: String
    public let name: String
    public let kind: Kind
    public let builtin: Bool

    public init(id: String, name: String, kind: Kind, builtin: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.builtin = builtin
    }

    /// How many tiles the set draws from; a Plain set's two directories hold the same tiles, so
    /// either says.
    public var tileCount: Int {
        kind.directories.map(\.count).max() ?? 0
    }

    /// The server-relative path of `nick`'s tile in this set, or nil when there is no image to
    /// draw: an Initial set, a tiles set whose manifest hasn't landed, or no nick. `ink` is what
    /// reads on the nick's colour — a Plain set has its silhouette in each. `stopChars` is
    /// the colour's (`look.nick.color_stop_chars`), resolved once by the caller for every row.
    public func tilePath(for nick: String?, stopChars: Set<Unicode.Scalar>, ink: AvatarInk) -> String? {
        guard let tiles = kind.tiles(ink: ink),
              let index = AvatarTiles.index(for: nick, count: tiles.count, stopChars: stopChars)
        else { return nil }
        return AvatarTiles.url(base: tiles.baseUrl, index: index, ext: tiles.ext)
    }
}

/// An uploaded set as `GET /api/avatar-sets` lists it.
public struct UploadedAvatarSet: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let count: Int

    public init(id: Int, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = count
    }
}

/// A bundled tiles set's `manifest.json`.
public struct AvatarSetManifest: Equatable, Sendable {
    public let count: Int
    public let ext: String

    public init(count: Int, ext: String = "webp") {
        self.count = count
        self.ext = ext
    }
}

/// Which sets exist and which one `look.avatars.set` points at (lurker#607, Mobile lurker#1203).
///
/// REST-fed rather than frame-fed, so it lives beside the view model, not in `ChatState`: the
/// bundled sets' tile counts come from each set's `manifest.json`, the uploaded sets from
/// `GET /api/avatar-sets` — on connect and again on `avatar-sets-changed`. The setting itself is
/// in `ChatState.settings` like every other key; `active(settings:)` resolves the pointer.
public struct AvatarSets: Equatable, Sendable {
    public static let settingKey = "look.avatars.set"
    /// What the registry defaults to and where a dangling pointer falls back.
    public static let defaultSetId = "initial"
    public static let ealainSetId = "ealain"

    /// The sets that ship with the client, counts unknown until their manifests are read.
    /// Same ids, names and order as the web.
    public static let builtins: [AvatarSet] = [
        AvatarSet(id: ealainSetId, name: "Ealain", kind: .tiles(.init(baseUrl: "/avatars/ealain")), builtin: true),
        AvatarSet(
            id: "plain", name: "Plain",
            kind: .plain(light: .init(baseUrl: "/avatars/plain-light"), dark: .init(baseUrl: "/avatars/plain-dark")),
            builtin: true
        ),
        AvatarSet(id: "initial", name: "Initial", kind: .initial, builtin: true),
    ]

    /// Initial and Plain each came in a light and a dark ink the user chose between, until the ink
    /// followed the tile's colour. The server moves a stored pointer (its schema v28); a server
    /// from before that still holds the old id, which means the set it became here.
    public static func currentSetId(_ id: String) -> String {
        switch id {
        case "initial-light", "initial-dark": "initial"
        case "plain-light", "plain-dark": "plain"
        default: id
        }
    }

    /// The id to write for a set: its own, or on a server from before schema v28 (one whose
    /// registry default is still an old id) the dark-ink id the set had there. That server's web
    /// client knows no `plain` or `initial` and would draw its default for either; the dark ink is
    /// the one its default had. Read back, either id is the same set here (`currentSetId`).
    public static func storedSetId(_ id: String, settings: Settings) -> String {
        guard let serverDefault = settings.registry[settingKey]?.default.stringValue,
              currentSetId(serverDefault) != serverDefault
        else { return id }
        switch id {
        case "initial": return "initial-dark"
        case "plain": return "plain-dark"
        default: return id
        }
    }

    /// The bundled tile directories whose manifests have been read, by directory name
    /// (`/avatars/<name>`).
    public var manifests: [String: AvatarSetManifest]
    public var uploaded: [UploadedAvatarSet]

    public init(manifests: [String: AvatarSetManifest] = [:], uploaded: [UploadedAvatarSet] = []) {
        self.manifests = manifests
        self.uploaded = uploaded
    }

    public static let none = AvatarSets()

    /// The bundled directories to fetch a manifest from, by name. A Plain set has one per ink,
    /// each counted by its own, as the web counts them.
    public static var builtinManifestDirs: [String] {
        builtins.flatMap { set in set.kind.directories.compactMap(\.dir) }
    }

    /// Every set, bundled first in the web's order, then the uploaded ones as listed.
    public var all: [AvatarSet] {
        let bundled = Self.builtins.map { set in
            AvatarSet(id: set.id, name: set.name, kind: set.kind.counted(by: manifests), builtin: true)
        }
        let mine = uploaded.map { row in
            AvatarSet(
                id: String(row.id), name: row.name,
                kind: .tiles(.init(baseUrl: "/api/avatar-sets/\(row.id)", count: row.count)),
                builtin: false
            )
        }
        return bundled + mine
    }

    /// The set an id names, an id from before the ink was automatic included.
    public func set(id: String) -> AvatarSet? {
        let current = Self.currentSetId(id)
        return all.first { $0.id == current }
    }

    /// The set `look.avatars.set` points at, or the default when it names nothing we know: an
    /// uploaded set not fetched yet, one deleted from another device, or an id from a newer
    /// client. The web's `activeSetId` resolves the same way.
    public func active(settings: Settings) -> AvatarSet {
        let pointer = settings.string(Self.settingKey, default: Self.defaultSetId)
        return set(id: pointer) ?? set(id: Self.defaultSetId) ?? Self.builtins[Self.builtins.count - 1]
    }

    /// The colour's stop characters as the tile hash wants them (`look.nick.color_stop_chars`).
    public static func stopChars(settings: Settings) -> Set<Unicode.Scalar> {
        AvatarTiles.stopChars(settings.string("look.nick.color_stop_chars", default: "_|"))
    }

    /// `nick`'s tile in the active set — `AvatarSet.tilePath` after `active(settings:)`. For one
    /// lookup; a list resolves the set once and asks it per row.
    public func tilePath(for nick: String?, settings: Settings, ink: AvatarInk) -> String? {
        active(settings: settings).tilePath(for: nick, stopChars: Self.stopChars(settings: settings), ink: ink)
    }

    // MARK: - Decoding

    /// `GET /api/avatar-sets` → `{items:[{id, name, count, bytes, createdAt}]}`. Nil for a body
    /// that isn't that shape, so a caller keeps what it had rather than reading garbage as
    /// "no sets".
    public static func parseList(_ data: Data) -> [UploadedAvatarSet]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = obj["items"] as? [[String: Any]]
        else { return nil }
        return items.compactMap { item in
            guard let id = item.intOrNull("id") else { return nil }
            let name = item.string("name")
            guard !name.isEmpty else { return nil }
            return UploadedAvatarSet(id: id, name: name, count: max(0, item.int("count")))
        }
    }

    /// A bundled set's `manifest.json` → `{count, ext}`. Nil unless `count` is a positive
    /// integer; `ext` defaults to webp, as the web's `ensureBuiltins` reads it.
    public static func parseManifest(_ data: Data) -> AvatarSetManifest? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let count = obj.intOrNull("count"), count > 0
        else { return nil }
        let ext = obj.string("ext")
        return AvatarSetManifest(count: count, ext: ext.isEmpty ? "webp" : ext)
    }
}
