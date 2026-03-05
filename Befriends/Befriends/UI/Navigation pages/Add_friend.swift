//
//  Add_friends.swift
//  Befriends
//
//  Created by Vianney Dubosc on 04/03/2026.
//

import SwiftUI

struct AddFriendView: View {
    @ObservedObject var manager: BluetoothManager
    
    var body: some View {
        List {
            // Pour l'instant, on y met les demandes en attente de ton ancien ScanView
            Section(header: Text("Demandes en attente")) {
                if manager.pendingRequests.isEmpty {
                    Text("Aucune demande.")
                        .foregroundColor(.gray)
                } else {
                    ForEach(manager.pendingRequests) { request in
                        HStack {
                            Text(request.originalName)
                            Spacer()
                            Button("Accepter") {
                                manager.acceptFriend(request)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                        }
                    }
                }
            }
            
            Section(header: Text("Autres utilisateurs à proximité")) {
                Text("Recherche en cours...")
                    .foregroundColor(.gray)
                    .italic()
            }
        }
        .navigationTitle("Ajouter un ami")
        .navigationBarTitleDisplayMode(.large)
    }
}
