import SwiftUI

struct ScanView: View {
    @ObservedObject var manager: BluetoothManager
    
    // États locaux pour le renommage
    @State private var idToRename: String?
    @State private var newNameInput: String = ""
    @State private var showRenameAlert = false
    
    var body: some View {
        NavigationView {
            List {
                // PARTIE 1 : DEMANDES
                if !manager.pendingRequests.isEmpty {
                    Section(header: Text("Nouvelles détections")) {
                        ForEach(manager.pendingRequests) { request in
                            HStack {
                                Image(systemName: "person.crop.circle.badge.questionmark")
                                    .font(.title2).foregroundColor(.orange)
                                VStack(alignment: .leading) {
                                    Text(request.originalName).font(.headline)
                                    Text("Approuver pour démarrer").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Ajouter") { manager.acceptFriend(request) }
                                    .buttonStyle(.borderedProminent).tint(.blue).font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                // PARTIE 2 : AMIS CONNECTÉS
                Section(header: Text("Amis à proximité")) {
                    if manager.activeSessions.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Recherche de signaux Befriends...")
                                .foregroundColor(.secondary).italic()
                        }
                        .padding(.vertical)
                    } else {
                        ForEach(manager.activeSessions) { session in
                            ActiveSessionRow(session: session, manager: manager, onRename: {
                                idToRename = session.id
                                newNameInput = manager.getDisplayName(for: session.id, fallbackName: session.originalName)
                                showRenameAlert = true
                            })
                        }
                    }
                }
            }
            .navigationTitle("Befriends")
            // Plus de bouton lune dans la toolbar !
            .alert("Renommer l'ami", isPresented: $showRenameAlert) {
                TextField("Nouveau nom", text: $newNameInput)
                Button("Annuler", role: .cancel) { }
                Button("Enregistrer") {
                    if let id = idToRename { manager.updateFriendName(id: id, newName: newNameInput) }
                }
            }
        }
    }
}

// Petit composant extrait pour alléger
struct ActiveSessionRow: View {
    let session: ActiveSession
    @ObservedObject var manager: BluetoothManager
    var onRename: () -> Void

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack {
                Image(systemName: "person.circle.fill")
                    .font(.title)
                    .foregroundColor(session.isConnected ? .green : .orange)

                VStack(alignment: .leading) {
                    HStack {
                        Text(manager.getDisplayName(for: session.id, fallbackName: session.originalName))
                            .font(.headline)
                        Button(action: onRename) {
                            Image(systemName: "pencil").font(.caption).foregroundColor(.blue)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    Text(formattedDuration(session.duration))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()

                if manager.waitingForMutual.contains(session.id) {
                    Text("En attente...")
                        .font(.caption2).fontWeight(.bold)
                        .padding(6).background(Color.yellow.opacity(0.2))
                        .foregroundColor(.yellow).cornerRadius(8)
                } else if session.isConnected {
                    Text("En ligne")
                        .font(.caption2).fontWeight(.bold)
                        .padding(6).background(Color.green.opacity(0.2))
                        .foregroundColor(.green).cornerRadius(8)
                } else {
                    Text("Reconnexion...")
                        .font(.caption2).fontWeight(.bold)
                        .padding(6).background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange).cornerRadius(8)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
