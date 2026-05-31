//
//  ContentView.swift
//  receipt-scanner
//
//  Created by Hao Dong on 5/31/26.
//

import SwiftUI
import SwiftData
import VisionKit
import Vision
import UIKit

// MARK: - Root Tabs

struct RootTabView: View {
    var body: some View {
        TabView {
            ReceiptListView()
                .tabItem { Label("Receipts", systemImage: "doc.text.viewfinder") }

            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
    }
}

// MARK: - Receipts List

struct ReceiptListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Receipt.timestamp, order: .reverse) private var receipts: [Receipt]

    @State private var showScanner = false
    @State private var pendingDraft: ReceiptDraft?
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if receipts.isEmpty {
                        ContentUnavailableView(
                            "No Receipts Yet",
                            systemImage: "doc.text.viewfinder",
                            description: Text("Tap the button below to scan your first receipt.")
                        )
                    } else {
                        List {
                            ForEach(receipts) { receipt in
                                NavigationLink {
                                    ReceiptDetailView(receipt: receipt)
                                } label: {
                                    ReceiptRow(receipt: receipt)
                                }
                            }
                            .onDelete(perform: deleteReceipts)
                        }
                    }
                }

                scanButton
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Receipts")
            .toolbar {
                if !receipts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
            .sheet(isPresented: $showScanner) {
                DocumentScannerView { result in
                    showScanner = false
                    handleScanResult(result)
                }
                .ignoresSafeArea()
            }
            .sheet(item: $pendingDraft) { draft in
                ReceiptEditorView(
                    mode: .create(draft),
                    onSave: { saved in
                        modelContext.insert(saved)
                        pendingDraft = nil
                    },
                    onCancel: { pendingDraft = nil }
                )
            }
            .alert("Scan Failed", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scanError ?? "")
            }
        }
    }

    private var scanButton: some View {
        Button {
            showScanner = true
        } label: {
            Label("Scan Receipt", systemImage: "camera.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 4, y: 2)
        }
    }

    private func handleScanResult(_ result: Result<UIImage, Error>) {
        switch result {
        case .success(let image):
            ReceiptOCR.recognize(in: image) { ocr in
                let parsed = ReceiptParser.parse(ocr)
                let data = image.jpegData(compressionQuality: 0.8)
                // Prefer the spatially-merged rows for the stored raw text so the
                // user sees label + amount on the same line.
                let displayText = ocr.rows.isEmpty ? ocr.text : ocr.rows.joined(separator: "\n")
                let draft = ReceiptDraft(
                    timestamp: parsed.date ?? Date(),
                    merchant: parsed.merchant ?? "",
                    total: parsed.total ?? 0,
                    tax: parsed.tax ?? 0,
                    note: "",
                    rawText: displayText,
                    imageData: data
                )
                pendingDraft = draft
            }
        case .failure(let error):
            scanError = error.localizedDescription
        }
    }

    private func deleteReceipts(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(receipts[index])
            }
        }
    }
}

// MARK: - Row

struct ReceiptRow: View {
    let receipt: Receipt

