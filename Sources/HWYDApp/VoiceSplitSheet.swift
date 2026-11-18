import SwiftUI
import HWYDCore

/// Splits a voice that held two people one after the other, at the chosen passage.
struct VoiceSplitSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let recording: Recording
    let segment: TranscriptSegment
    let onSplit: (VoiceSplitSide) -> Void
    @State private var keeping: VoiceSplitSide = .before
    private var speaker: Speaker? { segment.speakerID.flatMap { id in recording.speakers.first { $0.id == id } } }
    var body: some View {
        let split = recording.voiceSplit(at: segment.id) ?? ([], [])
        let label = speaker?.label ?? String(localized: "Voix")
        let time = timeLabel(segment.start)
        VStack(alignment: .leading, spacing: 18) {
            Text("Scinder la voix").font(.system(size: Studio.Size.heading, weight: .semibold))
            Text("Deux personnes ont parlé l’une après l’autre sous « \(label) » ? Ses passages sont coupés à \(time) : une des deux parties devient une nouvelle voix.")
                .font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                part(String(localized: "AVANT \(time)"), split.before, preview: split.before.last)
                part(String(localized: "À PARTIR DE \(time)"), split.after, preview: split.after.first)
            }
            if speaker?.confirmed == true {
                VStack(alignment: .leading, spacing: 8) {
                    Text("« \(label) » parle :").font(.system(size: Studio.Size.body, weight: .medium))
                    Picker("« \(label) » parle :", selection: $keeping) {
                        Text("Avant \(time)").tag(VoiceSplitSide.before)
                        Text("À partir de \(time)").tag(VoiceSplitSide.after)
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
            Text("L’autre partie devient une nouvelle voix, à nommer ensuite. Aucune empreinte vocale n’est lue ni modifiée, et la scission peut être annulée.")
                .font(.caption).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Scinder") { onSplit(speaker?.confirmed == true ? keeping : .before) }
                    .buttonStyle(StudioButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(split.before.isEmpty || split.after.isEmpty || model.voiceEditingLocked)
            }
        }.padding(26).frame(width: 560).background(Studio.background).foregroundStyle(Studio.text)
    }
    private func part(_ title: String, _ passages: [TranscriptSegment], preview: TranscriptSegment?) -> some View {
        let speech = passages.reduce(0) { $0 + max(0, $1.end - $1.start) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: Studio.Size.caption, weight: .semibold)).foregroundStyle(Studio.muted)
            Text("\(passages.count) passage(s) · \(Duration.seconds(speech).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))")
                .font(.system(size: Studio.Size.body, weight: .medium))
            if let preview {
                Text(preview.text).font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted).lineLimit(3)
                Button { model.play(at: preview.start) } label: { Label("Écouter \(timeLabel(preview.start))", systemImage: "play.fill") }
                    .buttonStyle(StudioButtonStyle(compact: true)).help("Lire la session à partir de ce passage")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 7))
    }
}
