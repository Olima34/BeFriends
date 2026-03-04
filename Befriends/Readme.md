# Befriends — Proximity Time Tracker

**Plateforme :** iOS 17.0+ | **Langage :** Swift / SwiftUI
**Technologies :** CoreBluetooth, Firebase Auth (anonyme), Firebase Firestore

---

## Vue d'ensemble

Befriends mesure automatiquement le temps passé à proximité de vos amis via **Bluetooth Low Energy (BLE)**. Dès qu'un appareil Befriends connu est détecté à portée, un chronomètre démarre. La session est archivée dans le Cloud à la fin.

L'application est conçue pour être **résiliente** : elle survit aux mises en veille d'iOS, répare les incohérences de temps entre appareils, et évite les doublons dans l'historique.

---

## Structure du projet

```
Befriends/
├── App/
│   ├── BefriendsApp.swift       # Point d'entrée, gestion avant-plan/arrière-plan
│   ├── AppDelegate.swift        # Init Firebase, permissions notifications, sauvegarde d'urgence
│   └── FriendModels.swift       # Modèles de données (SavedFriend, ActiveSession, HistorySession)
├── Core/
│   ├── AppConfig.swift          # Constantes de configuration (UUIDs BLE, délais, seuils)
│   ├── BluetoothManager.swift   # Logique BLE centrale, sessions, sync, persistance, restartScanning
│   ├── BluetoothManager+Extensions.swift  # Delegates CoreBluetooth (Central, Peripheral, PeripheralManager)
│   └── FirebaseManager.swift    # Auth anonyme, CRUD Firestore, écoute temps réel, nettoyage doublons
├── UI/
│   ├── ContentView.swift        # TabView racine (2 onglets : Radar + Journal)
│   ├── ScanView.swift           # Onglet "Radar" : amis à proximité, demandes en attente
│   └── HistoryView.swift        # Onglet "Journal" : historique groupé par ami
├── GoogleService-Info.plist     # Configuration Firebase (non versionné)
└── Info.plist                   # Permissions Bluetooth (NSBluetoothAlwaysUsageDescription)
Tests/
├── BefriendsTests/
└── BefriendsUITests/
```

---

## Modèles de données

### `SavedFriend`
Un ami approuvé, stocké localement (UserDefaults) et dans Firebase.
- `id` : Identifiant stable court (6 caractères, préfixe UUID)
- `originalName` : Nom diffusé par l'appareil (`UIDevice.current.name`)
- `customName` : Surnom personnalisé optionnel
- `displayName` : Retourne `customName` s'il existe, sinon `originalName`

### `ActiveSession`
Une session en cours (en RAM + persistée dans UserDefaults).
- `id` : ID de l'ami (même que `SavedFriend.id`)
- `startTime` : Heure de début de la session
- `isConnected` : `true` si l'ami est actuellement à portée BLE
- `lastSeenTime` : Dernière réception de signal
- `peripheral` : Référence `CBPeripheral` (exclu du Codable, non persisté)
- `duration` (calculé) : Si connecté → `now - startTime`. Si déconnecté → `lastSeenTime - startTime` (durée figée)

### `HistorySession`
Une session archivée dans Firebase Firestore.
- `id` : ID du document Firestore
- `friendID` : ID stable de l'ami
- `friendName` : Nom au moment de l'archivage
- `duration` : Durée en secondes
- `date` : Date de début de la session

---

## Protocole Bluetooth

Chaque appareil Befriends agit simultanément comme **Central** (scanner) et **Peripheral** (serveur). Un seul service BLE est exposé avec deux caractéristiques :

| Elément | UUID | Rôle |
|---|---|---|
| Service | `A495FF90-...-74DE` | Identifiant du réseau Befriends |
| Identité | `A495FF90-...-74DF` | Read-only. Valeur : `"STABLEID\|NomAppareil"` |
| Temps | `A495FF90-...-74E0` | Read / Notify / Write. Durée de session en secondes |

L'**identité stable** est un préfixe de 6 caractères d'un UUID généré une seule fois et stocké dans `UserDefaults` (clé `MyBefriendsStableID`).

La caractéristique Identité utilise `value: nil` pour que CoreBluetooth appelle `didReceiveRead` à chaque lecture (pas de cache), permettant de refléter un changement de nom en temps réel.

### Mapping Central-to-Friend

