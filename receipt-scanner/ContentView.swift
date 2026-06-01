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
import UniformTypeIdentifiers

// MARK: - Image helpers

extension UIImage {
    /// Generates a downscaled image whose longest side is `maxDimension` points.
    /// Used to produce ~5–10 KB JPEG thumbnails for fast list rendering.
    nonisolated func thumbnail(maxDimension: CGFloat = 200) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2   // @2x is plenty for a 56pt list cell
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            self.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Root Tabs

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            ReceiptListView()
                .tabItem { Label("Receipts", systemImage: "doc.text.viewfinder") }

            SummaryView()
                .tabItem { Label("Summary", systemImage: "chart.bar.xaxis") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { await backfillThumbnailsIfNeeded() }
    }

    /// One-time background pass that generates thumbnails for receipts created
    /// before the thumbnail column existed. Safe to run on every launch — once
    /// every row has a thumbnail, the fetch returns nothing.
    private func backfillThumbnailsIfNeeded() async {
        let descriptor = FetchDescriptor<Receipt>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        let needs = all.filter { $0.thumbnailData == nil && $0.imageData != nil }
        guard !needs.isEmpty else { return }

        for receipt in needs {
            guard let data = receipt.imageData else { continue }
            let thumb = await Task.detached(priority: .utility) { () -> Data? in
                guard let img = UIImage(data: data) else { return nil }
                return img.thumbnail(maxDimension: 200).jpegData(compressionQuality: 0.7)
            }.value
            receipt.thumbnailData = thumb
        }
        try? modelContext.save()
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
                let thumbData = image.thumbnail(maxDimension: 200).jpegData(compressionQuality: 0.7)
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
                    imageData: data,
                    thumbnailData: thumbData
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
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(Image(systemName: "doc.text").foregroundStyle(.secondary))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

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
        .task(id: receipt.uuid) {
            // Decode off the main thread; prefer the small thumbnail, fall back
            // to the full image (with on-the-fly downsizing) for older receipts.
            let thumbBytes = receipt.thumbnailData
            let fullBytes = receipt.imageData
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                if let t = thumbBytes, let img = UIImage(data: t) { return img }
                if let f = fullBytes, let img = UIImage(data: f) {
                    return img.thumbnail(maxDimension: 200)
                }
                return nil
            }.value
            self.thumbnail = decoded
        }
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
    var thumbnailData: Data?
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
    @State private var thumbnailData: Data?
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
            thumbnailData = draft.thumbnailData
        case .edit(let receipt):
            timestamp = receipt.timestamp
            merchant = receipt.merchant
            totalString = String(format: "%.2f", receipt.total)
            taxString = String(format: "%.2f", receipt.tax)
            note = receipt.note
            rawText = receipt.rawText
            imageData = receipt.imageData
            thumbnailData = receipt.thumbnailData
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
                imageData: imageData,
                thumbnailData: thumbnailData
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

// MARK: - Summary Tab

enum SummaryPeriod: String, CaseIterable, Identifiable {
    case week = "Weekly"
    case month = "Monthly"
    case year = "Yearly"

    var id: String { rawValue }

