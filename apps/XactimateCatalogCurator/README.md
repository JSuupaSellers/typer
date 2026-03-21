# Xactimate Catalog Curator

This is the native macOS app for building your curated Xactimate backend.

It is designed around the workflow you described:

1. Import the Excel export and prep it into SQLite.
2. Do a fast yes/no pass over the line items.
3. Revisit only the used items and add voice-friendly usage notes for AI.
4. Batch-scan existing estimate photos to auto-mark CAT/SEL pairs that already appear in your written estimates.

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
- record audio locally in the app
- send the recording to OpenAI transcription
- clean the raw transcript into a structured usage note with an OpenAI model
- export the curated result to JSON for the later AI recommendation step

### Stage 4

- import many estimate photos at once
- send each photo through Gemini vision in a batch loop
- extract unique visible `CAT/SEL` pairs from each image
- auto-mark matching catalog items as `Used Before`
- review unmatched codes after the batch finishes

As of March 21, 2026, OpenAI's Whisper API model is `whisper-1`. If you want the literal Whisper path, use that model name. OpenAI also offers newer non-Whisper transcription models such as `gpt-4o-transcribe` and `gpt-4o-mini-transcribe`.

As of March 21, 2026, Google's Gemini 3 docs list model IDs such as `gemini-3-flash-preview`, `gemini-3.1-flash-lite-preview`, and `gemini-3.1-pro-preview`; there is not an official model ID literally named `gemini-3.0`. The estimate photo workflow now defaults to `gemini-3-flash-preview`, and the app converts imported photos to JPEG before upload so batches can include iPhone-style formats like HEIC without manual conversion.

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
