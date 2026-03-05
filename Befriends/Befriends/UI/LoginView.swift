//
//  LoginView.swift
//  Befriends
//
//  Created by Vianney Dubosc on 05/03/2026.
//

import SwiftUI
import GoogleSignInSwift

struct LoginView: View {
    var body: some View {
        VStack(spacing: 40) {
            Text("Bienvenue sur Befriends")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Connectez-vous pour retrouver vos amis et votre historique sur n'importe quel appareil.")
                .multilineTextAlignment(.center)
                .padding()
            
            // Bouton natif Google
            GoogleSignInButton(scheme: .dark, style: .wide, state: .normal) {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    AuthManager.shared.signInWithGoogle(presentingViewController: rootVC)
                }
            }
            .frame(width: 280, height: 50)
            .padding()
        }
    }
}
