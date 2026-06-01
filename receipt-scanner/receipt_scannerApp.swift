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
        // Local-only store. CloudKit sync requires a paid Apple Developer
        // account + iCloud entitlement; users can use the JSON export/import
        // in the Account tab to move data between devices instead.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
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
