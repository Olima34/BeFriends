//
//  Profil.swift
//  Befriends
//
//  Created by Vianney Dubosc on 04/03/2026.
//

import SwiftUI

struct ProfilView: View {
    var body: some View {
        VStack {
            Text("Page des Hangout")
                .foregroundColor(.gray)
            Button(action: {
                AuthManager.shared.signOut()
            }) {
                Text("Se déconnecter")
                    .foregroundColor(.red)
                    .fontWeight(.bold)
            }
        }
        .navigationTitle("Mes Hangout")
        .navigationBarTitleDisplayMode(.large)
    }
}