    var calendarComponent: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    /// How many most-recent buckets to show.
    var bucketCount: Int {
        switch self {
        case .week: return 12
        case .month: return 12
        case .year: return 5
        }
    }
}

struct SummaryBucket: Identifiable {
    let id: Date          // start of the bucket
    let start: Date
    let end: Date
    let label: String
    var total: Double
    var tax: Double
    var count: Int
}

struct SummaryView: View {
    @Query(sort: \Receipt.timestamp, order: .reverse) private var receipts: [Receipt]
    @State private var period: SummaryPeriod = .month

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(SummaryPeriod.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                let buckets = makeBuckets()
                let totals = buckets.reduce(into: (spent: 0.0, tax: 0.0, count: 0)) { acc, b in
                    acc.spent += b.total; acc.tax += b.tax; acc.count += b.count
                }

                Section("Totals (last \(period.bucketCount) \(period.rawValue.lowercased()))") {
                    summaryRow(title: "Spent", value: totals.spent.formatted(.currency(code: "USD")))
                    summaryRow(title: "Tax", value: totals.tax.formatted(.currency(code: "USD")))
                    summaryRow(title: "Receipts", value: "\(totals.count)")
                }

                Section("By \(period.rawValue.dropLast(2))") {
                    if buckets.allSatisfy({ $0.count == 0 }) {
                        Text("No receipts in this period.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(buckets) { bucket in
                            bucketRow(bucket)
                        }
                    }
                }
            }
            .navigationTitle("Summary")
        }
    }

    private func summaryRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.headline.monospacedDigit())
        }
    }

    private func bucketRow(_ bucket: SummaryBucket) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.label).font(.headline)
                Text("\(bucket.count) receipt\(bucket.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(bucket.total, format: .currency(code: "USD"))
                    .font(.headline.monospacedDigit())
                Text("Tax \(bucket.tax, format: .currency(code: "USD"))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Build the most recent N buckets for the selected period, oldest → newest reversed for display.
    private func makeBuckets() -> [SummaryBucket] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [SummaryBucket] = []
        for offset in 0..<period.bucketCount {
            guard
                let bucketDate = calendar.date(byAdding: period.calendarComponent, value: -offset, to: now),
                let interval = calendar.dateInterval(of: period.calendarComponent, for: bucketDate)
            else { continue }
            buckets.append(SummaryBucket(
                id: interval.start,
                start: interval.start,
                end: interval.end,
                label: bucketLabel(for: interval.start),
                total: 0, tax: 0, count: 0
            ))
        }

        for receipt in receipts {
            if let idx = buckets.firstIndex(where: { receipt.timestamp >= $0.start && receipt.timestamp < $0.end }) {
                buckets[idx].total += receipt.total
                buckets[idx].tax += receipt.tax
                buckets[idx].count += 1
            }
        }

        return buckets
    }

    private func bucketLabel(for date: Date) -> String {
        let f = DateFormatter()
        switch period {
        case .week:
            let endDate = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
            f.dateFormat = "MMM d"
            return "\(f.string(from: date)) – \(f.string(from: endDate))"
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: date)
        case .year:
            f.dateFormat = "yyyy"
            return f.string(from: date)
        }
    }
}

// MARK: - Settings Tab

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var receipts: [Receipt]

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: BackupDocument?
    @State private var statusMessage: String?
    @State private var isShowingStatus = false

    var body: some View {
        NavigationStack {
            List {
                Section("Library") {
                    LabeledContent("Receipts", value: "\(receipts.count)")
                    LabeledContent(
                        "Total Spent",
                        value: receipts.reduce(0) { $0 + $1.total }
                            .formatted(.currency(code: "USD"))
                    )
                    LabeledContent(
                        "Total Tax",
                        value: receipts.reduce(0) { $0 + $1.tax }
                            .formatted(.currency(code: "USD"))
                    )
                }

                Section {
                    Button {
                        startExport()
                    } label: {
                        Label("Export Backup", systemImage: "square.and.arrow.up")
                    }
                    .disabled(receipts.isEmpty)

                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Backup", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Export saves all receipts and images into a single .json file you can store in iCloud Drive, Files, or AirDrop to another iPhone. Import merges receipts from a backup file (duplicates are skipped).")
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                }
            }
            .navigationTitle("Settings")
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: defaultExportFilename()
            ) { result in
                switch result {
                case .success: showStatus("Exported \(receipts.count) receipts")
                case .failure(let error): showStatus("Export failed: \(error.localizedDescription)")
                }
                exportDocument = nil
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importBackup(from: url) }
                case .failure(let error):
                    showStatus("Import failed: \(error.localizedDescription)")
                }
            }
            .overlay(alignment: .bottom) {
                if isShowingStatus, let msg = statusMessage {
                    Text(msg)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    private func startExport() {
        let payload = BackupFile(
            version: 1,
            exportedAt: Date(),
            receipts: receipts.map { ReceiptExport(from: $0) }
        )
        exportDocument = BackupDocument(backup: payload)
        isExporting = true
    }

    private func importBackup(from url: URL) {
        // Security-scoped resource access is required for files outside the app sandbox.
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(BackupFile.self, from: data)

            let existingIDs = Set(receipts.map { $0.uuid })
            var added = 0
            for r in backup.receipts where !existingIDs.contains(r.id) {
                modelContext.insert(r.toReceipt())
                added += 1
            }
            try? modelContext.save()
            let skipped = backup.receipts.count - added
            showStatus("Imported \(added), skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")")
        } catch {
            showStatus("Import failed: \(error.localizedDescription)")
        }
    }

    private func defaultExportFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "receipts-\(f.string(from: Date()))"
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        withAnimation { isShowingStatus = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { isShowingStatus = false }
        }
    }
}

