import Foundation
import CoreBluetooth
import UIKit
import SwiftUI
import Combine
import UserNotifications

class BluetoothManager: NSObject, ObservableObject {
    static let shared = BluetoothManager()
    
    var centralManager: CBCentralManager!
    var peripheralManager: CBPeripheralManager!
    
    @Published var activeSessions: [ActiveSession] = []
    @Published var pendingRequests: [ActiveSession] = []
    @Published var savedFriends: [SavedFriend] = []
    
    var discoveredPeripherals: [CBPeripheral] = []
    var connectionBlacklist: [UUID: Date] = [:]
    var notificationCooldowns: [String: Date] = [:]
    
    var cleanupTimerSource: DispatchSourceTimer?
    var broadcastTimerSource: DispatchSourceTimer?
    var timeSyncCharacteristic: CBMutableCharacteristic?
    private var saveWorkItem: DispatchWorkItem?

    // Mapping CBCentral → friendID pour envoyer la bonne durée à chaque abonné
    var subscribedCentrals: [CBCentral] = []
    var centralToFriendID: [UUID: String] = [:]  // CBCentral.identifier → friendID
    
    var myStableID: String {
        let key = "MyBefriendsStableID"
        if let existingID = UserDefaults.standard.string(forKey: key) { return existingID }
        let newID = String(UUID().uuidString.prefix(6))
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }
    
    var myIdentityString: String {
        return "\(myStableID)|\(UIDevice.current.name)"
    }