    var body: some View {
        HStack(spacing: 12) {
            if let data = receipt.imageData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "doc.text").foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.merchant.isEmpty ? "Receipt" : receipt.merchant)
                    .font(.headline)
                    .lineLimit(1)
                Text(receipt.timestamp, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(receipt.total, format: .currency(code: "USD"))
                    .font(.headline)
                Text("Tax \(receipt.tax, format: .currency(code: "USD"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct ReceiptDetailView: View {
    @Bindable var receipt: Receipt
    @State private var isEditing = false
    @State private var copiedMessage: String?

    private var currencyCode: String { "USD" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data = receipt.imageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contextMenu {
                            Button {
                                UIPasteboard.general.image = img
                                showCopied("Image copied")
                            } label: {
                                Label("Copy Image", systemImage: "doc.on.doc")
                            }
                        }
                }

                VStack(spacing: 0) {
                    copyableRow(
                        label: "Merchant",
                        display: receipt.merchant.isEmpty ? "—" : receipt.merchant,
                        copyValue: receipt.merchant
                    )
                    Divider()
                    copyableRow(
                        label: "Date",
                        display: receipt.timestamp.formatted(date: .abbreviated, time: .shortened),
                        copyValue: receipt.timestamp.formatted(date: .abbreviated, time: .shortened)
                    )
                    Divider()
                    copyableRow(
                        label: "Total",
                        display: receipt.total.formatted(.currency(code: currencyCode)),
                        copyValue: String(format: "%.2f", receipt.total)
                    )
                    Divider()
                    copyableRow(
                        label: "Tax",
                        display: receipt.tax.formatted(.currency(code: currencyCode)),
                        copyValue: String(format: "%.2f", receipt.tax)
                    )
                    if !receipt.note.isEmpty {
                        Divider()
                        copyableRow(label: "Note", display: receipt.note, copyValue: receipt.note)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if !receipt.rawText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recognized Text").font(.headline)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = receipt.rawText
                                showCopied("Text copied")
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                        }
                        Text(receipt.rawText)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = receipt.rawText
                                    showCopied("Text copied")
                                } label: {
                                    Label("Copy All", systemImage: "doc.on.doc")
                                }
                            }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .overlay(alignment: .bottom) {
            if let msg = copiedMessage {
                Text(msg)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .navigationTitle(receipt.merchant.isEmpty ? "Receipt" : receipt.merchant)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            ReceiptEditorView(
                mode: .edit(receipt),
                onSave: { _ in isEditing = false },
                onCancel: { isEditing = false }
            )
        }
    }

    @ViewBuilder
    private func copyableRow(label: String, display: String, copyValue: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(display)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = copyValue
                showCopied("\(label) copied")
            } label: {
                Label("Copy \(label)", systemImage: "doc.on.doc")
            }
        }
    }

    private func showCopied(_ message: String) {
        withAnimation { copiedMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { copiedMessage = nil }
        }
    }
}

// MARK: - Editor

struct ReceiptDraft: Identifiable {
    let id = UUID()
    var timestamp: Date
    var merchant: String
    var total: Double
    var tax: Double
    var note: String
    var rawText: String
    var imageData: Data?
}

struct ReceiptEditorView: View {
    enum Mode {
        case create(ReceiptDraft)
        case edit(Receipt)
    }

    let mode: Mode
    let onSave: (Receipt) -> Void
    let onCancel: () -> Void

    @State private var timestamp: Date = Date()
    @State private var merchant: String = ""
    @State private var totalString: String = ""
    @State private var taxString: String = ""
    @State private var note: String = ""
    @State private var imageData: Data?
    @State private var rawText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                if let data = imageData, let img = UIImage(data: data) {
                    Section {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                    }
                }

                Section("Details") {
                    TextField("Merchant", text: $merchant)
                    DatePicker("Date", selection: $timestamp)
                    HStack {
                        Text("Total")
                        Spacer()
                        TextField("0.00", text: $totalString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Tax")
                        Spacer()
                        TextField("0.00", text: $taxString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Note", text: $note, axis: .vertical)
                }

                if !rawText.isEmpty {
                    Section("Recognized Text") {
                        Text(rawText).font(.footnote)
                    }
                }
            }
            .navigationTitle(isCreating ? "Confirm Receipt" : "Edit Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isCreating ? "Save" : "Done") { commit() }
                        .bold()
                }
            }
            .onAppear(perform: load)
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private func load() {
        switch mode {
        case .create(let draft):
            timestamp = draft.timestamp
            merchant = draft.merchant
            totalString = String(format: "%.2f", draft.total)
            taxString = String(format: "%.2f", draft.tax)
            note = draft.note
            rawText = draft.rawText
            imageData = draft.imageData
        case .edit(let receipt):
            timestamp = receipt.timestamp
            merchant = receipt.merchant
            totalString = String(format: "%.2f", receipt.total)
            taxString = String(format: "%.2f", receipt.tax)
            note = receipt.note
            rawText = receipt.rawText
            imageData = receipt.imageData
        }
    }

    private func commit() {
        let total = Double(totalString.replacingOccurrences(of: ",", with: ".")) ?? 0
        let tax = Double(taxString.replacingOccurrences(of: ",", with: ".")) ?? 0

        switch mode {
        case .create:
            let receipt = Receipt(
                timestamp: timestamp,
                merchant: merchant,
                total: total,
                tax: tax,
                note: note,
                rawText: rawText,
                imageData: imageData
            )
            onSave(receipt)
        case .edit(let receipt):
            receipt.timestamp = timestamp
            receipt.merchant = merchant
            receipt.total = total
            receipt.tax = tax
            receipt.note = note
            onSave(receipt)
        }
    }
}

// MARK: - Account Tab

struct AccountView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("Guest").font(.headline)
                            Text("Sign in coming soon").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Preferences") {
                    Text("Currency").foregroundStyle(.secondary)
                    Text("Export Data").foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                }
            }
            .navigationTitle("Account")
        }
    }
}

