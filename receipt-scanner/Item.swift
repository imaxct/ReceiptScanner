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
    var timestamp: Date
    var merchant: String
    var total: Double
    var tax: Double
    var note: String
    var rawText: String
    @Attribute(.externalStorage) var imageData: Data?

    init(
        timestamp: Date = Date(),
        merchant: String = "",
        total: Double = 0,
        tax: Double = 0,
        note: String = "",
        rawText: String = "",
        imageData: Data? = nil
    ) {
        self.timestamp = timestamp
        self.merchant = merchant
        self.total = total
        self.tax = tax
        self.note = note
        self.rawText = rawText
        self.imageData = imageData
    }
}
