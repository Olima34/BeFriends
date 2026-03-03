import Foundation
import CoreBluetooth

// --- IDENTIFIANTS BLUETOOTH ---
let BEFRIENDS_SERVICE_UUID = CBUUID(string: "A495FF90-C5B1-4B44-B512-1370F02D74DE")
let IDENTITY_CHARACTERISTIC_UUID = CBUUID(string: "A495FF90-C5B1-4B44-B512-1370F02D74DF")
let TIME_SYNC_CHARACTERISTIC_UUID = CBUUID(string: "A495FF90-C5B1-4B44-B512-1370F02D74E0")

// --- RÉGLAGES DE TEMPS & DURÉE ---

// 1. GESTION DE LA CONNEXION
// Temps avant de considérer qu'un ami est parti (Mode "Grace Period")
// 15 minutes (900s) = Idéal pour éviter les coupures WC / Cuisine
let DISCONNECT_GRACE_PERIOD: TimeInterval = 10.0

// Temps avant de pouvoir recevoir une nouvelle notif "Ami détecté" (4 heures)
let NOTIFICATION_COOLDOWN: TimeInterval = 14400.0

// Temps avant de pouvoir se reconnecter à un appareil qu'on vient d'ignorer
let BLACKLIST_DURATION: TimeInterval = 300.0

// 2. SENSIBILITÉ DE LA SYNCHRONISATION
// Si l'écart entre les deux téléphones dépasse ce seuil, on se met à jour.
let SYNC_THRESHOLD: TimeInterval = 10.0

// Si NOUS sommes en avance de plus de X secondes, on FORCE l'autre à se mettre à jour.
// On met un peu plus que le seuil de base pour éviter les boucles infinies (Ping-Pong).
let FORCE_PUSH_THRESHOLD: TimeInterval = 30.0

// Si on reçoit un ORDRE d'écriture, on accepte si la correction est significative (> 5s)
let WRITE_ORDER_THRESHOLD: TimeInterval = 5.0

// 3. SAUVEGARDE & NETTOYAGE
// Durée minimale d'une session pour qu'elle mérite d'être sauvegardée dans l'historique (30s)
let MIN_SESSION_SAVE_DURATION: TimeInterval = 30.0

// Fenêtre de temps pour chercher des doublons dans le passé (5 minutes)
// "Supprime tout ce qui a commencé 5 min avant le début théorique de la session"
let DUPLICATE_SEARCH_WINDOW: TimeInterval = 300.0
