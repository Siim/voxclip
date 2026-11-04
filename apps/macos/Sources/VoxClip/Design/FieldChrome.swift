import SwiftUI

/// The custom text field look the panels share (doc/design.md §16.1): `bg.input` with the `line.edge` outline, 10 pt
/// inside across. A one-line field is the 28 pt large control height; a multi-line field gets 8 pt above and below.
struct VCFieldChrome: ViewModifier {
    var multiline = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, VCTokens.spacingFieldPaddingX)
            .padding(.vertical, multiline ? VCTokens.spacingFieldPaddingY : 0)
            .frame(minHeight: 28)
            .background(DesignValues.color("bg.input"), in: .rect(cornerRadius: VCTokens.radiusControl))
            .overlay { RoundedRectangle(cornerRadius: VCTokens.radiusControl).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1) }
    }
}

extension View {
    func vcFieldChrome(multiline: Bool = false) -> some View { modifier(VCFieldChrome(multiline: multiline)) }
}
