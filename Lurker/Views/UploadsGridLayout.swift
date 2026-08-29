// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The uploads browser's grid geometry (#138): as many square tiles across as fit at a readable
/// size, never fewer than two.
///
/// Its own type rather than a private method on the screen so the arithmetic can be measured
/// against real UIKit rather than reasoned about. Compositional layout is full of rules that fail
/// visually and silently — the wrong item width collapses a grid to one column, an item wider than
/// its share of the group overflows the row — and none of them raise anything.
enum UploadsGrid {

    /// The narrowest a tile is allowed to get before a column is dropped. Below this the
    /// thumbnail stops being something the eye can scan, which is the entire argument for a grid.
    static let minimumTileWidth: CGFloat = 150

    /// The gutter between tiles, applied as an inset on each side of an item (so half of it per
    /// edge).
    static let gutter: CGFloat = 10

    /// Room under each tile for the filename and the meta line at the default text size. Only an
    /// estimate — the group is `.estimated`, so a cell that needs more (Dynamic Type, a wrapped
    /// name) measures itself and takes it.
    static let captionEstimate: CGFloat = 46

    static let sectionInsets = NSDirectionalEdgeInsets(top: 8, leading: 11, bottom: 16, trailing: 11)

    /// How many columns a container this wide gets.
    static func columns(forWidth width: CGFloat) -> Int {
        let content = width - sectionInsets.leading - sectionInsets.trailing
        return max(2, Int(content / minimumTileWidth))
    }

    /// Sized from the CONTAINER, not the screen: a split view or a Stage Manager window gets the
    /// column count its own width deserves rather than the device's.
    static func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = columns(forWidth: width)
            let tile = (width - sectionInsets.leading - sectionInsets.trailing) / CGFloat(columns)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                    // ⚠⚠ `.estimated`, NOT `.fractionalHeight(1)`. The fractional form means
                    // "exactly the group's height", which is a value the item is TOLD rather than
                    // one it measures — so the cell's own `systemLayoutSizeFitting` is discarded
                    // and the row never grows with Dynamic Type. Measured: the cell itself sized
                    // 210pt at the default text size and 282pt at AX XXXL, while the laid-out row
                    // stayed 217pt in both. Nothing raised; the caption simply clipped.
                    heightDimension: .estimated(tile + captionEstimate)
                )
            )
            // ⚠⚠ Gutters as item insets, NOT `interItemSpacing`. A repeating group divides its
            // width among `count` items and then adds the spacing on top of that, so fractional
            // items plus fixed spacing overflow the row — the sibling of the trap the buffer-list
            // grid hit, where a `.fractionalWidth(1)` item under `repeatingSubitem:count:2`
            // silently collapsed two columns into one. An inset comes out of the item's own share
            // and cannot overflow.
            item.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: gutter / 2, bottom: gutter + 4, trailing: gutter / 2)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    // Estimated, not absolute: a tile is a square of art over two labels that grow
                    // with Dynamic Type, so the cell measures itself and this is only a starting
                    // guess for the first pass.
                    heightDimension: .estimated(tile + captionEstimate)
                ),
                repeatingSubitem: item,
                count: columns
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = sectionInsets
            return section
        }
    }
}
