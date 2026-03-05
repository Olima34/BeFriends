//
//  AuthManager.swift
//  Befriends
//
//  Created by Vianney Dubosc on 05/03/2026.
//

import Foundation
import FirebaseAuth
import GoogleSignIn
import FirebaseCore
import SwiftUI
import Combine

class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var isUserAuthenticated: Bool = false
    @Published var currentUser: User?
    
    init() {
        // Vérifie si un utilisateur est déjà connecté au lancement
        self.currentUser = Auth.auth().currentUser
        self.isUserAuthenticated = self.currentUser != nil
    }
    
    func signInWithGoogle(presentingViewController: UIViewController) {
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }
        
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController) { [weak self] result, error in
            if let error = error {
                print("Erreur de connexion Google: \(error.localizedDescription)")
                return
            }
            
            guard let user = result?.user, let idToken = user.idToken?.tokenString else { return }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                           accessToken: user.accessToken.tokenString)
            
            Auth.auth().signIn(with: credential) { authResult, error in
                if let error = error {
                    print("Erreur Auth Firebase: \(error.localizedDescription)")
                    return
                }
                
                DispatchQueue.main.async {
                    self?.currentUser = authResult?.user
                    self?.isUserAuthenticated = true

                    FirebaseManager.shared.checkAndCreateUserProfile(user: authResult?.user)

                    // Démarrer tous les services BLE avec la nouvelle identité
                    BluetoothManager.shared.startServices()
                }
            }
        }
    }
    
    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            DispatchQueue.main.async {
                self.isUserAuthenticated = false
                self.currentUser = nil
                
                // Arrêter tous les services BLE et nettoyer les données locales
                BluetoothManager.shared.stopServices()
            }
        } catch let error {
            print("Erreur de déconnexion: \(error.localizedDescription)")
        }
    }
}
