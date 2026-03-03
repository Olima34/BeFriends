import SwiftUI

struct ContentView: View {
    @StateObject var manager = BluetoothManager.shared
    
    var body: some View {
        TabView {
            // --- ONGLET 1 : RADAR (A besoin du Bluetooth) ---
            ScanView(manager: manager)
                .tabItem {
                    Label("Radar", systemImage: "dot.radiowaves.left.and.right")
                }
            
            // --- ONGLET 2 : HISTORIQUE (Autonome via Firebase) ---
            HistoryView()
                .tabItem {
                    Label("Journal", systemImage: "clock.arrow.circlepath")
                }
        }
        .accentColor(.purple)
    }
}
