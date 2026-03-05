import SwiftUI

// Filtres de temps
enum TimeFilter: String, CaseIterable {
    case total = "Total"
    case month = "Ce mois"
    case week = "Cette semaine"
}

// Structure de base pour les Amis
struct FriendStats {
    let id: String
    let totalDuration: TimeInterval
    let lastSeen: Date
}

// Structure MOCK (Fausses données) pour visualiser les Hangouts
struct HangoutMock: Identifiable {
    let id = UUID()
    let title: String
    let date: Date
    let participantCount: Int
}

struct HomeView: View {
    @ObservedObject var manager: BluetoothManager
    // FIX #7 : Reçu depuis ContentView (plus de @StateObject local)
    @ObservedObject var historyVM: HistoryViewModel

    @Binding var selectedTab: AppTab
    @State private var selectedFilter: TimeFilter = .total
    
    // J'ai ajouté un 3ème Hangout avec un titre très long pour tester les "..."
    let upcomingHangouts: [HangoutMock] = [
        HangoutMock(title: "Soirée Barbecue", date: Date().addingTimeInterval(86400), participantCount: 8),
        HangoutMock(title: "Session Code/Révisions", date: Date().addingTimeInterval(259200), participantCount: 3),
        HangoutMock(title: "Anniversaire surprise de Thomas au restaurant", date: Date().addingTimeInterval(500000), participantCount: 12)
    ]
    
    // --- LOGIQUE DE FILTRAGE ---
    private func isSession(_ session: HistorySession, in filter: TimeFilter) -> Bool {
        let calendar = Calendar.current
        switch filter {
        case .total: return true
        case .month: return calendar.isDate(session.date, equalTo: Date(), toGranularity: .month)
        case .week: return calendar.isDate(session.date, equalTo: Date(), toGranularity: .weekOfYear)
        }
    }
    
    private var filteredTotalAppTime: TimeInterval {
        var total: TimeInterval = 0
        for sessions in historyVM.groupedSessions.values {
            let filtered = sessions.filter { isSession($0, in: selectedFilter) }
            total += filtered.reduce(0) { $0 + $1.duration }
        }
        return total
    }
    
    private var topFriends: [FriendStats] {
        var stats: [FriendStats] = []
        for (id, sessions) in historyVM.groupedSessions {
            
            // 🌟 LE CORRECTIF EST LÀ : Si la personne n'est plus dans nos amis, on l'ignore !
            guard manager.savedFriends.contains(where: { $0.id == id }) else { continue }
            
            let filteredSessions = sessions.filter { isSession($0, in: selectedFilter) }
            guard !filteredSessions.isEmpty else { continue }
            
            let totalDuration = filteredSessions.reduce(0) { $0 + $1.duration }
            let lastSeen = filteredSessions.map { $0.date }.max() ?? .distantPast
            
            stats.append(FriendStats(id: id, totalDuration: totalDuration, lastSeen: lastSeen))
        }
        
        let sortedStats = stats.sorted { $0.totalDuration > $1.totalDuration }
        return Array(sortedStats.prefix(4))
    }
    
    private func formatToHoursOnly(_ duration: TimeInterval) -> String {
        let hours = Int(duration / 3600)
        if hours == 0 && duration > 0 {
            return "<1h"
        }
        return "\(hours)h"
    }
    
