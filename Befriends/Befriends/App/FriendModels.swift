//
//  FriendModels.swift
//  Befriends
//
//  Created by Vianney Dubosc on 06/02/2026.
//

import Foundation
import CoreBluetooth

// Représente un ami sauvegardé (pour le renommage)
struct SavedFriend: Codable, Identifiable {
    let id: String
    let originalName: String
    var customName: String?
    var displayName: String { return customName ?? originalName }
}

// Représente une session active (en cours, temps réel)
struct ActiveSession: Identifiable, Codable {
    let id: String
    let originalName: String
    var startTime: Date
    var isConnected: Bool = true
    var lastSeenTime: Date = Date()
    
    var peripheral: CBPeripheral? = nil // Exclu du Codable
    
    // CORRECTION : Si déconnecté, on fige la durée sur la dernière vue
    var duration: TimeInterval {
        if isConnected {
            return max(0, Date().timeIntervalSince(startTime))
        } else {
            return max(0, lastSeenTime.timeIntervalSince(startTime))
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, originalName, startTime, isConnected, lastSeenTime
    }
}

// Représente une session archivée (Historique Firebase)
struct HistorySession: Identifiable, Codable {
    var id: String      // ID du document Firebase
    var friendID: String // ID de l'ami (ex: MAC001)
    var friendName: String
    var duration: TimeInterval
    var date: Date

    private static let sharedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter
    }()

    // Formatteur pour la durée (ex: "34m 38s")
    var durationFormatted: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        else if minutes > 0 { return "\(minutes)m \(seconds)s" }
        else { return "\(seconds)s" }
    }

    // Formatteur pour la date (ex: "11/02/2026, 17:14")
    var dateFormatted: String {
        return Self.sharedDateFormatter.string(from: date)
    }
}
