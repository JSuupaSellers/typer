# Xactimate Catalog Curator

This is the native macOS app for building your curated Xactimate backend.

It is designed around the workflow you described:

1. Import the Excel export and prep it into SQLite.
2. Do a fast yes/no pass over the line items.
3. Revisit only the used items and add voice-friendly usage notes for AI.

## Current workflow

### Stage 1

- import the workbook you shared
- detect the first worksheet and the expected columns
- load the rows into SQLite under your macOS Application Support folder

The importer is currently tuned for this workbook shape:

- `CAT`
- `SEL`
- `Discription`
- `QTY Type`
- `Details`

### Stage 2

- review one line item at a time
- `Space`: mark `Used Before`
- `N`: mark `Never Used`
- `S`: skip for now

### Stage 3

- browse only the items marked `Used Before`
- create one or more usage notes per item
- use native text fields so macOS Dictation works naturally
- export the curated result to JSON for the later AI recommendation step

## Open and run

### In Xcode

1. Open `apps/XactimateCatalogCurator/Package.swift` in Xcode.
2. Select the `XactimateCatalogCurator` scheme.
3. Run the app.

### From Terminal

```bash
cd apps/XactimateCatalogCurator
swift run
```

## Verify

```bash
cd apps/XactimateCatalogCurator
swift build
swift test
```
