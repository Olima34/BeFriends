//
//  BefriendsApp.swift
//  Befriends
//
//  Created by Vianney Dubosc on 04/02/2026.
//

import SwiftUI
import UIKit // Nécessaire pour les Background Tasks
import GoogleSignIn

@main
struct BefriendsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    @StateObject var authManager = AuthManager.shared
    
    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isUserAuthenticated {
                    ContentView()
                        .onChange(of: scenePhase) { _, newPhase in
                            if newPhase == .background {
                                print("💾 L'app passe en arrière-plan...")
                                BluetoothManager.shared.saveData()
                                BluetoothManager.shared.checkExpirations()
                                var taskId: UIBackgroundTaskIdentifier = .invalid
                                taskId = UIApplication.shared.beginBackgroundTask {
                                    print("⚠️ Background task expirée par iOS")
                                    UIApplication.shared.endBackgroundTask(taskId)
                                    taskId = .invalid
                                }
                                DispatchQueue.global(qos: .utility).async {
                                    // On laisse un petit délai pour que les requêtes réseau partent
                                    Thread.sleep(forTimeInterval: 2.0)
                                    print("✅ Fin des tâches de fond.")
                                    UIApplication.shared.endBackgroundTask(taskId)
                                    taskId = .invalid
                                }
                            }
                            else if newPhase == .active {
                                print("☀️ L'app revient au premier plan : Vérification des expirations...")
                                BluetoothManager.shared.checkExpirations()
                                BluetoothManager.shared.restartScanning()
                            }
                        }
                } else {
                    // 👇 AJOUTEZ CECI POUR AFFICHER L'ÉCRAN DE CONNEXION
                    LoginView()
                }
            }
            .onOpenURL { url in
                GIDSignIn.sharedInstance.handle(url)
            }
        }
    }
}
