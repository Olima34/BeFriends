//
//  FriendProfileView.swift
//  Befriends
//
//  Created by Vianney Dubosc on 04/03/2026.
//

import SwiftUI

struct FriendProfileView: View {
    let friend: SavedFriend
    @ObservedObject var manager: BluetoothManager
    @ObservedObject var historyVM: HistoryViewModel
    
    @Environment(\.dismiss) var dismiss
    
    @State private var isEditingHistory = false
    @State private var selectedSessions = Set<String>()
    
    @State private var showDeleteHistoryAlert = false
    @State private var showDeleteFriendAlert = false
    
    // NOUVEAU : États pour le renommage
    @State private var showRenameAlert = false
    @State private var newName = ""
    
    var friendHistory: [HistorySession] {
        historyVM.groupedSessions[friend.id] ?? []
    }
    
    var totalTimeWithFriend: TimeInterval {
        friendHistory.reduce(0) { $0 + $1.duration }
    }
    
    var activeSession: ActiveSession? {
        manager.activeSessions.first(where: { $0.id == friend.id })
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                
                // --- EN-TÊTE : PHOTO ET NOM ---
                VStack(spacing: 15) {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 100, height: 100)
                        .overlay(Image(systemName: "person.fill").foregroundColor(.white).font(.system(size: 50)))
                    
                    // NOUVEAU : Le nom avec le bouton d'édition
                    HStack {
                        Text(friend.displayName)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Button(action: {
                            newName = friend.displayName
                            showRenameAlert = true
                        }) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.top, 20)
                
                // --- BLOC D'INFORMATIONS PRINCIPALES ---
                VStack(spacing: 15) {
                    HStack {
                        Text("Statut actuel").foregroundColor(.gray)
                        Spacer()
                        if let session = activeSession {
                            // NOUVEAU : On affiche si on est en attente d'acceptation de l'autre
                            if manager.waitingForMutual.contains(friend.id) {
                                Text("En attente d'acceptation").foregroundColor(.yellow).fontWeight(.bold)
                            } else if session.isConnected {
                                Text("Connecté").foregroundColor(.green).fontWeight(.bold)
                            } else {
                                Text("Signal perdu").foregroundColor(.orange).fontWeight(.bold)
                            }
                        } else {
                            Text("Déconnecté").foregroundColor(.red).fontWeight(.bold)
                        }
                    }
                    Divider().background(Color.gray.opacity(0.5))
                    HStack {
                        Text("Temps total partagé").foregroundColor(.gray)
                        Spacer()
                        Text(historyVM.formatTotalTime(totalTimeWithFriend))
                            .foregroundColor(.white).fontWeight(.bold)
                    }
                }
                .padding()
                .background(Color(white: 0.12))
                .cornerRadius(16)
                .padding(.horizontal)
                
                // --- SECTION : HISTORIQUE DES SESSIONS ---
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("Historique des sessions").font(.title3).fontWeight(.bold).foregroundColor(.white)
                        Spacer()
                        if !friendHistory.isEmpty {
                            Button(action: {
                                withAnimation {
                                    isEditingHistory.toggle()
                                    selectedSessions.removeAll()
                                }
                            }) {
                                Text(isEditingHistory ? "Annuler" : "Modifier")
                                    .font(.subheadline)
                                    .foregroundColor(.purple)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    if isEditingHistory {
                        HStack {
                            Button(action: {
                                if selectedSessions.count == friendHistory.count { selectedSessions.removeAll() }
                                else { selectedSessions = Set(friendHistory.map { $0.id }) }
                            }) {
                                Text(selectedSessions.count == friendHistory.count ? "Tout désélectionner" : "Tout sélectionner")
                                    .font(.caption).foregroundColor(.purple).padding(.vertical, 5).contentShape(Rectangle())
                            }
                            Spacer()
                            if !selectedSessions.isEmpty {
                                Button(action: { showDeleteHistoryAlert = true }) {
                                    Image(systemName: "trash.fill").foregroundColor(.red).padding(8).contentShape(Rectangle())
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    if friendHistory.isEmpty {
                        Text("Aucune session archivée pour l'instant.").foregroundColor(.gray).italic().padding(.horizontal)
                    } else {
                        ForEach(friendHistory.sorted(by: { $0.date > $1.date })) { session in
                            HStack(spacing: 15) {
                                if isEditingHistory {
                                    Image(systemName: selectedSessions.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedSessions.contains(session.id) ? .purple : .gray).font(.title2)
                                        .onTapGesture {
                                            if selectedSessions.contains(session.id) { selectedSessions.remove(session.id) }
                                            else { selectedSessions.insert(session.id) }
                                        }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(formatDate(session.date)).font(.subheadline).foregroundColor(.white)
                                    Text("à \(formatTime(session.date))").font(.caption).foregroundColor(.gray)
                                }
                                Spacer()
                                Text(historyVM.formatTotalTime(session.duration)).font(.subheadline).fontWeight(.bold).foregroundColor(isEditingHistory ? .gray : .purple)
                            }
                            .padding().background(Color(white: 0.12)).cornerRadius(12).padding(.horizontal)
                            .onTapGesture {
                                if isEditingHistory {
                                    if selectedSessions.contains(session.id) { selectedSessions.remove(session.id) }
                                    else { selectedSessions.insert(session.id) }
                                }
                            }
                        }
                    }
                }
                
                Spacer(minLength: 40)
                
                // --- BOUTON : SUPPRIMER L'AMI ---
                Button(action: { showDeleteFriendAlert = true }) {
                    Text("Supprimer l'ami")
                        .font(.headline).foregroundColor(.red).frame(maxWidth: .infinity).padding()
                        .background(Color.red.opacity(0.15)).cornerRadius(16)
                }
                .padding(.horizontal).padding(.bottom, 30)
            }
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .navigationBarTitleDisplayMode(.inline)
        
        // --- ALERTES ---
        .alert("Renommer l'ami", isPresented: $showRenameAlert) {
            TextField("Nouveau nom", text: $newName)
            Button("Enregistrer") { manager.updateFriendName(id: friend.id, newName: newName) }
            Button("Annuler", role: .cancel) { }
        }
        .alert("Supprimer des sessions", isPresented: $showDeleteHistoryAlert) {
            Button("Supprimer", role: .destructive) { deleteSelectedSessions() }
            Button("Annuler", role: .cancel) { }
        } message: { Text("Es-tu sûr de vouloir supprimer ces \(selectedSessions.count) session(s) ?") }
        
        .alert("Supprimer l'ami", isPresented: $showDeleteFriendAlert) {
            Button("Supprimer", role: .destructive) { removeFriend() }
            Button("Annuler", role: .cancel) { }
        } message: { Text("Es-tu sûr de vouloir retirer \(friend.displayName) de tes amis ? L'historique sera conservé si vous redevenez amis plus tard.") }
    }
    
    private func deleteSelectedSessions() {
        for sessionId in selectedSessions { FirebaseManager.shared.deleteHistorySession(id: sessionId) }
        if var sessions = historyVM.groupedSessions[friend.id] {
            sessions.removeAll { selectedSessions.contains($0.id) }
            historyVM.groupedSessions[friend.id] = sessions
        }
        withAnimation { isEditingHistory = false; selectedSessions.removeAll() }
    }
    
    private func removeFriend() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { manager.removeFriend(id: friend.id) }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeStyle = .short; return formatter.string(from: date)
    }
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true; formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: date).capitalized
    }
}