// MARK: - Document Scanner (VisionKit)

struct DocumentScannerView: UIViewControllerRepresentable {
    let completion: (Result<UIImage, Error>) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<UIImage, Error>) -> Void
        init(completion: @escaping (Result<UIImage, Error>) -> Void) {
            self.completion = completion
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else {
                controller.dismiss(animated: true)
                completion(.failure(NSError(domain: "Scanner", code: -1, userInfo: [NSLocalizedDescriptionKey: "No pages scanned."])))
                return
            }
            let image = scan.imageOfPage(at: 0)
            controller.dismiss(animated: true)
            completion(.success(image))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
            completion(.failure(error))
        }
    }
}

// MARK: - OCR

struct OCRObservation {
    let text: String
    /// Normalized bounding box in Vision coords (origin at bottom-left, 0...1).
    let bbox: CGRect
}

struct OCRResult {
    let text: String
    let lines: [String]
    let observations: [OCRObservation]
    /// Lines reconstructed by spatially merging observations that share a row.
    let rows: [String]
}

enum ReceiptOCR {
    static func recognize(in image: UIImage, completion: @escaping (OCRResult) -> Void) {
        guard let cgImage = image.cgImage else {
            completion(OCRResult(text: "", lines: [], observations: [], rows: []))
            return
        }
        let request = VNRecognizeTextRequest { request, _ in
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let items: [OCRObservation] = observations.compactMap { obs in
                guard let s = obs.topCandidates(1).first?.string else { return nil }
                return OCRObservation(text: s, bbox: obs.boundingBox)
            }
            let lines = items.map { $0.text }
            let text = lines.joined(separator: "\n")
            let rows = mergeIntoRows(items)
            DispatchQueue.main.async {
                completion(OCRResult(text: text, lines: lines, observations: items, rows: rows))
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(from: image.imageOrientation))
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    completion(OCRResult(text: "", lines: [], observations: [], rows: []))
                }
            }
        }
    }

    /// Merges OCR observations that share a horizontal row (similar Y center) into single
    /// row strings, ordered top-to-bottom on the receipt and left-to-right within a row.
    private static func mergeIntoRows(_ items: [OCRObservation]) -> [String] {
        guard !items.isEmpty else { return [] }
        // Use median observation height as a tolerance baseline.
        let heights = items.map { $0.bbox.height }.sorted()
        let medianHeight = heights[heights.count / 2]
        let tolerance = max(medianHeight * 0.6, 0.008)

        // Sort top-to-bottom (Vision Y is bottom-up, so larger Y = higher on page).
        let sorted = items.sorted { $0.bbox.midY > $1.bbox.midY }

        var rows: [[OCRObservation]] = []
        for item in sorted {
            if let lastIdx = rows.indices.last {
                let lastRowMidY = rows[lastIdx].map(\.bbox.midY).reduce(0, +) / CGFloat(rows[lastIdx].count)
                if abs(lastRowMidY - item.bbox.midY) <= tolerance {
                    rows[lastIdx].append(item)
                    continue
                }
            }
            rows.append([item])
        }

        return rows.map { row in
            row.sorted { $0.bbox.minX < $1.bbox.minX }
                .map { $0.text }
                .joined(separator: "  ")
        }
    }

    private static func cgOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Parser

