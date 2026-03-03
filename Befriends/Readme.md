# Befriends — Proximity Time Tracker

**Version :** 1.2 | **Plateforme :** iOS 15.0+ | **Langage :** Swift / SwiftUI
**Technologies :** CoreBluetooth, Firebase Auth (anonyme), Firebase Firestore

---

## Vue d'ensemble

Befriends mesure automatiquement le temps passé à proximité de vos amis via **Bluetooth Low Energy (BLE)**. Dès qu'un appareil "Befriends" connu est détecté à portée, un chronomètre démarre. La session est archivée dans le Cloud à la fin.

L'application est conçue pour être **résiliente** : elle survit aux mises en veille d'iOS, répare les incohérences de temps entre appareils, et évite les doublons dans l'historique.

---

## Structure du projet

```
Befriends/
├── App/
│   ├── BefriendsApp.swift       # Point d'entrée, gestion des transitions avant-plan/arrière-plan
│   ├── AppDelegate.swift        # Init Firebase, permissions notifications, sauvegarde d'urgence
│   └── FriendModels.swift       # Modèles de données (SavedFriend, ActiveSession, HistorySession)
├── Core/
│   ├── AppConfig.swift          # Toutes les constantes de configuration (UUIDs, délais)
│   ├── BluetoothManager.swift   # Logique BLE centrale + gestion des sessions
│   └── BluetoothManager+Extensions.swift  # Implémentations des delegates CoreBluetooth
├── UI/
│   ├── ContentView.swift        # TabView racine (2 onglets)
│   ├── ScanView.swift           # Onglet "Radar" : amis à proximité, demandes en attente
│   └── HistoryView.swift        # Onglet "Journal" : historique groupé par ami
MacBeacon/
└── main.swift                   # Script Mac autonome pour simuler un ami BLE
```

---

## Modèles de données

### `SavedFriend`
Un ami approuvé, stocké localement et dans Firebase.
- `id` : Identifiant stable court (6 caractères, ex : `A1B2C3`)
- `originalName` : Nom diffusé par l'appareil (`UIDevice.current.name`)
- `customName` : Surnom personnalisé optionnel
- `displayName` : Retourne `customName` s'il existe, sinon `originalName`

### `ActiveSession`
Une session en cours (en RAM + UserDefaults).
- `id` : ID de l'ami (même que `SavedFriend.id`)
- `startTime` : Heure de début de la session courante
- `isConnected` : `true` si l'ami est actuellement à portée BLE
- `lastSeenTime` : Dernière fois que le signal a été reçu
- `peripheral` : Référence BLE (exclu du Codable, non persisté)
- `duration` (calculé) : Si connecté → `now - startTime`. Si déconnecté → `lastSeenTime - startTime` (durée figée)

### `HistorySession`
Une session archivée dans Firebase Firestore.
- `id` : ID du document Firestore
- `friendID` : ID stable de l'ami
- `friendName` : Nom au moment de l'archivage
- `duration` : Durée en secondes
- `date` : Date/heure d'archivage

---

## Protocole Bluetooth

Tous les appareils Befriends exposent **un service BLE** avec **deux caractéristiques** :

| Élément | UUID | Rôle |
|---|---|---|
| Service | `A495FF90-...74DE` | Identifiant du réseau Befriends |
| Caractéristique Identité | `A495FF90-...74DF` | Read-only. Valeur : `"STABLEID\|Nom de l'appareil"` |
| Caractéristique Temps | `A495FF90-...74E0` | Read / Notify / Write. Valeur : durée de session en secondes (`"142"`) |

L'**identité stable** de chaque appareil est un préfixe de 6 caractères d'un UUID généré une seule fois et stocké dans `UserDefaults` (clé `MyBefriendsStableID`).

---

## Cycle de vie d'une session

### 1. Découverte
Le `CBCentralManager` scanne en permanence les périphériques exposant le service Befriends. À la découverte d'un périphérique :
- Si l'appareil est dans la **blacklist** (refus récent < 5 min) → ignoré
- Sinon → connexion BLE, puis découverte des services et caractéristiques

### 2. Identification (`handleIdentification`)
À la lecture de la caractéristique Identité :

- **Ami connu** (`savedFriends` contient cet ID) :
  - Vérification préventive : si la session existante est déconnectée depuis plus de 15 min → archivage immédiat de l'ancienne session
  - Reprise ou création d'une `ActiveSession`
  - Notification de proximité envoyée (avec cooldown de 4h)

- **Inconnu** :
  - Ajout dans `pendingRequests`
  - Notification "Nouvel appareil détecté"
  - Déconnexion + ajout à la blacklist pendant 5 min
  - L'utilisateur doit approuver manuellement via l'UI

### 3. Synchronisation du temps
Toutes les **5 secondes**, chaque appareil diffuse sa durée de session via `notify` sur la caractéristique Temps.

À la réception d'une durée distante :

| Situation | Action |
|---|---|
| Distant > Local + **10s** (`SYNC_THRESHOLD`) | Ajustement de `startTime` en local pour s'aligner sur la durée distante |
| Local > Distant + **30s** (`FORCE_PUSH_THRESHOLD`) | Envoi d'un ordre d'écriture (`write`) pour forcer la mise à jour de l'autre |
| Réception d'un ordre d'écriture > Local + **5s** (`WRITE_ORDER_THRESHOLD`) | Acceptation de la correction |
| Réception d'un ordre avec un saut > **5 min** (`DUPLICATE_SEARCH_WINDOW`) | Nettoyage anti-doublons Firebase déclenché |

