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

        // Listener pour réagir aux changements d'auth (expiration token, restauration iCloud, transfert)
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
            // Auth pas encore prête → mettre en file d'attente
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
                        
                        // On crée une HistorySession avec l'ID du document
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
    // Un doublon est un fragment de session archivé pendant la session en cours.
    // On le détecte en vérifiant : même friendID, date d'archivage récente (dans la fenêtre
    // de la session en cours), et durée inférieure à la durée actuelle (c'est un fragment).
    func checkAndDeleteDuplicateSession(friendID: String, presumedDuration: TimeInterval) {
        guard let uid = currentUserID else { return }

        // Borne inférieure : début estimé de la session en cours - marge de sécurité
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

                print("📚 Analyse de \(documents.count) fichiers potentiels...")

                for document in documents {
                    let data = document.data()

                    if let savedDuration = data["duration"] as? TimeInterval {
                        // Un fragment est forcément plus court que la session en cours
                        if savedDuration < presumedDuration {
                            print("   🗑️ Fragment détecté (durée: \(Int(savedDuration))s < \(Int(presumedDuration))s). Suppression...")

                            document.reference.delete { err in
                                if let err = err {
                                    print("   ❌ Erreur suppression : \(err)")
                                } else {
                                    print("   ✅ FLUSH : Fragment supprimé !")
                                }
                            }
                        } else {
                            print("   🛡️ Session valide (durée: \(Int(savedDuration))s >= \(Int(presumedDuration))s). On ne touche pas.")
                        }
                    }
                }
            }
    }
    
    // --- LECTURE DE L'HISTORIQUE (Temps Réel) ---
    func listenToHistory(completion: @escaping ([HistorySession]) -> Void) {
        guard let uid = currentUserID else { return }
        
        db.collection("users").document(uid).collection("history")
            .order(by: "date", descending: true) // Du plus récent au plus vieux
            .addSnapshotListener { snapshot, error in
                if let error = error {
                    print("❌ Erreur lecture historique : \(error.localizedDescription)")
                    return
                }
                
                guard let documents = snapshot?.documents else {
                    completion([])
                    return
                }
                
                // On transforme les documents JSON en objets Swift
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
    func listenToFriendsAttributes(completion: @escaping ([String: String]) -> Void) {
    guard let uid = currentUserID else { return }
    
    // On écoute la collection "friends" pour savoir comment tu as renommé tes amis
    db.collection("users").document(uid).collection("friends")
        .addSnapshotListener { snapshot, error in
            
            // En cas d'erreur ou si c'est vide, on ne fait rien
            guard let documents = snapshot?.documents else {
                completion([:])
                return
            }
            
            var namesMap: [String: String] = [:]
            
            for doc in documents {
                let data = doc.data()
                let friendID = doc.documentID // L'ID unique (ex: MAC001)
                
                // Priorité 1 : Le surnom que tu as donné (customName)
                if let custom = data["customName"] as? String, !custom.isEmpty {
                    namesMap[friendID] = custom
                }
                // Priorité 2 : Le nom d'origine (originalName)
                else if let original = data["originalName"] as? String {
                    namesMap[friendID] = original
                }
            }
            completion(namesMap) // On renvoie le dictionnaire : ["MAC001": "MacBook Vianney", ...]
        }
    }
}