struct ParsedReceipt {
    var merchant: String?
    var total: Double?
    var tax: Double?
    var date: Date?
}

enum ReceiptParser {
    /// Parse using spatially-merged rows when available; falls back to raw text.
    static func parse(_ ocr: OCRResult) -> ParsedReceipt {
        let rows = ocr.rows.isEmpty ? ocr.lines : ocr.rows
        return parse(rows: rows)
    }

    static func parse(rows inputRows: [String]) -> ParsedReceipt {
        let rows = inputRows
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result = ParsedReceipt()

        // Merchant: first row with enough letters and no big amount in it
        // (avoids picking up an address line if the store name was missed).
        result.merchant = rows.first(where: { line in
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            return letters.count >= 3 && extractAmounts(from: line).isEmpty
        }) ?? rows.first(where: { line in
            line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 3
        })

        // Date: scan all rows with NSDataDetector.
        result.date = detectDate(in: rows.joined(separator: "\n"))

        // Total / Tax keyword priority lists (more specific first).
        // "total tax" / "tax total" route to TAX, not total.
        let totalKeywords = [
            "grand total", "total purchase", "total amount", "amount due",
            "balance to pay", "balance due", "amount paid", "amount tendered",
            "you pay", "order total", "net total", "total", "balance", "amount"
        ]
        let taxKeywords = [
            "total tax", "tax total", "sales tax", "state tax", "county tax",
            "city tax", "local tax", "tax"
        ]
        let subtotalKeywords = ["subtotal", "sub total", "sub-total", "merchandise total"]
        // Lines we should never treat as the customer total even if they contain "amount" etc.
        let nonTotalNoise = ["tip", "gratuity", "change", "cash back", "cashback", "rounding"]

        var totalCandidates: [(priority: Int, value: Double)] = []
        var taxCandidates: [(priority: Int, value: Double, raw: String)] = []

        for row in rows {
            let lower = row.lowercased()
            let amounts = extractAmounts(from: row)
            guard let last = amounts.last else { continue }

            let isSubtotal = subtotalKeywords.contains(where: { lower.contains($0) })
            let isNoise = nonTotalNoise.contains(where: { lower.contains($0) })

            // Tax matching first — if this row is a tax row, don't also count it as a total.
            var matchedAsTax = false
            for (idx, kw) in taxKeywords.enumerated() where containsKeyword(lower, keyword: kw) {
                taxCandidates.append((priority: idx, value: last, raw: lower))
                matchedAsTax = true
                break
            }

            if !isSubtotal && !isNoise && !matchedAsTax {
                for (idx, kw) in totalKeywords.enumerated() where containsKeyword(lower, keyword: kw) {
                    totalCandidates.append((priority: idx, value: last))
                    break
                }
            }
        }

        // Total: highest-priority keyword match, else largest amount overall.
        if let best = totalCandidates.min(by: { $0.priority < $1.priority }) {
            result.total = best.value
        } else {
            let all = rows.flatMap { extractAmounts(from: $0) }
            result.total = all.max()
        }

        // Tax: prefer "total tax"/"tax total"/"sales tax" line if present;
        // otherwise sum all per-rate tax lines (state + county + city, etc.).
        if let totalTax = taxCandidates.first(where: { $0.priority <= 2 }) {
            result.tax = totalTax.value
        } else if !taxCandidates.isEmpty {
            // Deduplicate by amount to avoid summing a single tax printed twice.
            let unique = Array(Set(taxCandidates.map { $0.value }))
            result.tax = unique.reduce(0, +)
        }

        return result
    }

