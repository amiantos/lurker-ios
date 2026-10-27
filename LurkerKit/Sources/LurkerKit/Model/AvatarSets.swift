// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The ink an Initial set draws its letter in, and a placeholder tile draws its glyph in.
public enum AvatarInk: String, Equatable, Sendable {
    case light
    case dark
}

/// One set generated avatars can draw from (lurker#607): a bundled one, or one the user uploaded
/// on the web. Mirrors `shared/avatarTiles.ts`'s `BUILTIN_AVATAR_SETS` plus the rows of
/// `GET /api/avatar-sets`.
public struct AvatarSet: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Static image files under `baseUrl` (server-relative), numbered `000.<ext>` up to
        /// `count`. Zero tiles means the manifest hasn't been read yet: draw colour only.
        case tiles(baseUrl: String, count: Int, ext: String)
        /// No files: the first letter of the shown name, in `ink`.
        case initial(ink: AvatarInk)
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

    /// The ink for a letter or a placeholder glyph on this set's tiles: an Initial set's own,
    /// light for a tiles set — the web's `NickAvatar` makes the same choice.
    public var ink: AvatarInk {
        if case .initial(let ink) = kind { return ink }
        return .light
    }

    public var tileCount: Int {
        if case .tiles(_, let count, _) = kind { return count }
        return 0
    }

    /// The server-relative path of `nick`'s tile in this set, or nil when there is no image to
    /// draw: an Initial set, a tiles set whose manifest hasn't landed, or no nick. `stopChars` is
    /// the colour's (`look.nick.color_stop_chars`), resolved once by the caller for every row.
    public func tilePath(for nick: String?, stopChars: Set<Unicode.Scalar>) -> String? {
        guard case .tiles(let base, let count, let ext) = kind,
              let index = AvatarTiles.index(for: nick, count: count, stopChars: stopChars)
        else { return nil }
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
    public static let defaultSetId = "initial-dark"
    public static let ealainSetId = "ealain"

    /// The sets that ship with the client, counts unknown until their manifests are read.
    /// Same ids, names and order as the web.
    public static let builtins: [AvatarSet] = [
        AvatarSet(id: ealainSetId, name: "Ealain", kind: .tiles(baseUrl: "/avatars/ealain", count: 0, ext: "webp"), builtin: true),
        AvatarSet(id: "plain-light", name: "Plain (Light)", kind: .tiles(baseUrl: "/avatars/plain-light", count: 0, ext: "webp"), builtin: true),
        AvatarSet(id: "plain-dark", name: "Plain (Dark)", kind: .tiles(baseUrl: "/avatars/plain-dark", count: 0, ext: "webp"), builtin: true),
        AvatarSet(id: "initial-light", name: "Initial (Light)", kind: .initial(ink: .light), builtin: true),
        AvatarSet(id: "initial-dark", name: "Initial (Dark)", kind: .initial(ink: .dark), builtin: true),
    ]

    /// The bundled tiles sets whose manifests have been read, by id.
    public var manifests: [String: AvatarSetManifest]
    public var uploaded: [UploadedAvatarSet]

    public init(manifests: [String: AvatarSetManifest] = [:], uploaded: [UploadedAvatarSet] = []) {
        self.manifests = manifests
        self.uploaded = uploaded
    }

    public static let none = AvatarSets()

    /// The bundled ids that have files to fetch a manifest for.
    public static var builtinTileSetIds: [String] {
        builtins.compactMap { set in
            if case .tiles = set.kind { return set.id }
            return nil
        }
    }

    /// Every set, bundled first in the web's order, then the uploaded ones as listed.
    public var all: [AvatarSet] {
        let bundled = Self.builtins.map { set -> AvatarSet in
            guard case .tiles(let base, _, let ext) = set.kind else { return set }
            guard let manifest = manifests[set.id] else { return set }
            return AvatarSet(
                id: set.id, name: set.name,
                kind: .tiles(baseUrl: base, count: manifest.count, ext: manifest.ext.isEmpty ? ext : manifest.ext),
                builtin: true
            )
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

    public func set(id: String) -> AvatarSet? {
        all.first { $0.id == id }
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
    public func tilePath(for nick: String?, settings: Settings) -> String? {
        active(settings: settings).tilePath(for: nick, stopChars: Self.stopChars(settings: settings))
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
