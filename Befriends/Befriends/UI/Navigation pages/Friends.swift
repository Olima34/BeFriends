//
//  Friends.swift
//  Befriends
//
//  Created by Vianney Dubosc on 04/03/2026.
//

import SwiftUI
import Combine

// On crée une petite structure pour aider au tri
enum ConnectionStatus: Int {
    case connected = 0
    case reconnecting = 1
    case disconnected = 2
}

struct FriendsView: View {
    @ObservedObject var manager = BluetoothManager.shared
    @StateObject var historyVM = HistoryViewModel()
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var tick = 0
    
    // --- LOGIQUE DE TRI ---
    var sortedFriends: [SavedFriend] {
        // 1. On associe à chaque ami ses données de tri
        let sortData = manager.savedFriends.map { friend -> (friend: SavedFriend, status: ConnectionStatus, duration: TimeInterval, lastSeen: Date) in
            
            if let session = manager.activeSessions.first(where: { $0.id == friend.id }) {
                if session.isConnected {
                    return (friend, .connected, session.duration, session.lastSeenTime)
                } else {
                    return (friend, .reconnecting, session.duration, session.lastSeenTime)
                }
            } else {
                // Déconnecté : on cherche la dernière session archivée pour le lastSeen
                let history = historyVM.groupedSessions[friend.id] ?? []
                let lastSeen = history.max(by: { $0.date < $1.date })?.date ?? .distantPast
                return (friend, .disconnected, 0, lastSeen)
            }
        }
        
        // 2. On trie le tableau selon tes règles
        let sorted = sortData.sorted { a, b in
            // Règle 1 : L'ordre des statuts (Connecté -> Reconnexion -> Déconnecté)
            if a.status != b.status {
                return a.status.rawValue < b.status.rawValue
            }
            
            // Règle 2 : Si même statut, on affine
            switch a.status {
            case .connected, .reconnecting:
                // Du plus long temps au plus court
                return a.duration > b.duration
            case .disconnected:
                // De la déconnexion la plus récente à la plus ancienne
                return a.lastSeen > b.lastSeen
            }
        }
        
        // 3. On ne renvoie que les amis triés
        return sorted.map { $0.friend }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 15) {
                    if manager.savedFriends.isEmpty {
                        Text("Tu n'as pas encore ajouté d'amis.")
                            .foregroundColor(.gray)
                            .padding(.top, 50)
                    } else {
                        // On utilise maintenant notre liste triée !
                        ForEach(sortedFriends, id: \.id) { friend in
                            NavigationLink(destination: FriendProfileView(friend: friend, manager: manager, historyVM: historyVM)) {
                                FriendStatusRow(friend: friend, manager: manager)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .padding()
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .navigationTitle("Mes Amis")
            .navigationBarTitleDisplayMode(.large)
            .onReceive(timer) { _ in
                tick += 1
            }
        }
    }
}

struct FriendStatusRow: View {
    let friend: SavedFriend
    @ObservedObject var manager: BluetoothManager
    
    var activeSession: ActiveSession? {
        manager.activeSessions.first(where: { $0.id == friend.id })
    }
    
    var body: some View {
        HStack(spacing: 15) {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 55, height: 55)
                .overlay(Image(systemName: "person.fill").foregroundColor(.white).font(.title2))
            
            VStack(alignment: .leading, spacing: 6) {
                // FIX: Limite sur 1 ligne et "..."
                Text(friend.displayName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                if let session = activeSession {
                    if session.isConnected {
                        HStack {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("Connecté").font(.caption).foregroundColor(.green).fontWeight(.bold)
                        }
                    } else {
                        HStack {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text("Reconnexion...").font(.caption).foregroundColor(.orange).fontWeight(.bold)
                        }
                    }
                } else {
                    HStack {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Déconnecté").font(.caption).foregroundColor(.gray)
                    }
                }
            }
            
            Spacer(minLength: 15) // Force un petit espace minimum avant la bulle
            
            if let session = activeSession {
                Text(formatLiveDuration(session.duration))
                    .font(.subheadline)
                    .fontWeight(.bold)
                    // FIX: Les chiffres prennent le même espace (empêche le sautillement)
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(session.isConnected ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                    .clipShape(Capsule())
            }
        }
        .padding()
        .background(Color(white: 0.12))
        .cornerRadius(16)
    }
    
    private func formatLiveDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
