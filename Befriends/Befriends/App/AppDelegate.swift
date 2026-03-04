//
//  AppDelegate.swift
//  Befriends
//
//  Created by Vianney Dubosc on 06/02/2026.
//

import UIKit
import UserNotifications
import FirebaseCore

class AppDelegate: NSObject, UIApplicationDelegate {
        
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // 1. Configurer Firebase
        FirebaseApp.configure()
        _ = FirebaseManager.shared
        print("🔥 Firebase configuré !")
        
        // 2. Notifications (Code existant)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted { print("🔔 Permission notifications : ACCORDÉE") }
            else { print("🔕 Permission notifications : REFUSÉE") }
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        print("💀 L'utilisateur a tué l'app (Swipe Up) !")
        BluetoothManager.shared.saveData()
        
        let content = UNMutableNotificationContent()
        content.title = "Befriends est désactivé ⚠️"
        content.body = "L'historique ne fonctionne plus. Touche ici pour relancer l'app en arrière-plan."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "AppKilledAlert", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
