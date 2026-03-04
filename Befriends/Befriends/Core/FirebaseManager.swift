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

    init() {
        // Lecture cache immédiate si l'utilisateur est déjà connu
        if let user = Auth.auth().currentUser {
            self.currentUserID = user.uid
            print("🔥 Firebase Init : Utilisateur déjà connu (\(user.uid))")
        } else {
            signInAnonymously()
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
                    print("🔥 Auth perdue : re-connexion anonyme...")
                    self?.currentUserID = nil
                    self?.signInAnonymously()
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

    func signInAnonymously() {
        Auth.auth().signInAnonymously { result, error in
            if let error = error {
                print("🔥 Erreur Auth: \(error.localizedDescription)")
                return
            }
            if let user = result?.user {
                DispatchQueue.main.async {
                    self.currentUserID = user.uid
                }
                print("🔥 Connecté à Firebase avec ID: \(user.uid)")
            }
        }
    }
    
    // --- SAUVEGARDE DE L'HISTORIQUE ---
    func saveHistoryItem(_ item: HistorySession) {
        guard let uid = currentUserID ?? Auth.auth().currentUser?.uid else {
            print("⏳ Auth non prête : session mise en file d'attente pour envoi ultérieur")
            pendingHistoryItems.append(item)
            return
        }
        
        print("☁️ ENVOI FIREBASE : Archivage de \(item.friendName) (\(Int(item.duration))s)...")
        
        let data: [String: Any] = [
            "friendID": item.friendID,
            "friendName": item.friendName,
            "duration": item.duration,
            "date": item.date,
            "id": item.id
        ]
        
        db.collection("users").document(uid).collection("history").addDocument(data: data) { error in
            if let error = error {
                print("🔥 Erreur sauvegarde historique: \(error)")
            } else {
                print("✅ Session archivée dans le Cloud avec succès !")
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
    
    // --- CHARGEMENT ---
    func fetchHistory(completion: @escaping ([HistorySession]) -> Void) {
        guard let uid = currentUserID else { return }
        
        db.collection("users").document(uid).collection("history")
            .order(by: "date", descending: true)
            .getDocuments { snapshot, error in
                guard let documents = snapshot?.documents else {
                    completion([])
                    return
                }
                
                var sessions: [HistorySession] = []
                for doc in documents {
                    let data = doc.data()
                    if let fID = data["friendID"] as? String,
                       let fName = data["friendName"] as? String,
                       let dur = data["duration"] as? TimeInterval,
                       let stamp = data["date"] as? Timestamp {
                        
                        let session = HistorySession(
                            id: doc.documentID,
                            friendID: fID,
                            friendName: fName,
                            duration: dur,
                            date: stamp.dateValue()
                        )
                        sessions.append(session)
                    }
                }
                completion(sessions)
            }
    }
    
    // --- GESTION DES DOUBLONS ---
    func checkAndDeleteDuplicateSession(friendID: String, presumedDuration: TimeInterval) {
        guard let uid = currentUserID else { return }

        let presumedStartTime = Date().addingTimeInterval(-presumedDuration)
        let safeThresholdDate = presumedStartTime.addingTimeInterval(-DUPLICATE_SEARCH_WINDOW)

        print("🚜 Nettoyage : On cherche les fragments archivés après \(safeThresholdDate)...")

        db.collection("users").document(uid).collection("history")
            .whereField("friendID", isEqualTo: friendID)
            .whereField("date", isGreaterThan: Timestamp(date: safeThresholdDate))
            .order(by: "date", descending: true)
            .limit(to: 10)
            .getDocuments { snapshot, error in

                if let error = error {
                    print("❌ Erreur Firebase : \(error.localizedDescription)")
                    return
                }

                guard let documents = snapshot?.documents, !documents.isEmpty else { return }

                for document in documents {
                    let data = document.data()
                    if let savedDuration = data["duration"] as? TimeInterval {
                        if savedDuration < presumedDuration {
                            print("   🗑️ Fragment détecté (durée: \(Int(savedDuration))s < \(Int(presumedDuration))s). Suppression...")
                            document.reference.delete { err in
                                if let err = err { print("   ❌ Erreur suppression : \(err)") }
                                else { print("   ✅ FLUSH : Fragment supprimé !") }
                            }
                        }
                    }
                }
            }
    }
    
    // --- LECTURE DE L'HISTORIQUE (Temps Réel) ---
    @discardableResult
    func listenToHistory(completion: @escaping ([HistorySession]) -> Void) -> ListenerRegistration? {
        guard let uid = currentUserID else { return nil }

        return db.collection("users").document(uid).collection("history")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error = error {
                    print("❌ Erreur lecture historique : \(error.localizedDescription)")
                    return
                }
                
                guard let documents = snapshot?.documents else {
                    completion([])
                    return
                }
                
                let sessions = documents.compactMap { doc -> HistorySession? in
                    let data = doc.data()
                    guard let friendID = data["friendID"] as? String,
                          let friendName = data["friendName"] as? String,
                          let duration = data["duration"] as? TimeInterval,
                          let timestamp = data["date"] as? Timestamp else { return nil }
                    
                    return HistorySession(
                        id: doc.documentID,
                        friendID: friendID,
                        friendName: friendName,
                        duration: duration,
                        date: timestamp.dateValue()
                    )
                }
                completion(sessions)
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
    
    func deleteHistorySession(id: String) {
        guard let uid = currentUserID else { return }
        db.collection("users").document(uid).collection("history").document(id).delete() { err in
            if let err = err {
                print("❌ Erreur lors de la suppression de la session: \(err)")
            } else {
                print("✅ Session \(id) supprimée avec succès de Firebase !")
            }
        }
    }
    
    // --- GESTION DES SUPPRESSIONS BILATÉRALES (BOÎTE AUX LETTRES) ---
    func sendDeleteCommand(to targetStableID: String, from myStableID: String) {
        let data: [String: Any] = ["command": "delete", "timestamp": Timestamp(date: Date())]
        db.collection("mailboxes").document(targetStableID).collection("commands").document(myStableID).setData(data)
    }

    func listenForCommands(myStableID: String, onCommandReceived: @escaping (String, String) -> Void) {
        db.collection("mailboxes").document(myStableID).collection("commands").addSnapshotListener { snapshot, _ in
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
}
