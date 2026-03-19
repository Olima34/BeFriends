import Foundation
import CoreBluetooth

// --- IDENTIFIANTS BLUETOOTH ---
let BEFRIENDS_SERVICE_UUID = CBUUID(string: "A495FF90-C5B1-4B44-B512-1370F02D74DE")
let IDENTITY_CHARACTERISTIC_UUID = CBUUID(string: "A495FF90-C5B1-4B44-B512-1370F02D74DF")
let TIME_SYNC_CHARACTERISTIC_UUID = CBUUID(string: "A495FF90-C5B1-4B44-B512-1370F02D74E0")

// --- RÉGLAGES DE TEMPS & DURÉE ---

// 1. GESTION DE LA CONNEXION & BLUETOOTH
let DISCONNECT_GRACE_PERIOD: TimeInterval = 900.0 // 15 minutes (900s)
let NOTIFICATION_COOLDOWN: TimeInterval = 14400.0 // 4 heures (14400s)
let BLACKLIST_DURATION: TimeInterval = 300.0 // 5 minutes
let BLE_CLEANUP_INTERVAL: TimeInterval = 30.0 // Fréquence de nettoyage des timers BLE
let BLE_BROADCAST_INTERVAL: TimeInterval = 5.0 // Fréquence de diffusion du temps (GATT)
let PENDING_REQUEST_EXPIRATION: TimeInterval = 1800.0 // 30 min max pour accepter une demande
let BLE_CONNECTING_TIMEOUT: TimeInterval = 300.0 // 5 min max en statut "connecting"
let BLE_DISCONNECTED_TIMEOUT: TimeInterval = 120.0 // 2 min max avant d'oublier un périphérique inactif
let MAX_PENDING_REQUESTS: Int = 20 // Limite max de la file d'attente des demandes
let LOCAL_SAVE_DEBOUNCE: TimeInterval = 5.0 // Délai anti-spam pour l'écriture sur le disque

// 2. SENSIBILITÉ DE LA SYNCHRONISATION (HANDSHAKE)
let SYNC_THRESHOLD: TimeInterval = 10.0 // Écart toléré avant de se synchroniser sur l'autre
let FORCE_PUSH_THRESHOLD: TimeInterval = 30.0 // Écart pour forcer l'autre à s'aligner
let WRITE_ORDER_THRESHOLD: TimeInterval = 5.0 // Tolérance minimale pour accepter un ordre distant
let FRESH_SESSION_THRESHOLD: TimeInterval = 10.0 // Durée max pour valider une "nouvelle" session
let MUTUAL_ACCEPT_CONFIRMATION_COUNT: Int = 3 // Nombre de broadcasts positifs requis pour valider l'acceptation
let REMOTE_DELETION_CONFIRMATION_COUNT: Int = 3 // Nombre de "-1" consécutifs pour confirmer une suppression
let INITIAL_NEGATIVE_GRACE_PERIOD: TimeInterval = 5.0 // Marge avant de considérer un "-1" comme une vraie suppression

// 3. SAUVEGARDE & NETTOYAGE CLOUD
let MIN_SESSION_SAVE_DURATION: TimeInterval = 15.0 // Durée minimale pour sauvegarder sur Firebase
let DUPLICATE_SEARCH_WINDOW: TimeInterval = 300.0 // 5 min pour chercher des fragments de sessions partagées
let HISTORY_DEDUPLICATION_WINDOW: TimeInterval = 60.0 // 60s pour fusionner les doubles sauvegardes simultanées
