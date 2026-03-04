import SwiftUI

// On définit les 4 onglets possibles
enum AppTab {
    case home, hangout, friends, profile
}

struct ContentView: View {
    @StateObject var manager = BluetoothManager.shared
    
    // Cet état mémorise quel onglet est actuellement sélectionné
    @State private var selectedTab: AppTab = .home
    
    var body: some View {
        TabView(selection: $selectedTab) {
            
            // --- ONGLET 1 : ACCUEIL ---
            // On passe $selectedTab à HomeView pour qu'elle puisse changer d'onglet
            HomeView(manager: manager, selectedTab: $selectedTab)
                .tabItem { Label("Accueil", systemImage: "house.fill") }
                .tag(AppTab.home)
            
            // --- ONGLET 2 : HANGOUT ---
            HangoutView() // Remplace par le nom de ton fichier Hangout si c'est différent
                .tabItem { Label("Hangout", systemImage: "figure.2.arms.open") }
                .tag(AppTab.hangout)
            
            // --- ONGLET 3 : AMIS ---
            FriendsView() // Ta page Friends
                .tabItem { Label("Amis", systemImage: "person.2.fill") }
                .tag(AppTab.friends)
            
            // --- ONGLET 4 : PROFIL ---
            Text("Page Profil en construction 🛠️")
                .tabItem { Label("Profil", systemImage: "person.crop.circle.fill") }
                .tag(AppTab.profile)
        }
        .accentColor(.purple)
        .preferredColorScheme(.dark)
    }
}