    // --- UI ---
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 25) {
                    
                    // --- FILTRES DE TEMPS ---
                    HStack(spacing: 10) {
                        ForEach(TimeFilter.allCases, id: \.self) { filter in
                            Button(action: {
                                withAnimation { selectedFilter = filter }
                            }) {
                                Text(filter.rawValue)
                                    .font(.subheadline)
                                    .fontWeight(selectedFilter == filter ? .bold : .medium)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedFilter == filter ? Color.purple : Color.gray.opacity(0.2))
                                    .foregroundColor(selectedFilter == filter ? .white : .gray)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.top, 10)
                    
                    // --- SECTION : TES AMIS ---
                    VStack(spacing: 15) {
                        HStack {
                            Text("Tes amis")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            Spacer()
                            
                            Button(action: { selectedTab = .friends }) {
                                Text("Voir tous")
                                    .font(.subheadline)
                                    .foregroundColor(.purple)
                            }
                        }
                        .padding(.horizontal)
                        if topFriends.isEmpty {
                            Text("Aucune donnée pour cette période.")
                                .foregroundColor(.gray)
                                .italic()
                        } else {
                            ForEach(topFriends, id: \.id) { stats in
                                // On recrée/récupère l'objet ami pour le passer au Profil
                                let friendObj = manager.savedFriends.first(where: { $0.id == stats.id })
                                    ?? SavedFriend(id: stats.id, originalName: historyVM.getDisplayName(for: stats.id), customName: nil)
                                
                                // On enveloppe la box de l'ami dans un NavigationLink
                                NavigationLink(destination: FriendProfileView(friend: friendObj, manager: manager, historyVM: historyVM)) {
                                    FriendRowView(
                                        name: historyVM.getDisplayName(for: stats.id),
                                        durationString: formatToHoursOnly(stats.totalDuration),
                                        lastSeen: stats.lastSeen
                                    )
                                }
                                .buttonStyle(PlainButtonStyle()) // Évite que le texte devienne bleu
                                .padding(.horizontal)
                            }
                        }
                    }
                    
                    // --- SECTION : HANGOUT ---
                    VStack(spacing: 15) {
                        HStack {
                            Text("Hangout")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            Spacer()
                            
                            Button(action: { selectedTab = .hangout }) {
                                Text("Voir tous")
                                    .font(.subheadline)
                                    .foregroundColor(.purple)
                            }
                        }
                        .padding(.horizontal)
                        
                        // CARROUSEL HORIZONTAL
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 15) {
                                // On prend maintenant les 3 premiers Hangouts
                                ForEach(upcomingHangouts.prefix(3)) { hangout in
                                    HangoutRowView(hangout: hangout)
                                        // On force une taille identique pour toutes les box du carrousel
                                        .frame(width: 260, height: 130)
                                }
                            }
                            // Pour aligner la première box avec le texte "Hangout"
                            .padding(.horizontal)
                        }
                    }
                    
                    Spacer()
                }
                .padding(.bottom, 30) // Un peu d'espace en bas de la page
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: AddFriendView(manager: manager)) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                }
                
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Temps Total")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .textCase(.uppercase)
                        
                        Text(formatToHoursOnly(filteredTotalAppTime))
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.purple)
                            .contentTransition(.numericText())
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: NotificationsView()) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }
}

// Composant visuel pour un "Ami"
struct FriendRowView: View {
    
    let name: String
    let durationString: String
    let lastSeen: Date
    
    var body: some View {
        HStack(spacing: 15) {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 50, height: 50)
                .overlay(Image(systemName: "person.fill").foregroundColor(.white).font(.system(size: 24)))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(formatLastSeen(lastSeen)).font(.caption).foregroundColor(.gray)
            }
            Spacer()
            
            Text(durationString)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.purple.opacity(0.8))
                .clipShape(Capsule())
        }
        .padding()
        .background(Color(white: 0.12))
        .cornerRadius(16)
    }
    
    private static let lastSeenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .none; f.dateStyle = .medium
        f.doesRelativeDateFormatting = true
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    private func formatLastSeen(_ date: Date) -> String {
        "Vu(e) \(Self.lastSeenFormatter.string(from: date).lowercased())"
    }
}

// Composant visuel pour un "Hangout"
struct HangoutRowView: View {
    let hangout: HangoutMock
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Titre avec limitation sur 1 seule ligne et "..."
            Text(hangout.title)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            
            // Date et Heure
            Text(formatDate(hangout.date))
                .font(.subheadline)
                .foregroundColor(.gray)
            
            Spacer(minLength: 0) // Pousse les photos vers le bas de la box
            
            // Photos de profil empilées
            HStack(spacing: -12) {
                let maxDisplay = min(hangout.participantCount, 5)
                
                ForEach(0..<maxDisplay, id: \.self) { _ in
                    Circle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 35, height: 35)
                        .overlay(Circle().stroke(Color(white: 0.12), lineWidth: 2))
                        .overlay(Image(systemName: "person.fill").foregroundColor(.white).font(.system(size: 16)))
                }
                
                if hangout.participantCount > 5 {
                    let remaining = hangout.participantCount - 5
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 35, height: 35)
                        .overlay(Circle().stroke(Color(white: 0.12), lineWidth: 2))
                        .overlay(
                            Text("+\(remaining)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        )
                }
            }
        }
        .padding()
        // La box s'adapte à la taille fixe (.frame) définie dans le parent (HomeView)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.12))
        .cornerRadius(16)
    }
    
    private static let hangoutDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE 'à' HH:mm"
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.hangoutDateFormatter.string(from: date).capitalized
    }
}
