import SwiftUI
import HWYDCore

struct VoiceIdentityView: View {
    @EnvironmentObject var model: AppModel
    @State private var speakerID: UUID?
    @State private var personID: UUID?
    @State private var name = ""
    @State private var consent = false
    @State private var cleanSpeech = false
    @State private var channel: VoiceChannel = .room
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Identité des voix").font(.title2); Spacer(); Button("Fermer") { model.showVoiceIdentity = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Une correction de nom ne crée jamais d’empreinte. L’enrôlement ci-dessous conserve des données vocales biométriques dans le trousseau de ce Mac.").font(.callout).foregroundStyle(Studio.muted)
                    Picker("Canal", selection: $channel) {
                        Text("Proche · moi").tag(VoiceChannel.near); Text("Salle").tag(VoiceChannel.room); Text("Visio").tag(VoiceChannel.remote)
                    }
                    Button("Chercher les voix consenties") { model.runVoice(command: "identify-voices", channel: channel) }.buttonStyle(StudioButtonStyle()).disabled(model.people.allSatisfy { $0.consentedAt == nil || $0.opposed })
                    Text("Reconnaissance expérimentale. Chaque proposition doit être confirmée. Une voix apprise en salle reste distincte de son empreinte en visio.").font(.caption).foregroundStyle(Studio.muted)
                    ForEach(model.selected?.speakers ?? []) { speaker in
                        if let match = speaker.proposedIdentity, let person = model.people.first(where: { $0.id == match.personID && !$0.opposed }) {
                            HStack { Text("\(speaker.label) → \(person.name) (\(match.score, specifier: "%.2f"))"); Spacer(); Button("Confirmer") { model.confirmIdentity(speakerID: speaker.id, person: person) } }
                        }
                    }
                    Divider()
                    Text("Enrôler une voix").font(.headline)
                    Picker("Voix corrigée", selection: $speakerID) {
                        Text("Choisir…").tag(nil as UUID?)
                        ForEach((model.selected?.speakers ?? []).filter { channel == .remote ? $0.source == .system : $0.source == .mic }) { Text($0.label).tag(Optional($0.id)) }
                    }
                    Picker("Personne", selection: $personID) {
                        Text("Nouvelle personne").tag(nil as UUID?)
                        ForEach(model.people.filter { !$0.opposed }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if personID == nil { TextField("Nom", text: $name).textFieldStyle(.roundedBorder) }
                    Toggle("Cette personne a explicitement consenti à la mémorisation et à la reconnaissance de sa voix.", isOn: $consent)
                    Toggle("J’ai vérifié les passages : une seule personne, sans écho ni voix superposée.", isOn: $cleanSpeech)
                    Button("Créer l’empreinte consentie") {
                        let person = model.people.first { $0.id == personID } ?? VoicePerson(name: name.trimmingCharacters(in: .whitespacesAndNewlines), consentedAt: Date())
                        model.runVoice(command: "enroll-voice", speakerID: speakerID, person: person, channel: channel)
                        consent = false; cleanSpeech = false
                    }.buttonStyle(StudioButtonStyle(primary: true)).disabled(!consent || !cleanSpeech || speakerID == nil || (personID == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    Text("20 secondes minimum de parole propre. Aucun vecteur dans les fichiers, les exports ou SQLite.").font(.caption).foregroundStyle(Studio.muted)
                    Divider()
                    Text("Personnes mémorisées").font(.headline)
                    ForEach(model.people) { person in
                        HStack {
                            Text(person.name); Spacer()
                            if person.opposed { Text("Opposition active").foregroundStyle(Studio.muted) }
                            Button(person.opposed ? "Réessayer l’effacement" : "Effacer et opposer") {
                                var opposed = person; opposed.opposed = true; opposed.consentedAt = nil
                                model.runVoice(command: "forget-voice", person: opposed)
                            }
                        }
                    }
                }
            }.disabled(model.voiceBusy)
            if model.voiceBusy { ProgressView("Traitement local…") }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(Studio.mint) }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(Studio.copper) }
        }.padding(24).frame(width: 610, height: 700).foregroundStyle(Studio.text).background(Studio.background)
            .preferredColorScheme(model.appearancePreference.colorScheme)
            .onChange(of: channel) { _, _ in speakerID = nil; consent = false; cleanSpeech = false }
    }
}
