import SwiftUI
import VoxClipCore

/// Settings › Clips (design.md §6.6 and §6.3.1): who makes the clips of every new video, with Claude mode's count and
/// cap (mirroring the editor's "Who makes the clips?" card and the clip style card's mode, Clips and Spend rows); then the
/// tones saved with "+ Save as my tone", with Rename and Delete in place. A renamed tone keeps its id, so clip styles that
/// chose it keep it; a deleted one plans as Auto from then on.
@MainActor struct ClipsSettings: View {
    @Bindable var app: AppModel
    @State private var renaming: String?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let settings = app.settings.clipsAutopilot
        Form {
            Section {
                Picker("Every new video", selection: Binding(get: { settings.mode?.rawValue ?? "" },
                                                             set: { if let mode = ClipsMode(rawValue: $0) { app.set(ClipsMode.key, .string(mode.rawValue)) } })) {
                    if settings.mode == nil { Text("Not chosen yet").tag("") }
                    Text("✦ Claude does it all").tag(ClipsMode.claude.rawValue)
                    Text("I'll pick").tag(ClipsMode.pick.rawValue)
                }
                .pickerStyle(.radioGroup)
                Picker("Clips per video", selection: Binding(get: { settings.count }, set: { app.set(ClipsMode.countKey, .number(Double($0))) })) {
                    ForEach(ClipsMode.counts, id: \.self) { Text("Top \($0)").tag($0) }
                }
                Picker("Spend per video", selection: Binding(get: { settings.capUSD }, set: { app.set(ClipsMode.capKey, .number(Double($0))) })) {
                    ForEach(ClipsMode.capsUSD, id: \.self) { Text(ClipStyleCard.spendLabel($0)).tag($0) }
                }
            } header: { Text("Who makes the clips") } footer: {
                Text("✦ Claude does it all: after a new video is transcribed and its clips found, Claude (Opus, extra high) makes the top clips postable by itself: cuts, rewording in your voice, captions, music and shape. The spend cap is your approval for ElevenLabs voice and generated music; Claude never spends past it and asks inline for more. I'll pick: Claude suggests clips and you press ✦ Make it postable on the ones you want.")
            }
            Section {
                let tones = app.myRewriteTones
                if tones.isEmpty {
                    Text("No saved tones yet. Type how you want words rewritten in Rewrite's field, then choose “+ Save as my tone”.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(tones) { tone in row(tone) }
            } header: {
                Text("Your tones")
            } footer: {
                Text("They show after the built-in tones in every Rewrite as strip and in the clip style card's Tone menu.")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("voxclip.settings.clips")
    }

    private func row(_ tone: RewriteTone) -> some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack(spacing: VCTokens.spacingRowGap) {
                if renaming == tone.id {
                    TextField("Tone name", text: $draft).focused($fieldFocused)
                        .onSubmit { commit(tone) }
                        .onExitCommand { renaming = nil }
                        .accessibilityIdentifier("voxclip.settings.clips.name.\(tone.id)")
                    Button("Save") { commit(tone) }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { renaming = nil }
                } else {
                    Text(tone.title).font(.body.weight(.semibold))
                    Spacer(minLength: VCTokens.spacingRowGap)
                    Button("Rename") { draft = tone.title; renaming = tone.id; fieldFocused = true }
                        .accessibilityLabel("Rename \(tone.title)")
                        .accessibilityIdentifier("voxclip.settings.clips.rename.\(tone.id)")
                    Button("Delete", role: .destructive) { app.deleteRewriteTone(tone.id) }
                        .accessibilityLabel("Delete \(tone.title)")
                        .accessibilityIdentifier("voxclip.settings.clips.delete.\(tone.id)")
                }
            }
            Text(tone.instruction).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, VCTokens.spacing2)
    }

    private func commit(_ tone: RewriteTone) {
        guard app.renameRewriteTone(tone.id, to: draft) else { return }
        renaming = nil
    }
}