// MARK: - Backup Format

nonisolated struct ReceiptExport: Codable {
    let id: UUID
    let timestamp: Date
    let merchant: String
    let total: Double
    let tax: Double
    let note: String
    let rawText: String
    /// Base64-encoded JPEG/PNG image data. Optional.
    let imageBase64: String?

    init(from r: Receipt) {
        self.id = r.uuid
        self.timestamp = r.timestamp
        self.merchant = r.merchant
        self.total = r.total
        self.tax = r.tax
        self.note = r.note
        self.rawText = r.rawText
        self.imageBase64 = r.imageData?.base64EncodedString()
    }

    func toReceipt() -> Receipt {
        let imgData = imageBase64.flatMap { Data(base64Encoded: $0) }
        let thumb = imgData.flatMap { UIImage(data: $0) }?
            .thumbnail(maxDimension: 200)
            .jpegData(compressionQuality: 0.7)
        return Receipt(
            uuid: id,
            timestamp: timestamp,
            merchant: merchant,
            total: total,
            tax: tax,
            note: note,
            rawText: rawText,
            imageData: imgData,
            thumbnailData: thumb
        )
    }
}

nonisolated struct BackupFile: Codable {
    let version: Int
    let exportedAt: Date
    let receipts: [ReceiptExport]
}

nonisolated struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var backup: BackupFile

    init(backup: BackupFile) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.backup = try decoder.decode(BackupFile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        return FileWrapper(regularFileWithContents: data)
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
            "total tax", "tax total", "sales tax", "salestax",
            "state tax", "statetax", "county tax", "city tax",
            "local tax", "tax"
        ]
        let subtotalKeywords = ["subtotal", "sub total", "sub-total", "merchandise total"]
        // Lines we should never treat as the customer total even if they contain "amount" etc.
        // "savings"/"discount"/"coupon" totals belong to promos, not what the customer paid.
        let nonTotalNoise = [
            "tip", "gratuity", "change", "cash back", "cashback", "rounding",
            "saving", "savings", "discount", "coupon", "rewards", "reward",
            "markdown", "you saved",
            // Item-count summaries like "Total 10.91 Items" / "12 items" — not money.
            "items", "item count", "qty", "quantity"
        ]

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

        // Total: highest-priority keyword match (ties broken by larger amount,
        // since the real total often appears multiple times near the bottom),
        // else largest amount overall.
        if let best = totalCandidates.min(by: { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.value > b.value
        }) {
            result.total = best.value
        } else {
            let all = rows.flatMap { extractAmounts(from: $0) }
            result.total = all.max()
        }

        // Tax: prefer "total tax"/"tax total"/"sales tax"/"salestax" line if present;
        // otherwise sum all per-rate tax lines (state + county + city, etc.).
        if let totalTax = taxCandidates.first(where: { $0.priority <= 3 }) {
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

    /// Match currency-style amounts: must contain a 2-digit decimal part
    /// (a stray 3rd digit from OCR slips like "$16.317" is also tolerated).
    /// Optional leading `-` (refund) or `$`. Excludes ZIP codes, percentages
    /// like "10.3", item counts, and phone segments.
    private static let amountRegex: NSRegularExpression = {
        return try! NSRegularExpression(
            pattern: #"(?<![\d.])-?\$?\s?\d{1,3}(?:,\d{3})+\.\d{2,3}(?!\d)|(?<![\d.])-?\$?\s?\d+\.\d{2,3}(?!\d)"#
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
