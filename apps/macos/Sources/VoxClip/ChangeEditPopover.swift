import SwiftUI

/// The edit popover of a proposed change (design.md §6.3.5): click its new words, or press
/// Return or F2 on the focused change. It holds the change's new words, the fit meter line of a
/// voice change, "Return saves · Esc cancels" and Reject Change. Saving reruns the local diff
/// and the fit meter; nothing is sent. Raised fill, a `line.strong` edge, radius 10, as the
/// fold popover.
struct ChangeEditPopover: View {
    let ordinal: Int
    /// The fit meter line for a text, nil where the change has none.
    let fit: (String) -> String?
    let save: (String) -> Void
    let reject: () -> Void
    let cancel: () -> Void
    @State private var text: String
    @FocusState private var editing: Bool

    init(ordinal: Int, words: String, fit: @escaping (String) -> String?, save: @escaping (String) -> Void, reject: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.ordinal = ordinal; self.fit = fit; self.save = save; self.reject = reject; self.cancel = cancel
        _text = State(initialValue: words)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New words for change \(ordinal)")
                .font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                .accessibilityHidden(true)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(VCType.body.font())
                .foregroundStyle(DesignValues.color("text.primary"))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DesignValues.color("bg.surface")))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1))
                .focused($editing)
                .onSubmit { save(text) }
                .onExitCommand(perform: cancel)
                .accessibilityLabel("New words for change \(ordinal)")
            if let line = fit(text) {
                Text(line).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            HStack(spacing: 8) {
                Text("Return saves · Esc cancels").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                Spacer(minLength: 8)
                Button("Reject Change", action: reject)
                    .buttonStyle(ChangeRejectButtonStyle())
                    .help("Leave this change out")
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DesignValues.color("bg.input")))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DesignValues.color("line.strong"), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit change \(ordinal)")
        .onAppear { editing = true }
    }
}

/// Reject Change: 12 pt `text.primary` on `bg.selectedRow`, 22 high, radius 6.
private struct ChangeRejectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VCType.callout.font())
            .foregroundStyle(DesignValues.color("text.primary"))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignValues.color("bg.selectedRow").opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
