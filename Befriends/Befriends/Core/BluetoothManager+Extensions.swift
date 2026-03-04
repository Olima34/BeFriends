import Foundation
import CoreBluetooth

extension BluetoothManager: CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    
    // --- CENTRAL (Scanner & Client) ---
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        checkExpirations()
        if central.state == .poweredOn {
            let systemConnectedPeripherals = central.retrieveConnectedPeripherals(withServices: [BEFRIENDS_SERVICE_UUID])
            
            for peripheral in systemConnectedPeripherals {
                print("🔄 DÉMARRAGE : Récupération d'une connexion système fantôme (\(peripheral.identifier))")
                if !discoveredPeripherals.contains(peripheral) {
                    discoveredPeripherals.append(peripheral)
                }
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
            }
            restartScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionBlacklist[peripheral.identifier] = Date()
        restartScanning()
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                if !discoveredPeripherals.contains(peripheral) { discoveredPeripherals.append(peripheral) }
                peripheral.delegate = self
                if peripheral.state == .connected {
                    peripheral.discoverServices([BEFRIENDS_SERVICE_UUID])
                } else if peripheral.state != .connecting {
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
        checkExpirations()
        restartScanning()
        peripheral.discoverServices([BEFRIENDS_SERVICE_UUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnection(peripheral: peripheral)
        checkExpirations()
        if central.state == .poweredOn {
            if connectionBlacklist[peripheral.identifier] == nil {
                central.connect(peripheral, options: nil)
            }
            restartScanning()
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
                let identPayload = "\(BluetoothManager.shared.myStableID)|0"
                if let data = identPayload.data(using: .utf8) {
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                }
                peripheral.readValue(for: characteristic)
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

        let charIdentity = CBMutableCharacteristic(type: IDENTITY_CHARACTERISTIC_UUID, properties: [.read], value: nil, permissions: [.readable])
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
    
    // --- 🌟 LES NOUVELLES FONCTIONS DE SYNCHRONISATION MAGIQUE ---
    
    // RÉPONSE AUX LECTURES DIRECTES
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == IDENTITY_CHARACTERISTIC_UUID {
            request.value = myIdentityString.data(using: .utf8)
            peripheral.respond(to: request, withResult: .success)
            return
        }
        guard request.characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID else { return }
        
        let duration: TimeInterval
        if let friendID = centralToFriendID[request.central.identifier],
           let session = activeSessions.first(where: { $0.id == friendID }) {
            duration = session.duration
        } else {
            duration = -1
        }
        request.value = "\(Int(duration))".data(using: .utf8)
        peripheral.respond(to: request, withResult: .success)
    }

    // SYNC IMMÉDIAT QUAND UN CENTRAL S'ABONNE
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID, let char = timeSyncCharacteristic else { return }
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) { subscribedCentrals.append(central) }
        
        let duration: TimeInterval
        if let friendID = centralToFriendID[central.identifier],
           let session = activeSessions.first(where: { $0.id == friendID }) {
            duration = session.duration
        } else {
            duration = -1
        }
        if let data = "\(Int(duration))".data(using: .utf8) {
            peripheralManager.updateValue(data, for: char, onSubscribedCentrals: [central])
        }
    }
    
    // Nettoyage quand un central se désabonne
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll(where: { $0.identifier == central.identifier })
        centralToFriendID.removeValue(forKey: central.identifier)
    }

    // MISE À JOUR (LECTURE DU TEMPS DE L'AUTRE)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == IDENTITY_CHARACTERISTIC_UUID {
            if let identityString = String(data: data, encoding: .utf8) {
                let components = identityString.split(separator: "|")
                if components.count >= 2 {
                    handleIdentification(stableID: String(components[0]), name: String(components[1]), peripheral: peripheral)
                }
            }
        }
        
        if characteristic.uuid == TIME_SYNC_CHARACTERISTIC_UUID {
            if let timeString = String(data: data, encoding: .utf8), let remoteDuration = TimeInterval(timeString) {
                if let session = activeSessions.first(where: { $0.peripheral?.identifier == peripheral.identifier }) {
                    
                    // --- GESTION DE L'ACCEPTATION MUTUELLE ET DES SUPPRESSIONS ---
                    if remoteDuration == -1 {
                        if !BluetoothManager.shared.waitingForMutual.contains(session.id) {
                            if session.duration > 5 {
                                DispatchQueue.main.async { BluetoothManager.shared.processRemoteDeletion(friendID: session.id) }
                                return
                            } else {
                                DispatchQueue.main.async { BluetoothManager.shared.waitingForMutual.insert(session.id) }
                            }
                        }
                        
                        DispatchQueue.main.async {
                            if let idx = BluetoothManager.shared.activeSessions.firstIndex(where: { $0.id == session.id }) {
                                BluetoothManager.shared.activeSessions[idx].startTime = Date()
                            }
                        }
                        return
                    } else {
                        if BluetoothManager.shared.waitingForMutual.contains(session.id) {
                            DispatchQueue.main.async { BluetoothManager.shared.waitingForMutual.remove(session.id) }
                        }
                    }
                    
                    // --- LOGIQUE DE SYNCHRO NORMALE ---
                    if session.isConnected && remoteDuration > (session.duration + SYNC_THRESHOLD) {
                        FirebaseManager.shared.checkAndDeleteDuplicateSession(friendID: session.id, presumedDuration: remoteDuration)
                    }
                    
                    synchronizeSession(for: session.id, remoteDuration: remoteDuration)
                    
                    if remoteDuration > 0 && session.duration > (remoteDuration + FORCE_PUSH_THRESHOLD) {
                        let payloadString = "\(myStableID)|\(Int(session.duration))"
                        if let dataToWrite = payloadString.data(using: .utf8) {
                            peripheral.writeValue(dataToWrite, for: characteristic, type: .withResponse)
                        }
                    }
                }
            }
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
                        centralToFriendID[request.central.identifier] = senderID

                        if let index = self.activeSessions.firstIndex(where: { $0.id == senderID }) {
                            if !self.activeSessions[index].isConnected {
                                print("🤝 ASYMÉTRIE RÉSOLUE : L'ami \(senderID) nous parle, on le reconnecte !")
                                self.activeSessions[index].isConnected = true
                                self.restartScanning()
                            }
                            self.activeSessions[index].lastSeenTime = Date()
                            
                            let session = self.activeSessions[index]
                            print("📥 REÇU : Ordre de \(senderID) pour temps \(Int(newTime))s")

                            if session.isConnected && newTime > (session.duration + DUPLICATE_SEARCH_WINDOW) {
                                print("⚡️ OBÉISSANCE : Gros saut temporel détecté pour \(session.originalName)")
                                FirebaseManager.shared.checkAndDeleteDuplicateSession(friendID: senderID, presumedDuration: newTime)
                                self.synchronizeSession(for: senderID, remoteDuration: newTime)
                            }
                            else if session.isConnected && newTime > (session.duration + WRITE_ORDER_THRESHOLD) {
                                self.synchronizeSession(for: senderID, remoteDuration: newTime)
                            }
                        }
                        else if self.pendingRequests.contains(where: { $0.id == senderID }) {
                            // On ignore silencieusement
                        }
                        else if newTime > 0 {
                            print("⚠️ REJETÉ : Ordre ignoré, l'ID (\(senderID)) n'est pas un ami.")
                        }
                    }
                }
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }
}