Chaque appareil maintient un dictionnaire `centralToFriendID` qui associe l'identifiant d'un `CBCentral` à l'ID ami correspondant. Ce mapping permet d'envoyer la bonne durée à chaque abonné lors des broadcasts `notify`, évitant la "contamination" (envoyer la durée d'un ami A à un ami B).

Le mapping est établi quand un Central envoie un `write` contenant `"STABLEID|durée"` sur la caractéristique Temps. Il est nettoyé au désabonnement (`didUnsubscribeFrom`) et lors du nettoyage périodique dans `updateBroadcastedTime`.

---

## Cycle de vie d'une session

### 1. Découverte
Le `CBCentralManager` scanne en permanence les périphériques exposant le service Befriends via `restartScanning()`. Cette méthode est appelée systématiquement :
- Au retour au premier plan (`scenePhase == .active`)
- Dans chaque callback BLE significatif (`centralManagerDidUpdateState`, `didConnect`, `didDisconnect`, `didFailToConnect`)

Le `stopScan()` précédant chaque `scanForPeripherals()` force CoreBluetooth à réinitialiser son filtre de doublons, permettant de redécouvrir un peripheral déjà signalé (notamment après une rotation d'adresse BLE).

En **foreground**, le scan active `CBCentralManagerScanOptionAllowDuplicatesKey: true` pour recevoir les signaux répétés d'un même peripheral (couche de sécurité si une connexion pendante échoue silencieusement). En **background**, iOS force le dédoublonnage indépendamment de ce flag.

A la découverte :
- Si l'appareil est dans la **blacklist** (refus récent < 5 min) → ignoré
- Sinon → connexion BLE, découverte des services, lecture de l'identité

### 2. Identification (`handleIdentification`)
A la lecture de la caractéristique Identité :

- **Ami connu** (`savedFriends` contient cet ID) :
  - Vérification préventive : si une session existante est déconnectée depuis plus de 15 min → archivage immédiat de l'ancienne
  - Si un ancien `CBPeripheral` différent était associé (rotation d'adresse BLE) → déconnexion propre de l'ancien
  - Reprise ou création d'une `ActiveSession`
  - Notification de proximité (cooldown de 4h)

- **Inconnu** :
  - Ajout dans `pendingRequests` (max 20 entrées)
  - Notification "Nouvel appareil détecté"
  - Déconnexion + blacklist pendant 5 min
  - L'utilisateur approuve manuellement via l'UI

### 3. Synchronisation du temps
Toutes les **5 secondes**, chaque appareil diffuse sa durée de session via `notify` sur la caractéristique Temps (broadcast ciblé par abonné).

A la réception d'une durée distante :

| Situation | Action |
|---|---|
| Distant > Local + **10s** (`SYNC_THRESHOLD`) | Ajustement de `startTime` pour s'aligner |
| Local > Distant + **30s** (`FORCE_PUSH_THRESHOLD`) | Envoi d'un `write` pour forcer la mise à jour de l'autre |
| Réception d'un `write` > Local + **5s** (`WRITE_ORDER_THRESHOLD`) | Acceptation de la correction |
| Réception d'un `write` avec saut > **5 min** (`DUPLICATE_SEARCH_WINDOW`) | Nettoyage anti-doublons Firebase |

A la connexion initiale, le Central envoie immédiatement un `write` d'identification (`"STABLEID|0"`) pour établir le mapping avant le premier broadcast.

### 4. Déconnexion et Grace Period
A la perte du signal BLE :
- `isConnected = false`, `lastSeenTime` mis à jour
- La durée est **figée** (plus incrémentée)
- Reconnexion pendante immédiate via `central.connect(peripheral)` (si non blacklisté)
- `restartScanning()` relancé pour découvrir d'éventuels nouveaux peripherals
- Le timer `checkExpirations` tourne toutes les **30 secondes** (via `DispatchSourceTimer`)

`checkExpirations` est aussi appelé dans les callbacks BLE (`didConnect`, `didDisconnect`, `centralManagerDidUpdateState`) et au retour foreground, garantissant un nettoyage même si le timer est gelé en suspension iOS.

**Nettoyage des connexions pendantes périmées** : après **2 minutes** sans nouvelles d'une session déconnectée, `checkExpirations` annule la connexion pendante via `cancelPeripheralConnection`. Cela libère des ressources CoreBluetooth et permet au scan de découvrir le nouveau peripheral si l'adresse BLE a changé (rotation ~15 min par iOS pour la vie privée).

Si la déconnexion dure plus de **15 minutes** (`DISCONNECT_GRACE_PERIOD`) :
- Si `duration > 30s` (`MIN_SESSION_SAVE_DURATION`) → archivage dans Firebase
- Suppression de l'`ActiveSession`

Si l'ami revient dans les 15 minutes : la session reprend sans interruption.

### 5. Survie en arrière-plan
- **Passage en arrière-plan** (`scenePhase == .background`) :
  - `saveData()` persiste les sessions dans UserDefaults
  - `checkExpirations()` est appelé immédiatement
  - Une `beginBackgroundTask` est démarrée avec un handler d'expiration qui termine proprement la tâche
- **Retour au premier plan** (`scenePhase == .active`) :
  - `checkExpirations()` immédiat
  - `restartScanning()` relance le scan BLE avec `allowDuplicates: true` — iOS peut avoir silencieusement arrêté le scan pendant la suspension
- **Kill de l'app** (`applicationWillTerminate`) → `saveData()` + notification système alertant l'utilisateur
- **Restauration CoreBluetooth** (`willRestoreState`) → reconnexion aux périphériques connus, réhydratation de `timeSyncCharacteristic`

Au prochain lancement, `loadData()` analyse chaque session sauvegardée :
- Coupure < 15 min → **reprise** (session marquée déconnectée, durée figée)
- Coupure >= 15 min → **archivage** Firebase + suppression

Les timers utilisent `DispatchSourceTimer` (GCD) au lieu de `Timer` (RunLoop). En arrière-plan actif, les timers GCD fonctionnent. En **suspension** (après ~30s sans activité BLE), tous les timers sont gelés par iOS. Le nettoyage est alors assuré par les appels à `checkExpirations()` dans les callbacks BLE et au retour au premier plan.

---

## Nettoyage des doublons Firebase

Quand un grand saut temporel est détecté (micro-déconnexion ayant créé un fragment dans Firebase), `checkAndDeleteDuplicateSession` est appelé :

1. Calcul du début théorique de la session (`now - remoteDuration`)
2. Zone de recherche : `débutThéorique - 5 min` (`DUPLICATE_SEARCH_WINDOW`)
3. Requête Firebase : les 10 dernières sessions pour cet ami après cette date
4. Suppression de tout document dont la durée est **inférieure** à la durée présumée (fragments)
5. Les sessions de durée supérieure ou égale sont préservées

---

## Structure Firebase Firestore

```
users/
  {uid_anonyme}/
    history/
      {auto_id}/
        friendID   : String      // ID stable de l'ami
        friendName : String      // Nom au moment de l'archivage
        duration   : Number      // Durée en secondes
        date       : Timestamp   // Date de début de la session
        id         : String      // UUID local
    friends/
      {friendID}/
        id           : String
        originalName : String
        customName   : String    // Vide si pas de surnom
```

### Listeners temps réel

`HistoryView` utilise deux listeners Firestore (`addSnapshotListener`) pour la mise à jour en temps réel :
- `listenToHistory` : écoute la collection `history` (sessions archivées)
- `listenToFriendsAttributes` : écoute la collection `friends` (surnoms)

Les deux fonctions retournent un `ListenerRegistration` stocké dans le `HistoryViewModel`. Les listeners sont retirés dans `deinit` et avant chaque nouvel appel à `fetchAllData`, évitant l'accumulation de listeners lors de la navigation entre onglets.

L'authentification est surveillée via un `Combine` pipeline (`$currentUserID.compactMap.first()`) : les données ne sont chargées qu'une fois l'UID Firebase disponible. Un mécanisme de file d'attente (`pendingHistoryItems`) garantit qu'aucune session n'est perdue si l'auth n'est pas encore prête.

---

## Interface utilisateur

### Onglet Radar (`ScanView`)
- Section **"Nouvelles détections"** : appareils inconnus en attente d'approbation, avec bouton "Ajouter"
- Section **"Amis à proximité"** : sessions actives avec chronomètre en temps réel (refresh chaque seconde via `TimelineView`), indicateur vert (connecté) / orange (grace period), et bouton de renommage

### Onglet Journal (`HistoryView`)
- Thème sombre
- Sessions groupées par ami (par ID stable, pas par nom), triées par date de la session la plus récente
- Durée totale par ami affichée en violet
- Cartes dépliables/repliables avec le détail de chaque session (date + durée)
- Les surnoms sont chargés en temps réel depuis Firebase

---

## Configuration (`AppConfig.swift`)

Tous les paramètres de comportement sont centralisés :

| Constante | Valeur | Description |
|---|---|---|
| `DISCONNECT_GRACE_PERIOD` | 900s (15 min) | Délai avant archivage après perte de signal |
| `MIN_SESSION_SAVE_DURATION` | 30s | Durée minimale pour sauvegarder une session |
| `NOTIFICATION_COOLDOWN` | 14 400s (4h) | Anti-spam des notifications de proximité |
| `BLACKLIST_DURATION` | 300s (5 min) | Délai avant de réessayer un appareil refusé |
| `SYNC_THRESHOLD` | 10s | Ecart déclenchant une synchronisation locale |
| `FORCE_PUSH_THRESHOLD` | 30s | Ecart déclenchant un ordre d'écriture vers l'autre |
| `WRITE_ORDER_THRESHOLD` | 5s | Ecart minimum pour accepter un ordre reçu |
| `DUPLICATE_SEARCH_WINDOW` | 300s (5 min) | Fenêtre de recherche des fragments Firebase |

---

## Installation

### Prérequis
- Xcode 16+
- Un projet Firebase avec **Authentication anonyme** et **Firestore** activés
- Appareil physique iOS (le simulateur ne supporte pas le Bluetooth)

### Etapes
1. Cloner le projet
2. Ajouter votre fichier `GoogleService-Info.plist` dans le dossier `Befriends/`
3. Compiler et lancer sur un appareil physique
4. Accepter les permissions Bluetooth et Notifications au premier lancement

---

## Vie privée

- Authentification **anonyme** via Firebase Auth — aucun email ni mot de passe requis
- Le nom diffusé en BLE est `UIDevice.current.name` (nom de l'iPhone dans les Réglages)
- Toutes les données sont isolées par UID anonyme Firebase
- Aucune donnée de localisation n'est collectée
