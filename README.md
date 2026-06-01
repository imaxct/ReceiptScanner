# ReceiptScanner

A SwiftUI + SwiftData iOS app that scans paper receipts with the device camera, extracts the merchant, date, total, and tax via on-device OCR, and stores everything (image included) locally for later review.

## Features

- **Scan with VisionKit** — full-screen document camera with edge detection and perspective correction.
- **On-device OCR** — Apple Vision (`VNRecognizeTextRequest`, accurate mode) with spatial row reconstruction so two-column receipts (label on the left, amount on the right) parse correctly.
- **Smart parser** for US receipts:
  - Merchant guessed from the first letter-rich line that contains no amount.
  - Date detected via `NSDataDetector`, prefers full timestamps and rejects garbage fragments like `6/2`.
  - Total picked by keyword priority (`Grand Total` → `Balance Due` → `Total Purchase` → … → `Total`), with ties broken by the larger amount and item-count lines like `Total 12 Items` filtered out.
  - Tax routed before total when both keywords appear; sums per-rate lines (`State Tax` + `County Tax` + `City Tax`) when no single "Total Tax" is printed.
  - Promo lines (`Savings`, `Discount`, `Coupon`, `Markdown`, `You Saved`) excluded from totals.
- **Confirm-before-save** editor — every parsed field is editable; the photo and recognized text are shown for reference.
- **Receipt list** with thumbnail, merchant, date, total, and tax; swipe-to-delete and Edit mode.
- **Detail view** — full image, parsed fields, recognized text. Long-press to copy any field, the image, or the entire OCR text. Toast confirms each copy.
- **Summary tab** — Weekly / Monthly / Yearly buckets with receipt count, total spent, and total tax.
- **Settings tab** — library stats, JSON backup export/import, and version info.
- **Local-only storage** with SwiftData. Images use `@Attribute(.externalStorage)` so they live as files on disk.
- **Performance** — 200pt JPEG thumbnails per receipt (~5–10 KB), async-decoded off the main thread, with a one-time launch backfill for older entries.

## Tech stack

- iOS 17+ (SwiftData, `@Observable` views, `.fileExporter`/`fileImporter`)
- SwiftUI
- VisionKit (`VNDocumentCameraViewController`)
- Vision (`VNRecognizeTextRequest`)
- `NSDataDetector` for date parsing

## Project structure

```
receipt-scanner/
├─ receipt-scanner/
│  ├─ receipt_scannerApp.swift   # @main, SwiftData ModelContainer
│  ├─ ContentView.swift          # all views, OCR, parser, backup
│  ├─ Item.swift                 # @Model Receipt
│  └─ Assets.xcassets/
└─ receipt-scanner.xcodeproj/
```

`ContentView.swift` is intentionally a single file: tabs, list, detail, editor, summary, settings, scanner, OCR, parser, and backup format all live there for easy navigation. Split into modules whenever it stops being convenient.

## Build & run

1. Open `receipt-scanner.xcodeproj` in Xcode 15 or later.
2. Select an iOS 17+ device. The document camera requires a real device (the simulator has no camera).
3. Run.

The Info.plist (set via `INFOPLIST_KEY_NSCameraUsageDescription` build settings) prompts for camera and photo library access on first scan.

## Backup format

Tap **Settings → Export Backup** to save a single JSON file you can store in iCloud Drive, Files, or AirDrop to another iPhone. **Import Backup** merges receipts from a backup; duplicates (matched by stable `uuid`) are skipped.

```jsonc
{
  "version": 1,
  "exportedAt": "2026-05-31T12:34:56Z",
  "receipts": [
    {
      "id": "…UUID…",
      "timestamp": "2026-04-26T15:55:00Z",
      "merchant": "TRADER JOE'S",
      "total": 31.81,
      "tax": 0.01,
      "note": "",
      "rawText": "TRADER JOE'S\n…",
      "imageBase64": "…optional JPEG…"
    }
  ]
}
```

## Limitations

- US receipts only (USD currency, US tax keywords, US date formats).
- No iCloud / CloudKit sync — that requires a paid Apple Developer account. Use Export/Import for cross-device transfer.
- Single-page scans only.
- Parser is heuristic; the editor lets you fix anything OCR or the parser gets wrong before saving.

## License

Personal project. No license granted — please ask before reusing.
