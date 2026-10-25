import SwiftUI
import HWYDCore

struct SessionPlayerView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var scrubTime: Double?
    @State private var sliderEditing = false
    private var position: Double { scrubTime ?? model.playbackTime }
    private var hasAudio: Bool { !recording.audioChunks.isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13)).foregroundStyle(Studio.onAccent)
                        .frame(width: 34, height: 34).background(Studio.mint, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!hasAudio).opacity(hasAudio ? 1 : 0.4)
                    .accessibilityLabel(model.isPlaying ? "Mettre en pause" : "Lire les pistes")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lecture multipiste").font(.system(size: 12, weight: .medium))
                    Text(hasAudio ? "Micro et système synchronisés" : recording.isDemo ? "Exemple sans audio" : "Audio indisponible")
                        .font(.system(size: 10)).foregroundStyle(Studio.muted)
                }
                Spacer()
                Text(timeLabel(position)).foregroundStyle(Studio.text)
                Text("/ \(timeLabel(recording.duration))").foregroundStyle(Studio.muted)
            }.font(.system(size: 11, design: .monospaced))
            VStack(spacing: 6) {
                track(.mic, label: "Micro", icon: "mic", color: Studio.mint)
                track(.system, label: "Système", icon: "speaker.wave.2", color: Studio.muted)
            }
            HStack(spacing: 12) {
                Text("POSITION").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(Studio.muted).frame(width: 90, alignment: .leading)
                Slider(value: Binding(get: { position }, set: { if sliderEditing { scrubTime = $0 } else { model.seekPlayback(to: $0) } }), in: 0...max(1, recording.duration), onEditingChanged: { editing in
                    sliderEditing = editing
                    if !editing, let target = scrubTime { model.seekPlayback(to: target); scrubTime = nil }
                }).tint(Studio.mint).disabled(!hasAudio).accessibilityLabel("Position de lecture")
            }
            if let error = model.waveformError { Text(error).font(.system(size: 10)).foregroundStyle(Studio.muted) }
        }.padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Studio.line.opacity(0.6)))
            .padding(.vertical, 4)
    }
    private func track(_ source: AudioSource, label: String, icon: String, color: Color) -> some View {
        let available = recording.audioChunks.contains { $0.source == source }
        let audible = model.isTrackAudible(source)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Label(label, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                HStack(spacing: 4) {
                    trackButton("S", help: "Solo", label: label, active: model.soloTracks.contains(source)) { model.toggleSolo(source) }
                    trackButton("M", help: "Muet", label: label, active: model.mutedTracks.contains(source)) { model.toggleMute(source) }
                }.disabled(!available)
            }.frame(width: 90, alignment: .leading)
            ZStack {
                TrackWaveform(peaks: model.trackEnvelopes[source]?.peaks ?? [], progress: position / max(recording.duration, 1), color: color)
                    .opacity(audible ? 1 : 0.25)
                if model.trackEnvelopes[source] == nil {
                    Text(available ? (model.waveformLoading ? "Calcul de la forme d’onde…" : "Forme d’onde indisponible") : "Aucune piste audio")
                        .font(.system(size: 10)).foregroundStyle(Studio.muted)
                }
            }.frame(height: 46).frame(maxWidth: .infinity)
                .background(Studio.inset, in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().fill(Studio.text.opacity(0.65)).frame(width: 1)
                            .offset(x: geo.size.width * min(1, max(0, position / max(1, recording.duration))))
                    }.allowsHitTesting(false)
                }
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in scrubTime = min(1, max(0, value.location.x / max(1, geo.size.width))) * recording.duration }
                            .onEnded { _ in if let target = scrubTime { model.seekPlayback(to: target); scrubTime = nil } })
                    }.allowsHitTesting(available)
                }
                .accessibilityLabel("Forme d’onde \(label)")
        }
    }
    private func trackButton(_ title: String, help: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 9, weight: .semibold)).frame(width: 24, height: 19)
                .foregroundStyle(active ? Studio.onAccent : Studio.muted)
                .background(active ? Studio.mint : Studio.inset, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).help("\(help) : \(label)")
            .accessibilityLabel("\(help) \(label)").accessibilityValue(active ? "Activé" : "Désactivé")
    }
}

struct TrackWaveform: View {
    let peaks: [Float]
    var progress: Double
    var color: Color
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let bars = max(1, min(peaks.count, Int(size.width / 3)))
            for bar in 0..<bars {
                let first = bar * peaks.count / bars
                let last = max(first + 1, (bar + 1) * peaks.count / bars)
                let peak = peaks[first..<last].max() ?? 0
                // Square root gives quiet speech visibility; silence stays on the baseline.
                let height = max(1, min(1, sqrt(Double(peak))) * (size.height - 8))
                let x = Double(bar) * size.width / Double(bars)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(Double(bar) / Double(bars) <= progress ? 0.95 : 0.38)))
            }
        }.padding(.horizontal, 4).accessibilityHidden(true)
    }
}
