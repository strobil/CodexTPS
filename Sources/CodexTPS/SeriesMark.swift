import SwiftUI

/// Marks a series by its model family with an SF Symbol in the family's color, the color of its
/// chart line.
struct SeriesMark: View {
    let key: GroupKey
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: key.family.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(SeriesPalette.color(key.family))
            .frame(width: size + 4, height: size + 4)
    }
}