### 4. Déconnexion et Grace Period
À la perte du signal BLE :
- `isConnected = false`, `lastSeenTime` mis à jour
- La durée de la session est **figée** (plus incrémentée)
- Un timer (`checkExpirations`) tourne toutes les **30 secondes**

Si la déconnexion dure plus de **15 minutes** (`DISCONNECT_GRACE_PERIOD`) :
- Si `duration > 30s` (`MIN_SESSION_SAVE_DURATION`) → archivage dans Firebase
- Suppression de l'`ActiveSession`

Si l'ami revient dans les 15 minutes : la session reprend sans interruption.

### 5. Survie en arrière-plan
- **Passage en arrière-plan** (`scenePhase == .background`) → `saveData()` sauvegarde les sessions actives dans `UserDefaults`
- **Retour au premier plan** (`scenePhase == .active`) → `checkExpirations()` est appelé immédiatement (le timer peut avoir dormi)
- **Kill de l'app** (`applicationWillTerminate`) → `saveData()` + notification système alertant l'utilisateur
- **Restauration CoreBluetooth** (`willRestoreState`) → reconnexion aux périphériques déjà connus par le système

Au prochain lancement, `loadData()` analyse chaque session sauvegardée :
- Session de moins de 15 min de coupure → **reprise**
- Session plus vieille → **archivage** dans Firebase + suppression

---

## Nettoyage des doublons Firebase

Quand un grand saut temporel est détecté (ex : micro-déconnexion ayant créé un fragment dans Firebase), `checkAndDeleteDuplicateSession` est appelé :

1. Calcul du début théorique de la session (`now - remoteDuration`)
2. Définition d'une zone sûre : `débutThéorique - 5 min`
3. Interrogation Firebase : les 10 dernières sessions pour cet ami
4. Suppression de tout document dont le début calculé est **après** la zone sûre (fragments récents)
5. Arrêt à la première session valide (antérieure à la zone sûre)

---

## Structure Firebase Firestore

```
users/
  {uid_anonyme}/
    history/
      {auto_id}/
        friendID   : String   // ID stable de l'ami
        friendName : String   // Nom au moment de l'archivage
        duration   : Number   // Durée en secondes
        date       : Timestamp
        id         : String   // UUID local (redondant avec l'ID du document)
    friends/
      {friendID}/
        id           : String
        originalName : String
        customName   : String  // Vide si pas de surnom
```

---

## Interface utilisateur

### Onglet Radar (`ScanView`)
- Section **"Nouvelles détections"** : appareils inconnus en attente d'approbation, avec bouton "Ajouter"
- Section **"Amis à proximité"** : sessions actives avec chronomètre en temps réel (refresh chaque seconde via `TimelineView`), indicateur vert/orange (connecté/grace period), et bouton de renommage

### Onglet Journal (`HistoryView`)
- Thème sombre
- Sessions groupées par ami (par ID stable, pas par nom), triées par date de la session la plus récente
- Durée totale par ami affichée en violet
- Cartes dépliables/repliables avec le détail de chaque session (date + durée)
- Les surnoms sont chargés en temps réel depuis Firebase via `listenToFriendsAttributes`

---

## Configuration (`AppConfig.swift`)

Tous les paramètres de comportement sont centralisés ici :

| Constante | Valeur | Description |
|---|---|---|
| `DISCONNECT_GRACE_PERIOD` | 900s (15 min) | Délai avant archivage après perte de signal |
| `MIN_SESSION_SAVE_DURATION` | 30s | Durée minimale pour qu'une session soit sauvegardée |
| `NOTIFICATION_COOLDOWN` | 14 400s (4h) | Anti-spam des notifications de proximité |
| `BLACKLIST_DURATION` | 300s (5 min) | Délai avant de réessayer un appareil refusé |
| `SYNC_THRESHOLD` | 10s | Écart déclenchant une synchronisation locale |
| `FORCE_PUSH_THRESHOLD` | 30s | Écart déclenchant un ordre d'écriture vers l'autre |
| `WRITE_ORDER_THRESHOLD` | 5s | Écart minimum pour accepter un ordre reçu |
| `DUPLICATE_SEARCH_WINDOW` | 300s (5 min) | Fenêtre de recherche des fragments à supprimer |

---

## MacBeacon (outil de test)

`MacBeacon/main.swift` est un script Swift autonome qui transforme un Mac en "ami simulé". Il expose le même service BLE que l'app iPhone.

**Comportement :**
- ID fixe : `MAC001` | Nom fixe : `MacBook de Test`
- La session démarre uniquement quand l'iPhone se connecte (subscribe ou lecture)
- Un timer d'inactivité vérifie toutes les **60 secondes** : si aucune interaction depuis **15 min** → arrêt et remise à zéro du chronomètre
- Si l'iPhone lui envoie une durée plus grande (+2s) → mise à jour locale

**Lancement :**
```bash
cd MacBeacon
swift main.swift
```

---

## Installation

### Prérequis
- Xcode 15+
- Un projet Firebase avec **Authentication anonyme** et **Firestore** activés
- Appareil physique iOS (le simulateur ne supporte pas le Bluetooth)

### Étapes
1. Cloner le projet
2. Ajouter votre fichier `GoogleService-Info.plist` dans le dossier `Befriends/`
3. Compiler et lancer sur un appareil physique
4. Accepter les permissions Bluetooth et Notifications au premier lancement

---

## Vie privée

- Authentification **anonyme** via Firebase Auth — aucun email ni mot de passe requis
- Le nom diffusé en BLE est `UIDevice.current.name` (nom de l'iPhone dans les Réglages)
- Toutes les données sont isolées par UID anonyme Firebase
