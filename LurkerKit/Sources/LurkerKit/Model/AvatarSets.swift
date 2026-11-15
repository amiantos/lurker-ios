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
    /// theme's stop at 0.274), so each keeps the ink it was drawn for.
    public static let luminanceThreshold = 0.29

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
    public enum Kind: Equatable, Sendable {
        /// Static image files under `baseUrl` (server-relative), numbered `000.<ext>` up to
        /// `count`. Zero tiles means the manifest hasn't been read yet: draw colour only.
        case tiles(baseUrl: String, count: Int, ext: String)
        /// One silhouette kept in both inks, each a directory of tiles like `tiles`: the tile's
        /// colour says which (`AvatarInk.on`).
        case plain(light: String, dark: String, count: Int, ext: String)
        /// No files: the first letter of the shown name.
        case initial
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

    public var tileCount: Int {
        switch kind {
        case .tiles(_, let count, _), .plain(_, _, let count, _): return count
        case .initial: return 0
        }
    }

    /// The server-relative path of `nick`'s tile in this set, or nil when there is no image to
    /// draw: an Initial set, a tiles set whose manifest hasn't landed, or no nick. `ink` is what
    /// reads on the nick's colour — a Plain set has its silhouette in each. `stopChars` is
    /// the colour's (`look.nick.color_stop_chars`), resolved once by the caller for every row.
    public func tilePath(for nick: String?, stopChars: Set<Unicode.Scalar>, ink: AvatarInk) -> String? {
        let base: String, count: Int, ext: String
        switch kind {
        case .tiles(let url, let n, let e): (base, count, ext) = (url, n, e)
        case .plain(let light, let dark, let n, let e): (base, count, ext) = (ink == .light ? light : dark, n, e)
        case .initial: return nil
        }
        guard let index = AvatarTiles.index(for: nick, count: count, stopChars: stopChars) else { return nil }
        return AvatarTiles.url(base: base, index: index, ext: ext)
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
        AvatarSet(id: ealainSetId, name: "Ealain", kind: .tiles(baseUrl: "/avatars/ealain", count: 0, ext: "webp"), builtin: true),
        AvatarSet(
            id: "plain", name: "Plain",
            kind: .plain(light: "/avatars/plain-light", dark: "/avatars/plain-dark", count: 0, ext: "webp"), builtin: true
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

    /// The bundled tile directories whose manifests have been read, by directory name
    /// (`/avatars/<name>`).
    public var manifests: [String: AvatarSetManifest]
    public var uploaded: [UploadedAvatarSet]

    public init(manifests: [String: AvatarSetManifest] = [:], uploaded: [UploadedAvatarSet] = []) {
        self.manifests = manifests
        self.uploaded = uploaded
    }

    public static let none = AvatarSets()

    /// The bundled directories to fetch a manifest from. A Plain set's two hold the same tiles, so
    /// the light one speaks for the count.
    public static var builtinManifestDirs: [String] {
        builtins.compactMap { set in manifestDir(set.kind) }
    }

    private static func manifestDir(_ kind: AvatarSet.Kind) -> String? {
        let base: String
        switch kind {
        case .tiles(let url, _, _): base = url
        case .plain(let light, _, _, _): base = light
        case .initial: return nil
        }
        return base.split(separator: "/").last.map(String.init)
    }

    /// Every set, bundled first in the web's order, then the uploaded ones as listed.
    public var all: [AvatarSet] {
        let bundled = Self.builtins.map { set -> AvatarSet in
            guard let dir = Self.manifestDir(set.kind), let manifest = manifests[dir] else { return set }
            let kind: AvatarSet.Kind
            switch set.kind {
            case .tiles(let base, _, let ext):
                kind = .tiles(baseUrl: base, count: manifest.count, ext: manifest.ext.isEmpty ? ext : manifest.ext)
            case .plain(let light, let dark, _, let ext):
                kind = .plain(light: light, dark: dark, count: manifest.count, ext: manifest.ext.isEmpty ? ext : manifest.ext)
            case .initial:
                return set
            }
            return AvatarSet(id: set.id, name: set.name, kind: kind, builtin: true)
        }
        let mine = uploaded.map { row in
            AvatarSet(
                id: String(row.id), name: row.name,
                kind: .tiles(baseUrl: "/api/avatar-sets/\(row.id)", count: row.count, ext: "webp"),
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
