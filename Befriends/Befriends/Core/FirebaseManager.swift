//
//  FirebaseManager.swift
//  Befriends
//
//  Created by Vianney Dubosc on 11/02/2026.
//

import Foundation
import SwiftUI
import Combine
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

class FirebaseManager: ObservableObject {
    static let shared = FirebaseManager()

    let db = Firestore.firestore()
    @Published var currentUserID: String?
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var pendingHistoryItems: [HistorySession] = []
    private var commandListener: ListenerRegistration?

    init() {
        // Lecture cache immédiate si l'utilisateur est déjà connu
        if let user = Auth.auth().currentUser {
            self.currentUserID = user.uid
            print("🔥 Firebase Init : Utilisateur déjà connu (\(user.uid))")
        }

        // Listener pour réagir aux changements d'auth
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                if let user = user {
                    if self?.currentUserID != user.uid {
                        print("🔥 Auth changée : nouvel UID \(user.uid)")
                        self?.currentUserID = user.uid
                        self?.flushPendingItems()
                    }
                } else {
                    print("🔥 Auth perdue : Aucun utilisateur connecté.")
                    self?.currentUserID = nil
                    // ON A SUPPRIMÉ "signInAnonymously()" ICI AUSSI
                }
            }
        }
    }
    
    private func flushPendingItems() {
        guard !pendingHistoryItems.isEmpty else { return }
        print("📤 Envoi de \(pendingHistoryItems.count) sessions en attente...")
        let items = pendingHistoryItems
        pendingHistoryItems.removeAll()
        for item in items {
            saveHistoryItem(item)
        }
    }
    
    // --- SAUVEGARDE DE L'HISTORIQUE (PARTAGÉ) ---
    func saveHistoryItem(_ item: HistorySession) {
        guard let user = Auth.auth().currentUser else {
            print("⏳ Auth non prête : session mise en file d'attente")
            pendingHistoryItems.append(item)
            return
        }
        
        let myStableID = String(user.uid.prefix(6))
        let myName = user.displayName ?? "Utilisateur"
        
        // 👇 On arrondit la durée à la seconde la plus proche
        let roundedDuration = round(item.duration)
        
        print("☁️ ENVOI FIREBASE : Archivage PARTAGÉ de \(item.friendName) (\(Int(roundedDuration))s)...")
        
        // On enregistre les deux participants et leurs noms
        let data: [String: Any] = [
            "participants": [myStableID, item.friendID],
            "participantNames": [
                myStableID: myName,
                item.friendID: item.friendName
            ],
            "duration": roundedDuration, // 👈 La valeur arrondie est utilisée ici
            "date": item.date
        ]
        
        // On sauvegarde dans la collection GOLBALE commune
        db.collection("shared_history").addDocument(data: data) { error in
            if let error = error {
                print("🔥 Erreur sauvegarde historique partagé: \(error)")
            } else {
                print("✅ Session archivée dans le Cloud commun avec succès (\(Int(roundedDuration))s) !")
            }
        }
    }
    
    // --- SAUVEGARDE D'UN AMI ---
    func saveFriend(_ friend: SavedFriend) {
        guard let uid = currentUserID else { return }
        
        let data: [String: Any] = [
            "id": friend.id,
            "originalName": friend.originalName,
            "customName": friend.customName ?? ""
        ]
        
        db.collection("users").document(uid).collection("friends").document(friend.id).setData(data) { error in
            if let error = error { print("🔥 Erreur sauvegarde ami: \(error)") }
        }
    }
    
    // --- CHARGEMENT UNIQUE (Pour le rafraîchissement manuel si besoin) ---
    func fetchHistory(completion: @escaping ([HistorySession]) -> Void) {
        guard let user = Auth.auth().currentUser else { return }
        let myStableID = String(user.uid.prefix(6))
        
        db.collection("shared_history")
            .whereField("participants", arrayContains: myStableID)
            .getDocuments { snapshot, error in
                guard let documents = snapshot?.documents else {
                    completion([])
                    return
                }
                
                var rawSessions: [HistorySession] = []
                for doc in documents {
                    let data = doc.data()
                    guard let participants = data["participants"] as? [String],
                          let names = data["participantNames"] as? [String: String],
                          let dur = data["duration"] as? TimeInterval,
                          let stamp = data["date"] as? Timestamp else { continue }
                    
                    let friendID = participants.first(where: { $0 != myStableID }) ?? "Inconnu"
                    let friendName = names[friendID] ?? "Ami Inconnu"
                    
                    rawSessions.append(HistorySession(id: doc.documentID, friendID: friendID, friendName: friendName, duration: dur, date: stamp.dateValue()))
                }
                
                // 🛡️ DÉDUPLICATION CORRIGÉE : Fenêtre de 60 secondes
                var uniqueSessions: [HistorySession] = []
                for session in rawSessions {
                    if let idx = uniqueSessions.firstIndex(where: { $0.friendID == session.friendID && abs($0.date.timeIntervalSince(session.date)) < HISTORY_DEDUPLICATION_WINDOW }) {
                        if session.duration > uniqueSessions[idx].duration {
                            uniqueSessions[idx] = session
                        }
                    } else {
                        uniqueSessions.append(session)
                    }
                }
                
                uniqueSessions.sort(by: { $0.date > $1.date })
                completion(uniqueSessions)
            }
    }
    
    // --- SUPPRESSION DES DOUBLONS DANS LA BASE COMMUNE ---
    func checkAndDeleteDuplicateSession(friendID: String, presumedDuration: TimeInterval) {
        guard let user = Auth.auth().currentUser else { return }
        let myStableID = String(user.uid.prefix(6))

        let presumedStartTime = Date().addingTimeInterval(-presumedDuration)
        let safeThresholdDate = presumedStartTime.addingTimeInterval(-DUPLICATE_SEARCH_WINDOW)

        db.collection("shared_history")
            .whereField("participants", arrayContains: myStableID)
            .getDocuments { snapshot, error in
                guard let documents = snapshot?.documents else { return }

                for document in documents {
                    let data = document.data()
                    guard let participants = data["participants"] as? [String] else { continue }
                    
                    // On s'assure que c'est bien la session partagée avec cet ami précis
                    if participants.contains(friendID) {
                        if let savedDuration = data["duration"] as? TimeInterval,
                           let timestamp = data["date"] as? Timestamp {
                            
                            if timestamp.dateValue() > safeThresholdDate && savedDuration < presumedDuration {
                                print("   🗑️ Fragment partagé détecté et supprimé pour les DEUX téléphones !")
                                document.reference.delete()
                            }
                        }
                    }
                }
            }
    }
    
    // --- LECTURE DE L'HISTORIQUE (Temps Réel & Partagé) ---
    @discardableResult
    func listenToHistory(completion: @escaping ([HistorySession]) -> Void) -> ListenerRegistration? {
        guard let user = Auth.auth().currentUser else { return nil }
        let myStableID = String(user.uid.prefix(6))

        // On cherche toutes les sessions où NOTRE ID est dans les participants
        return db.collection("shared_history")
            .whereField("participants", arrayContains: myStableID)
            .addSnapshotListener { snapshot, error in
                if let error = error {
                    print("❌ Erreur lecture historique partagé : \(error.localizedDescription)")
                    return
                }
                
                guard let documents = snapshot?.documents else {
                    completion([])
                    return
                }
                
                var rawSessions: [HistorySession] = []
                for doc in documents {
                    let data = doc.data()
                    guard let participants = data["participants"] as? [String],
                          let names = data["participantNames"] as? [String: String],
                          let duration = data["duration"] as? TimeInterval,
                          let timestamp = data["date"] as? Timestamp else { continue }
                    
                    // On détermine qui est l'autre personne dans la session
                    let friendID = participants.first(where: { $0 != myStableID }) ?? "Inconnu"
                    let friendName = names[friendID] ?? "Ami Inconnu"
                    
                    rawSessions.append(HistorySession(
                        id: doc.documentID,
                        friendID: friendID,
                        friendName: friendName,
                        duration: duration,
                        date: timestamp.dateValue()
                    ))
                }
                
                // 🛡️ DÉDUPLICATION CORRIGÉE : Fenêtre de 60 secondes au lieu de 2 heures
                var uniqueSessions: [HistorySession] = []
                for session in rawSessions {
                    // Si on trouve une session avec ce même ami enregistrée à moins de 60 secondes d'intervalle
                    if let idx = uniqueSessions.firstIndex(where: { $0.friendID == session.friendID && abs($0.date.timeIntervalSince(session.date)) < HISTORY_DEDUPLICATION_WINDOW }) {
                        if session.duration > uniqueSessions[idx].duration {
                            uniqueSessions[idx] = session // On garde la plus longue des deux sauvegardes simultanées
                        }
                    } else {
                        uniqueSessions.append(session)
                    }
                }
                
                // On trie du plus récent au plus ancien localement
                uniqueSessions.sort(by: { $0.date > $1.date })
                completion(uniqueSessions)
        }
    }
    
    // --- Écoute les "Vrais Noms" (Surnoms) ---
    @discardableResult
    func listenToFriendsAttributes(completion: @escaping ([String: String]) -> Void) -> ListenerRegistration? {
        guard let uid = currentUserID else { return nil }

        return db.collection("users").document(uid).collection("friends")
            .addSnapshotListener { snapshot, error in
                guard let documents = snapshot?.documents else {
                    completion([:])
                    return
                }
                
                var namesMap: [String: String] = [:]
                for doc in documents {
                    let data = doc.data()
                    let friendID = doc.documentID
                    
                    if let custom = data["customName"] as? String, !custom.isEmpty {
                        namesMap[friendID] = custom
                    } else if let original = data["originalName"] as? String {
                        namesMap[friendID] = original
                    }
                }
                completion(namesMap)
            }
    }
    
    // --- SUPPRESSION VOLONTAIRE D'UNE SESSION ---
    func deleteHistorySession(id: String) {
        // En supprimant de la base partagée, ça la supprime pour les DEUX utilisateurs instantanément
        db.collection("shared_history").document(id).delete() { err in
            if let err = err {
                print("❌ Erreur lors de la suppression de la session: \(err)")
            } else {
                print("✅ Session partagée supprimée pour les deux utilisateurs !")
            }
        }
    }
    
    // --- GESTION DES SUPPRESSIONS BILATÉRALES (BOÎTE AUX LETTRES) ---
    func sendDeleteCommand(to targetStableID: String, from myStableID: String) {
        let data: [String: Any] = ["command": "delete", "timestamp": Timestamp(date: Date())]
        db.collection("mailboxes").document(targetStableID).collection("commands").document(myStableID).setData(data)
    }

    func listenForCommands(myStableID: String, onCommandReceived: @escaping (String, String) -> Void) {
        commandListener?.remove()
        commandListener = db.collection("mailboxes").document(myStableID).collection("commands").addSnapshotListener { snapshot, _ in
            guard let docs = snapshot?.documents else { return }
            for doc in docs {
                let senderID = doc.documentID
                if let command = doc.data()["command"] as? String {
                    onCommandReceived(senderID, command)
                    doc.reference.delete()
                }
            }
        }
    }

    func stopListeningForCommands() {
        commandListener?.remove()
        commandListener = nil
    }

    // --- CHARGEMENT DES AMIS DEPUIS FIREBASE (Source de vérité multi-appareils) ---
    func loadFriends(completion: @escaping ([SavedFriend]) -> Void) {
        guard let uid = currentUserID else { completion([]); return }
        db.collection("users").document(uid).collection("friends").getDocuments { snapshot, error in
            guard let documents = snapshot?.documents else { completion([]); return }
            let friends = documents.compactMap { doc -> SavedFriend? in
                let data = doc.data()
                let id = doc.documentID
                let originalName = data["originalName"] as? String ?? "Ami"
                let customName = data["customName"] as? String
                return SavedFriend(
                    id: id,
                    originalName: originalName,
                    customName: (customName?.isEmpty == true) ? nil : customName
                )
            }
            completion(friends)
        }
    }

    // --- SUPPRESSION D'UN AMI DE FIREBASE ---
    func deleteFriend(_ friendID: String) {
        guard let uid = currentUserID else { return }
        db.collection("users").document(uid).collection("friends").document(friendID).delete()
    }
    
    func checkAndCreateUserProfile(user: User?) {
        guard let user = user else { return }
        let db = Firestore.firestore()
        let userRef = db.collection("users").document(user.uid)
        
        userRef.getDocument { document, error in
            if let document = document, !document.exists {
                // Premier lancement : on crée le profil
                let data: [String: Any] = [
                    "uid": user.uid,
                    "email": user.email ?? "",
                    "displayName": user.displayName ?? "Utilisateur",
                    "stableID": String(user.uid.prefix(6)),
                    "createdAt": FieldValue.serverTimestamp()
                ]
                userRef.setData(data)
            }
        }
    }
}