    /// Word-boundary-ish match so "tax" doesn't match inside "Texas" and
    /// "total" doesn't match inside "subtotal" (we already pre-filter, but
    /// this is a safety net).
    private static func containsKeyword(_ haystack: String, keyword: String) -> Bool {
        guard let range = haystack.range(of: keyword) else { return false }
        let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
        let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
        let isLetter: (Character?) -> Bool = { ch in
            guard let ch else { return false }
            return ch.isLetter
        }
        return !isLetter(before) && !isLetter(after)
    }

    private static func detectDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = detector.matches(in: text, range: range)
        let keywords = ["date", "time", "trans", "purchase", "sale", "sold", "receipt", "printed"]
        // Reasonable acceptance window: not in the future (allow 1 day slack
        // for time-zone weirdness) and not absurdly old.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let earliest = Calendar.current.date(byAdding: .year, value: -20, to: Date()) ?? Date.distantPast

        struct Candidate {
            let date: Date
            let location: Int
            let length: Int
            let hasFullTimestamp: Bool   // matched text has both date-sep and time-sep
            let nearKeyword: Bool
        }

        var candidates: [Candidate] = []
        for m in matches {
            guard let d = m.date else { continue }
            if d > tomorrow || d < earliest { continue }

            let matched = ns.substring(with: m.range)
            // Reject tiny fragments like "6/2" — require at least a year component.
            // Year can be 2 or 4 digits, separated by / or -.
            let parts = matched.components(separatedBy: CharacterSet(charactersIn: "/-")).filter { !$0.isEmpty }
            let monthDayYear = parts.count >= 3 && parts.allSatisfy { $0.rangeOfCharacter(from: .decimalDigits.inverted) == nil || $0.contains(" ") }
            let hasMonthName = matched.range(of: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#, options: .regularExpression) != nil
            guard monthDayYear || hasMonthName else { continue }

            let hasDateSep = matched.contains("/") || matched.contains("-") || hasMonthName
            let hasTimeSep = matched.contains(":") || matched.uppercased().contains("AM") || matched.uppercased().contains("PM")
            let hasFullTimestamp = hasDateSep && hasTimeSep

            // Look at up to 24 characters before the match for context keywords.
            let prefixStart = max(0, m.range.location - 24)
            let prefixRange = NSRange(location: prefixStart, length: m.range.location - prefixStart)
            let prefix = ns.substring(with: prefixRange).lowercased()
            let nearKeyword = keywords.contains(where: { prefix.contains($0) })

            candidates.append(Candidate(
                date: d,
                location: m.range.location,
                length: m.range.length,
                hasFullTimestamp: hasFullTimestamp,
                nearKeyword: nearKeyword
            ))
        }

        // Rank: full timestamp first, then near-keyword, then later occurrence,
        // then longer match. Receipts usually print the most authoritative
        // timestamp near the bottom (transaction footer).
        let sorted = candidates.sorted { a, b in
            if a.hasFullTimestamp != b.hasFullTimestamp { return a.hasFullTimestamp && !b.hasFullTimestamp }
            if a.nearKeyword != b.nearKeyword { return a.nearKeyword && !b.nearKeyword }
            if a.location != b.location { return a.location > b.location }
            return a.length > b.length
        }
        return sorted.first?.date
    }

    /// Match currency-style amounts: must contain a 2-digit decimal part.
    /// Optional leading `-` (refund) or `$`. Excludes ZIP codes, percentages
    /// like "10.3", item counts, and phone segments.
    private static let amountRegex: NSRegularExpression = {
        return try! NSRegularExpression(
            pattern: #"(?<![\d.])-?\$?\s?\d{1,3}(?:,\d{3})+\.\d{2}(?!\d)|(?<![\d.])-?\$?\s?\d+\.\d{2}(?!\d)"#
        )
    }()

    private static func extractAmounts(from line: String) -> [Double] {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = amountRegex.matches(in: line, range: range)
        return matches.compactMap { m -> Double? in
            let s = ns.substring(with: m.range)
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(s)
        }
    }
}

// MARK: - Preview

#Preview {
    RootTabView()
        .modelContainer(for: Receipt.self, inMemory: true)
}
