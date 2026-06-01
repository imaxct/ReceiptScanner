//
//  Receipt.swift
//  receipt-scanner
//
//  Created by Hao Dong on 5/31/26.
//

import Foundation
import SwiftData

@Model
final class Receipt {
    /// Stable identifier used for deduplication when importing backups.
    /// Named `uuid` (not `id`) to avoid shadowing the `Identifiable`
    /// conformance synthesized from `persistentModelID`, which would make
    /// SwiftUI `ForEach` collapse rows that share a default UUID.
    var uuid: UUID = UUID()
    var timestamp: Date = Date()
    var merchant: String = ""
    var total: Double = 0
    var tax: Double = 0
    var note: String = ""
    var rawText: String = ""
    @Attribute(.externalStorage) var imageData: Data?

    init(
        uuid: UUID = UUID(),
        timestamp: Date = Date(),
        merchant: String = "",
        total: Double = 0,
        tax: Double = 0,
        note: String = "",
        rawText: String = "",
        imageData: Data? = nil
    ) {
        self.uuid = uuid
        self.timestamp = timestamp
        self.merchant = merchant
        self.total = total
        self.tax = tax
        self.note = note
        self.rawText = rawText
        self.imageData = imageData
    }
}
