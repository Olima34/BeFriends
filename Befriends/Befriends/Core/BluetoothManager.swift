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
    @Published var waitingForMutual: Set<String> = []
    
    var discoveredPeripherals: [CBPeripheral] = []
    var connectionBlacklist: [UUID: Date] = [:]
    var notificationCooldowns: [String: Date] = [:]

    // FIX #1 : Compteur de -1 consécutifs par ami.
    // Exige 3 confirmations avant de déclencher processRemoteDeletion,
    // pour absorber un -1 résiduel dû à la race subscribe/write.
    var consecutiveNegativeOnes: [String: Int] = [:]
    
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
        
        // DispatchSourceTimer au lieu de Timer : fonctionne en arrière-plan actif.
        // En suspension (après ~30s sans activité BLE), tous les timers sont gelés par iOS.
        // Le nettoyage est alors assuré par checkExpirations() dans les callbacks BLE et au retour foreground.
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
        
        // Écoute des suppressions distantes
         FirebaseManager.shared.listenForCommands(myStableID: myStableID) { [weak self] senderID, command in
             if command == "delete" {
                 DispatchQueue.main.async {
                     self?.processRemoteDeletion(friendID: senderID)
                 }
             }
         }
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
        if let index = pendingRequests.firstIndex(where: { $0.id == session.id }) {
            pendingRequests.remove(at: index)
        }
        
        // 🌟 NOUVEAU : On le met PROACTIVEMENT en attente mutuelle.
        // Ça gèle le chrono à 00:00 et affiche "En attente d'acceptation" sur son profil.
        waitingForMutual.insert(session.id)
        
        if let peripheral = session.peripheral {
            connectionBlacklist.removeValue(forKey: peripheral.identifier)
            if centralManager.state == .poweredOn { centralManager.connect(peripheral, options: nil) }
        }
        
        if let index = activeSessions.firstIndex(where: { $0.id == session.id }) {
            // S'il était déjà dans les sessions actives par erreur, on reset tout à maintenant
            activeSessions[index].startTime = Date()
            // FIX #3 : Ne pas marquer connecté tant que la connexion n'est pas réellement établie.
            // handleIdentification passera isConnected = true après identification réussie.
            activeSessions[index].isConnected = false
            activeSessions[index].lastSeenTime = Date()
        } else {
            // FIX #3 : isConnected = false — on attend la vraie connexion BLE.
            // handleIdentification mettra isConnected = true quand la connexion sera établie.
            let newSession = ActiveSession(
                id: session.id,
                originalName: session.originalName,
                startTime: Date(),
                isConnected: false,
                lastSeenTime: Date(),
                peripheral: session.peripheral
            )
            activeSessions.append(newSession)
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
        // FIX #5 : Annuler les connexions pendantes périmées (rotation d'adresse BLE).
        // CoreBluetooth ne time-out jamais une connexion .connecting, donc après une
        // rotation d'adresse le peripheral reste en .connecting indéfiniment.
        for session in activeSessions where !session.isConnected {
            if let peripheral = session.peripheral {
                let timeSinceLastSeen = now.timeIntervalSince(session.lastSeenTime)
                if peripheral.state == .connecting && timeSinceLastSeen > 300 {
                    // 5 min en .connecting sans succès → probablement rotation d'adresse
                    centralManager.cancelPeripheralConnection(peripheral)
                } else if peripheral.state != .connected && peripheral.state != .connecting && timeSinceLastSeen > 120 {
                    centralManager.cancelPeripheralConnection(peripheral)
                }
            }
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
    
    /// Relance le scan BLE. Appeler systématiquement au retour au premier plan
    /// et dans les callbacks BLE pour contrer l'arrêt silencieux du scan par iOS.
    /// Le stopScan() avant scanForPeripherals force CoreBluetooth à réinitialiser
    /// son filtre de doublons, permettant de redécouvrir un peripheral déjà signalé.
    func restartScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()

        let isBackground = UIApplication.shared.applicationState != .active
        let options: [String: Any] = isBackground
            ? [:]
            : [CBCentralManagerScanOptionAllowDuplicatesKey: true]

        centralManager.scanForPeripherals(
            withServices: [BEFRIENDS_SERVICE_UUID],
            options: options
        )
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
        // FIX #2 : Persister waitingForMutual pour éviter les suppressions après redémarrage
        UserDefaults.standard.set(Array(waitingForMutual), forKey: "WaitingForMutual")
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
        // FIX #2 : Restaurer waitingForMutual depuis le disque
        if let waiting = UserDefaults.standard.stringArray(forKey: "WaitingForMutual") {
            waitingForMutual = Set(waiting)
        }
    }
    
    func removeFriend(id: String) {
        // 1. On prévient le Cloud pour qu'il soit supprimé sur l'autre téléphone
        FirebaseManager.shared.sendDeleteCommand(to: id, from: myStableID)

        // 2. On archive la session en cours avant de tout détruire
        if let index = activeSessions.firstIndex(where: { $0.id == id }) {
            let session = activeSessions[index]

            let realDuration = Date().timeIntervalSince(session.startTime)
            if realDuration > MIN_SESSION_SAVE_DURATION && !waitingForMutual.contains(id) {
                let item = HistorySession(id: UUID().uuidString, friendID: session.id, friendName: session.originalName, duration: realDuration, date: session.startTime)
                FirebaseManager.shared.saveHistoryItem(item)
            }

            if let peripheral = session.peripheral {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            
            // L'ASTUCE EST ICI : On le bascule DIRECTEMENT dans les demandes en attente
            if !pendingRequests.contains(where: { $0.id == id }) {
                var pendingSession = session
                // FIX #8 : isConnected = false — il n'est peut-être plus à portée.
                // Évite un affichage trompeur pendant 30min dans ScanView.
                pendingSession.isConnected = false
                pendingSession.startTime = Date()
                pendingSession.lastSeenTime = Date()
                pendingRequests.append(pendingSession)
            }

            activeSessions.remove(at: index)
        }

        // 3. On nettoie tout
        savedFriends.removeAll { $0.id == id }
        waitingForMutual.remove(id)
        saveData()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.restartScanning()
        }
    }
    
    func processRemoteDeletion(friendID: String) {
         guard savedFriends.contains(where: { $0.id == friendID }) else { return }
         print("💔 Rupture : \(friendID) nous a supprimé ! Archivage et suppression locale...")

         // 1. Sauvegarder la session en cours si elle existe
         if let index = activeSessions.firstIndex(where: { $0.id == friendID }) {
             let session = activeSessions[index]
             
             let realDuration = Date().timeIntervalSince(session.startTime)
             if realDuration > MIN_SESSION_SAVE_DURATION && !waitingForMutual.contains(friendID) {
                 let item = HistorySession(id: UUID().uuidString, friendID: session.id, friendName: session.originalName, duration: realDuration, date: session.startTime)
                 FirebaseManager.shared.saveHistoryItem(item)
             }
             
             if let peripheral = session.peripheral {
                 centralManager.cancelPeripheralConnection(peripheral)
             }
             
             // L'ASTUCE ICI AUSSI : S'il est à côté de nous quand il nous supprime,
             // on le voit réapparaître instantanément dans nos demandes !
             if !pendingRequests.contains(where: { $0.id == friendID }) {
                 var pendingSession = session
                 // FIX #8 : isConnected = false — il n'est peut-être plus à portée
                 pendingSession.isConnected = false
                 pendingSession.startTime = Date()
                 pendingSession.lastSeenTime = Date()
                 pendingRequests.append(pendingSession)
             }
             
             activeSessions.remove(at: index)
         }

         // 2. Supprimer l'ami de notre téléphone
         savedFriends.removeAll { $0.id == friendID }
         waitingForMutual.remove(friendID)
         saveData()
         restartScanning()
     }
}
