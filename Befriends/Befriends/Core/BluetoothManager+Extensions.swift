import Foundation
import CoreBluetooth

extension BluetoothManager: CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    
    // --- CENTRAL (Scanner & Client) ---
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Nettoyage préventif : cet événement arrive après une restauration d'état ou
        // un redémarrage du stack BT — le timer peut avoir manqué des expirations.
        checkExpirations()
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [BEFRIENDS_SERVICE_UUID], options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Retenter la connexion automatiquement en cas d'échec transitoire.
        if central.state == .poweredOn {
            central.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                if !discoveredPeripherals.contains(peripheral) { discoveredPeripherals.append(peripheral) }
                peripheral.delegate = self
                if peripheral.state == .connected {
                    // Ne pas conditionner à central.state == .poweredOn : la connexion est
                    // maintenue par le système BT, discoverServices fonctionne indépendamment.
                    peripheral.discoverServices([BEFRIENDS_SERVICE_UUID])
                } else if peripheral.state != .connecting {
                    // Périphérique restauré mais déconnecté → retenter la connexion.
                    // CoreBluetooth la mettra en file et l'exécutera dès que le stack est prêt.
                    central.connect(peripheral, options: nil)
                }
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let blacklistDate = connectionBlacklist[peripheral.identifier] {
            if Date().timeIntervalSince(blacklistDate) < BLACKLIST_DURATION { return }
            else { connectionBlacklist.removeValue(forKey: peripheral.identifier) }
        }
        if !discoveredPeripherals.contains(peripheral) { discoveredPeripherals.append(peripheral) }
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BEFRIENDS_SERVICE_UUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnection(peripheral: peripheral)
        // Profiter du réveil BLE pour vérifier les expirations (le timer peut être endormi).
        checkExpirations()
        if central.state == .poweredOn {
            // Retenter la connexion immédiatement si l'appareil n'est pas blacklisté.
            // Cela accélère la reconnexion quand l'ami est encore à portée.
            if connectionBlacklist[peripheral.identifier] == nil {
                central.connect(peripheral, options: nil)
            }
            central.scanForPeripherals(withServices: [BEFRIENDS_SERVICE_UUID], options: nil)
        }
    }
    
    // --- PERIPHERAL DELEGATE ---
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([IDENTITY_CHARACTERISTIC_UUID, TIME_SYNC_CHARACTERISTIC_UUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == IDENTITY_CHARACTERISTIC_UUID {
                peripheral.readValue(for: characteristic)
            }
            if characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID {
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        // 1. Identité
        if characteristic.uuid == IDENTITY_CHARACTERISTIC_UUID {
            if let identityString = String(data: data, encoding: .utf8) {
                let components = identityString.split(separator: "|")
                if components.count >= 2 {
                    handleIdentification(stableID: String(components[0]), name: String(components[1]), peripheral: peripheral)
                }
            }
        }
        
        // 2. Temps (Sync)
        if characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID {
            if let timeString = String(data: data, encoding: .utf8), let remoteDuration = TimeInterval(timeString) {
                if let session = activeSessions.first(where: { $0.peripheral?.identifier == peripheral.identifier }) {
                    
                    // --- UTILISATION DES CONSTANTES CONFIGURABLES ---
                    
                    // DÉTECTION DU SAUT TEMPOREL (ex: +10s)
                    if session.isConnected && remoteDuration > (session.duration + SYNC_THRESHOLD) {
                        print("📈 LECTURE : L'autre appareil est loin devant (+\(Int(remoteDuration - session.duration))s). Vérification doublons...")
                        FirebaseManager.shared.checkAndDeleteDuplicateSession(friendID: session.id, presumedDuration: remoteDuration)
                    }
                    
                    // A. Mise à jour locale (Sync de base)
                    synchronizeSession(for: session.id, remoteDuration: remoteDuration)
                    
                    // B. FORCE PUSH (Si NOUS sommes loin devant) (ex: +30s)
                    if session.duration > (remoteDuration + FORCE_PUSH_THRESHOLD) {
                        let payloadString = "\(myStableID)|\(Int(session.duration))"
                        if let dataToWrite = payloadString.data(using: .utf8) {
                            peripheral.writeValue(dataToWrite, for: characteristic, type: .withResponse)
                        }
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        peripheral.discoverServices([BEFRIENDS_SERVICE_UUID])
    }
    
    // --- PERIPHERAL MANAGER ---
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            setupPeripheralService()
            startAdvertising()
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        // Réhydrater timeSyncCharacteristic depuis l'état restauré.
        // Sans ça, updateBroadcastedTime() retourne immédiatement (guard let char = nil)
        // jusqu'à ce que setupPeripheralService() soit rappelé.
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services {
                if let chars = service.characteristics as? [CBMutableCharacteristic] {
                    for char in chars where char.uuid == TIME_SYNC_CHARACTERISTIC_UUID {
                        timeSyncCharacteristic = char
                    }
                }
            }
        }
    }
    
    func setupPeripheralService() {
        peripheralManager.removeAllServices()
        
        guard let dataIdentity = myIdentityString.data(using: .utf8) else { return }
        let charIdentity = CBMutableCharacteristic(type: IDENTITY_CHARACTERISTIC_UUID, properties: [.read], value: dataIdentity, permissions: [.readable])
        let charTime = CBMutableCharacteristic(
            type: TIME_SYNC_CHARACTERISTIC_UUID,
            properties: [.read, .notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        
        self.timeSyncCharacteristic = charTime
        let service = CBMutableService(type: BEFRIENDS_SERVICE_UUID, primary: true)
        service.characteristics = [charIdentity, charTime]
        peripheralManager.add(service)
    }
    
    func startAdvertising() {
        if peripheralManager.isAdvertising { return }
        let advertisingData: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [BEFRIENDS_SERVICE_UUID]]
        peripheralManager.startAdvertising(advertisingData)
    }
    
    // RÉPONSE AUX LECTURES DIRECTES (TIME_SYNC a value: nil → lecture dynamique obligatoire)
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID else { return }
        let maxDuration = activeSessions.max(by: { $0.duration < $1.duration })?.duration ?? 0
        request.value = "\(Int(maxDuration))".data(using: .utf8)
        peripheral.respond(to: request, withResult: .success)
    }

    // SYNC IMMÉDIAT QUAND UN CENTRAL S'ABONNE AUX NOTIFICATIONS
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID,
              let char = timeSyncCharacteristic else { return }
        let maxDuration = activeSessions.max(by: { $0.duration < $1.duration })?.duration ?? 0
        if let data = "\(Int(maxDuration))".data(using: .utf8) {
            peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
        }
    }

    // GESTION DES ORDRES D'ÉCRITURE REÇUS
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID {
                if let data = request.value, let payload = String(data: data, encoding: .utf8) {
                    
                    let components = payload.split(separator: "|")
                    
                    if components.count == 2,
                       let newTime = TimeInterval(components[1]) {
                        
                        let senderID = String(components[0])
                        print("📥 REÇU : Ordre de \(senderID) pour temps \(Int(newTime))s")
                        
                        DispatchQueue.main.async {
                            if let index = self.activeSessions.firstIndex(where: { $0.id == senderID }) {
                                let session = self.activeSessions[index]
                                
                                // UTILISATION DE WRITE_ORDER_THRESHOLD (ex: 5s)
                                
                                // CAS A : Gros saut (Utilisation de DUPLICATE_SEARCH_WINDOW pour la détection "gros saut" ou juste un seuil arbitraire plus grand)
                                // Ici on garde le 300s (5min) pour le "Gros saut" de nettoyage, car c'est une sécurité importante.
                                if session.isConnected && newTime > (session.duration + DUPLICATE_SEARCH_WINDOW) {
                                    print("⚡️ OBÉISSANCE : Gros saut temporel détecté pour \(session.originalName)")
                                    
                                    FirebaseManager.shared.checkAndDeleteDuplicateSession(friendID: senderID, presumedDuration: newTime)
                                    self.synchronizeSession(for: senderID, remoteDuration: newTime)
                                }
                                // CAS B : Correction standard (> 5s)
                                else if session.isConnected && newTime > (session.duration + WRITE_ORDER_THRESHOLD) {
                                    self.synchronizeSession(for: senderID, remoteDuration: newTime)
                                }
                            } else {
                                print("⚠️ REJETÉ : ID inconnu (\(senderID))")
                            }
                        }
                    }
                }
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }
}
