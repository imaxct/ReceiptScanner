//
//  receipt_scannerApp.swift
//  receipt-scanner
//
//  Created by Hao Dong on 5/31/26.
//

import SwiftUI
import SwiftData

@main
struct receipt_scannerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Receipt.self])
        // Use the automatic CloudKit database when the iCloud entitlement is
        // present; SwiftData transparently falls back to local-only otherwise.
        // If you want to pin to a specific container, replace `.automatic`
        // with `.private("iCloud.<your.bundle.id>")`.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(sharedModelContainer)
    }
}