    override init() {
        super.init()
        loadData()
        // Options de restauration pour le mode background
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "BefriendsCentralRestoreID"])
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil, options: [CBPeripheralManagerOptionRestoreIdentifierKey: "BefriendsPeripheralRestoreID"])
        
        // DispatchSourceTimer au lieu de Timer : fonctionne même quand le RunLoop principal
        // est suspendu en arrière-plan (les Timer s'arrêtent, GCD non).
        let cleanupSource = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        cleanupSource.schedule(deadline: .now() + 30, repeating: 30.0)
        cleanupSource.setEventHandler { [weak self] in DispatchQueue.main.async { self?.checkExpirations() } }
        cleanupSource.resume()
        cleanupTimerSource = cleanupSource

        let broadcastSource = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        broadcastSource.schedule(deadline: .now() + 5, repeating: 5.0)
        broadcastSource.setEventHandler { [weak self] in DispatchQueue.main.async { self?.updateBroadcastedTime() } }
        broadcastSource.resume()
        broadcastTimerSource = broadcastSource
    }
    
    // --- SYNC LOGIC ---
    func synchronizeSession(for friendID: String, remoteDuration: TimeInterval) {
        // Pas de DispatchQueue.main.async : les callbacks CoreBluetooth (queue: nil) sont
        // déjà sur le main thread. Le async redondant différait l'exécution et pouvait
        // être perdu si iOS suspendait l'app entre les deux.
        guard let index = activeSessions.firstIndex(where: { $0.id == friendID }) else { return }
        let myDuration = activeSessions[index].duration

        if remoteDuration > (myDuration + SYNC_THRESHOLD) {
            print("🔄 SYNC : L'autre est en avance. On s'aligne !")
            let newStartTime = Date().addingTimeInterval(-remoteDuration)

            let updatedSession = activeSessions[index]
            let newSession = ActiveSession(
                id: updatedSession.id,
                originalName: updatedSession.originalName,
                startTime: newStartTime,
                isConnected: true,
                lastSeenTime: Date(),
                peripheral: updatedSession.peripheral
            )
            activeSessions[index] = newSession
            scheduleSave()
            // Propager immédiatement notre temps mis à jour aux abonnés BLE
            updateBroadcastedTime()
        }
    }
    
    func updateBroadcastedTime() {
        guard peripheralManager.state == .poweredOn else { return }
        guard let char = timeSyncCharacteristic else { return }
        guard !activeSessions.isEmpty else { return }

        // Nettoyer les centrals qui n'ont plus de session active (déconnexion brutale)
        subscribedCentrals.removeAll { central in
            guard let friendID = centralToFriendID[central.identifier] else { return false }
            let shouldRemove = !activeSessions.contains(where: { $0.id == friendID && $0.isConnected })
            if shouldRemove {
                centralToFriendID.removeValue(forKey: central.identifier)
            }
            return shouldRemove
        }

        // Envoyer la durée spécifique à chaque central abonné
        for central in subscribedCentrals {
            guard let friendID = centralToFriendID[central.identifier],
                  let session = activeSessions.first(where: { $0.id == friendID }) else {
                // Pas de mapping → ne pas envoyer pour éviter la contamination
                continue
            }
            if let data = "\(Int(session.duration))".data(using: .utf8) {
                peripheralManager.updateValue(data, for: char, onSubscribedCentrals: [central])
            }
        }
    }
    
    // --- GESTION AMIS & NOTIFS ---
    func getDisplayName(for id: String, fallbackName: String) -> String {
        if let friend = savedFriends.first(where: { $0.id == id }) { return friend.displayName }
        return fallbackName
    }
    
    func updateFriendName(id: String, newName: String) {
        if let index = savedFriends.firstIndex(where: { $0.id == id }) {
            var friend = savedFriends[index]
            friend.customName = newName
            savedFriends[index] = friend
            saveData()
            objectWillChange.send()
            FirebaseManager.shared.saveFriend(friend)
        }
    }
    
    func sendProximityNotification(forName name: String, id: String) {
        if let lastNotifDate = notificationCooldowns[id] {
            if Date().timeIntervalSince(lastNotifDate) < NOTIFICATION_COOLDOWN { return }
        }
        let display = getDisplayName(for: id, fallbackName: name)
        let content = UNMutableNotificationContent()
        content.title = "Ami détecté ! 📍"
        content.body = "\(display) est à proximité."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        notificationCooldowns[id] = Date()
    }
    
    func sendNewDeviceNotification(forName name: String, id: String) {
        if let lastNotifDate = notificationCooldowns["new_\(id)"] {
            if Date().timeIntervalSince(lastNotifDate) < NOTIFICATION_COOLDOWN { return }
        }
        let content = UNMutableNotificationContent()
        content.title = "Nouvel appareil détecté 🔍"
        content.body = "\(name) veut se connecter. Ouvrir Befriends pour approuver."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        notificationCooldowns["new_\(id)"] = Date()
    }

    func acceptFriend(_ session: ActiveSession) {
        let newFriend = SavedFriend(id: session.id, originalName: session.originalName, customName: nil)
        if !savedFriends.contains(where: { $0.id == newFriend.id }) {
            savedFriends.append(newFriend)
            saveData()
            FirebaseManager.shared.saveFriend(newFriend)
        }
        if let index = pendingRequests.firstIndex(where: { $0.id == session.id }) { pendingRequests.remove(at: index) }
        
        if let peripheral = session.peripheral {
            connectionBlacklist.removeValue(forKey: peripheral.identifier)
            if centralManager.state == .poweredOn { centralManager.connect(peripheral, options: nil) }
        }
        
        if !activeSessions.contains(where: { $0.id == session.id }) {
            // Ne créer la session que si le peripheral est toujours connecté
            // pour éviter une session fantôme qui serait archivée avec une durée de 0s
            if session.peripheral?.state == .connected {
                var newSession = session
                newSession.isConnected = true
                newSession.lastSeenTime = Date()
                activeSessions.append(newSession)
            }
        }
    }
    
    // --- LOGIQUE DE FIN DE SESSION ---
    func checkExpirations() {
        let now = Date()
        // Nettoyage des entrées expirées dans la blacklist
        connectionBlacklist = connectionBlacklist.filter { now.timeIntervalSince($0.value) < BLACKLIST_DURATION }
        // Nettoyage des pending requests de plus de 30 minutes (non approuvées/refusées)
        pendingRequests.removeAll { now.timeIntervalSince($0.lastSeenTime) > 1800 }
        // Nettoyage des peripherals qui ne sont plus dans une session active
        let activePeripheralIDs = Set(activeSessions.compactMap { $0.peripheral?.identifier })
        let pendingPeripheralIDs = Set(pendingRequests.compactMap { $0.peripheral?.identifier })
        discoveredPeripherals.removeAll { peripheral in
            !activePeripheralIDs.contains(peripheral.identifier) &&
            !pendingPeripheralIDs.contains(peripheral.identifier) &&
            peripheral.state != .connected && peripheral.state != .connecting
        }
        for index in activeSessions.indices.reversed() {
            let session = activeSessions[index]
            if !session.isConnected {
                let timeInLimbo = now.timeIntervalSince(session.lastSeenTime)
                
                // UTILISATION DE LA CONSTANTE CONFIGURABLE
                if timeInLimbo > DISCONNECT_GRACE_PERIOD {
                    let realDuration = session.lastSeenTime.timeIntervalSince(session.startTime)
                    
                    // UTILISATION DE LA CONSTANTE CONFIGURABLE (Min Session)
                    if realDuration > MIN_SESSION_SAVE_DURATION {
                        print("🏁 Session terminée et archivée : \(session.originalName)")
                        
                        // CLOUD ☁️
                        let item = HistorySession(
                            id: UUID().uuidString,
                            friendID: session.id,
                            friendName: session.originalName,
                            duration: realDuration,
                            date: session.startTime
                        )
                        FirebaseManager.shared.saveHistoryItem(item)
                    }
                    
                    activeSessions.remove(at: index)
                    saveData()
                }
            }
        }
    }
    
    // --- GESTION BLUETOOTH CORE ---
    // Pas de DispatchQueue.main.async : les callbacks CoreBluetooth (queue: nil) sont
    // déjà sur le main thread. Exécution synchrone pour éviter toute race condition
    // sur activeSessions entre handleIdentification et checkExpirations.
    func handleIdentification(stableID: String, name: String, peripheral: CBPeripheral) {
        let now = Date()
        // NETTOYAGE PRÉVENTIF AU RÉVEIL
        // Si le Timer était endormi, on fait son travail ici avant de reconnecter !
        if let index = activeSessions.firstIndex(where: { $0.id == stableID }) {
            let session = activeSessions[index]
            if !session.isConnected {
                let timeInLimbo = now.timeIntervalSince(session.lastSeenTime)

                // Si la coupure a dépassé la limite autorisée
                if timeInLimbo > DISCONNECT_GRACE_PERIOD {
                    print("⏳ Réveil : La session de \(name) a expiré pendant le sommeil de l'app. Archivage immédiat !")
                    let realDuration = session.lastSeenTime.timeIntervalSince(session.startTime)

                    if realDuration > MIN_SESSION_SAVE_DURATION {
                        let item = HistorySession(
                            id: UUID().uuidString,
                            friendID: session.id,
                            friendName: session.originalName,
                            duration: realDuration,
                            date: session.startTime
                        )
                        FirebaseManager.shared.saveHistoryItem(item)
                    }
                    // On détruit la vieille session
                    activeSessions.remove(at: index)
                }
            }
        }
        if savedFriends.contains(where: { $0.id == stableID }) {
            sendProximityNotification(forName: name, id: stableID)
            if let index = activeSessions.firstIndex(where: { $0.id == stableID }) {
                // Déconnecter l'ancien peripheral si c'est un objet différent (rotation d'adresse BLE)
                if let oldPeripheral = activeSessions[index].peripheral,
                   oldPeripheral.identifier != peripheral.identifier {
                    centralManager.cancelPeripheralConnection(oldPeripheral)
                }
                activeSessions[index].isConnected = true
                activeSessions[index].lastSeenTime = now
                activeSessions[index].peripheral = peripheral
            } else {
                let newSession = ActiveSession(id: stableID, originalName: name, startTime: now, isConnected: true, lastSeenTime: now, peripheral: peripheral)
                activeSessions.append(newSession)
            }
            connectionBlacklist.removeValue(forKey: peripheral.identifier)
        } else {
            if !pendingRequests.contains(where: { $0.id == stableID }) {
                // Limiter les pending requests pour éviter l'accumulation en environnement dense
                if pendingRequests.count >= 20 {
                    pendingRequests.removeFirst()
                }
                let request = ActiveSession(id: stableID, originalName: name, startTime: now, isConnected: true, lastSeenTime: now, peripheral: peripheral)
                pendingRequests.append(request)
                sendNewDeviceNotification(forName: name, id: stableID)
            }
            centralManager.cancelPeripheralConnection(peripheral)
            connectionBlacklist[peripheral.identifier] = now
        }
    }
    
    func handleDisconnection(peripheral: CBPeripheral) {
        if let index = activeSessions.firstIndex(where: { $0.peripheral?.identifier == peripheral.identifier }) {
            activeSessions[index].isConnected = false
            activeSessions[index].lastSeenTime = Date()
        }
    }

    func saveData() {
        // Ne pas mettre à jour lastSeenTime ici : c'est handleDisconnection et
        // handleIdentification qui gèrent ce timestamp. Le mettre à jour à chaque
        // sauvegarde gonfle artificiellement la durée et relance le grace period.
        let encoder = JSONEncoder()
        if let encodedFriends = try? encoder.encode(savedFriends) { UserDefaults.standard.set(encodedFriends, forKey: "SavedFriends") }
        if let encodedActive = try? encoder.encode(activeSessions) { UserDefaults.standard.set(encodedActive, forKey: "ActiveSessions") }
    }

    /// Sauvegarde différée pour éviter les écritures disque répétées (debounce 5s)
    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveData() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }
    
    func loadData() {
        let decoder = JSONDecoder()
        if let dataFriends = UserDefaults.standard.data(forKey: "SavedFriends"),
           let decoded = try? decoder.decode([SavedFriend].self, from: dataFriends) {
            savedFriends = decoded
        }
        
        if let dataActive = UserDefaults.standard.data(forKey: "ActiveSessions"),
           let decodedSessions = try? decoder.decode([ActiveSession].self, from: dataActive) {
            
            var validSessions: [ActiveSession] = []
            let now = Date()
            
            print("📂 Restauration : Analyse de \(decodedSessions.count) sessions...")
            
            for var session in decodedSessions {
                let timeSinceDeath = now.timeIntervalSince(session.lastSeenTime)
                
                // IMPORTANT : On la marque comme déconnectée pour figer sa durée
                session.isConnected = false
                
                // CAS 1 : Session récente (moins de 15 min de coupure) -> On reprend
                // On ne réinitialise PAS lastSeenTime : conserver l'horodatage réel évite
                // de gonfler la durée et de réinitialiser le grace period à chaque redémarrage.
                if timeSinceDeath <= DISCONNECT_GRACE_PERIOD {
                    validSessions.append(session)
                }
                // CAS 2 : Session trop vieille (La nuit est passée) -> ON ARCHIVE !
                else {
                    print("💀 Session expirée retrouvée (\(session.originalName)). Archivage...")
                    
                    // On vérifie qu'elle a duré assez longtemps pour être intéressante
                    if session.duration > MIN_SESSION_SAVE_DURATION {
                        let item = HistorySession(
                            id: UUID().uuidString,
                            friendID: session.id,
                            friendName: session.originalName,
                            duration: session.duration, // Durée correcte grâce au fix n°1
                            date: session.startTime
                        )
                        FirebaseManager.shared.saveHistoryItem(item)
                    }
                }
            }
            self.activeSessions = validSessions
        }
    }
}
