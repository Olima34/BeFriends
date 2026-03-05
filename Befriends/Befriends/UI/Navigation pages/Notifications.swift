//
//  Notifications.swift
//  Befriends
//
//  Created by Vianney Dubosc on 04/03/2026.
//

import SwiftUI

struct NotificationsView: View {
    var body: some View {
        VStack {
            Image(systemName: "bell.slash")
                .font(.system(size: 50))
                .foregroundColor(.gray)
                .padding()
            Text("Vous n'avez aucune notification.")
                .foregroundColor(.gray)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
    }
}
