//
//  HistoryView.swift
//  Befriends
//
//  Created by Vianney Dubosc on 06/02/2026.
//

import SwiftUI
import Combine
import FirebaseFirestore

class HistoryViewModel: ObservableObject {
    // On groupe maintenant par ID (identifiant stable), pas par Nom
    @Published var groupedSessions: [String: [HistorySession]] = [:]
    @Published var totalDurations: [String: TimeInterval] = [:]

    // Le dictionnaire magique : [ID : "Surnom Actuel"]
    @Published var friendNames: [String: String] = [:]

    private var authCancellable: AnyCancellable?
    private var historyListener: ListenerRegistration?
    private var friendsListener: ListenerRegistration?

    init() {
        // On attend que l'auth Firebase soit prête avant de charger.
        // Si currentUserID est déjà défini (lancements suivants), le sink se déclenche immédiatement.
        authCancellable = FirebaseManager.shared.$currentUserID
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fetchAllData() }
    }

    deinit {
        historyListener?.remove()
        friendsListener?.remove()
    }

    func fetchAllData() {
        // Retirer les anciens listeners avant d'en créer de nouveaux
        historyListener?.remove()
        friendsListener?.remove()

        // 1. On charge les "Vrais Noms" actuels
        friendsListener = FirebaseManager.shared.listenToFriendsAttributes { [weak self] namesMap in
            self?.friendNames = namesMap
            // Si l'historique est déjà chargé, cela forcera l'UI à se rafraîchir avec les nouveaux noms
        }

        // 2. On charge l'historique
        historyListener = FirebaseManager.shared.listenToHistory { [weak self] sessions in
            guard let self = self else { return }
            
            // On groupe par friendID (MAC001), car lui ne change jamais !
            let grouped = Dictionary(grouping: sessions) { $0.friendID }
            self.groupedSessions = grouped
            
            var totals: [String: TimeInterval] = [:]
            for (id, sessions) in grouped {
                let total = sessions.reduce(0) { $0 + $1.duration }
                totals[id] = total
            }
            self.totalDurations = totals
        }
    }
    
    // Fonction utilitaire pour trouver le nom à afficher
    func getDisplayName(for friendID: String) -> String {
        // Soit on a le surnom actuel dans notre map, soit on met l'ID en attendant
        return friendNames[friendID] ?? friendID
    }
    
    func formatTotalTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    // Retourne les IDs triés par date de la session la plus récente
    var sortedFriendIDs: [String] {
        groupedSessions.keys.sorted {
            let latestA = groupedSessions[$0]?.first?.date ?? .distantPast
            let latestB = groupedSessions[$1]?.first?.date ?? .distantPast
            return latestA > latestB
        }
    }
}

struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if viewModel.groupedSessions.isEmpty {
                    VStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("Aucun historique")
                            .foregroundColor(.gray)
                            .padding(.top)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            ForEach(viewModel.sortedFriendIDs, id: \.self) { friendID in
                                
                                // On récupère le VRAI NOM actuel ici
                                let realName = viewModel.getDisplayName(for: friendID)
                                
                                if let sessions = viewModel.groupedSessions[friendID],
                                   let totalTime = viewModel.totalDurations[friendID] {
                                    
                                    FriendHistoryCard(
                                        friendName: realName, // On passe le nom dynamique
                                        totalTime: viewModel.formatTotalTime(totalTime),
                                        sessions: sessions
                                    )
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Historique")
            .navigationBarTitleDisplayMode(.large)
        }
        .colorScheme(.dark)
    }
}

struct FriendHistoryCard: View {
    let friendName: String
    let totalTime: String
    let sessions: [HistorySession]
    @State private var isExpanded: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text(friendName).font(.headline).foregroundColor(.white)
                    Spacer()
                    Text(totalTime).font(.headline).foregroundColor(.purple)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").foregroundColor(.gray)
                }
                .padding()
                .background(Color(white: 0.15))
            }
            
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        VStack {
                            Divider().background(Color.gray.opacity(0.3))
                            HStack {
                                Text(session.dateFormatted).font(.subheadline).foregroundColor(.gray)
                                Spacer()
                                Text(session.durationFormatted).font(.subheadline).foregroundColor(.white)
                            }
                            .padding()
                        }
                    }
                }
                .background(Color(white: 0.1))
            }
        }
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3), lineWidth: 1))
    }
}
