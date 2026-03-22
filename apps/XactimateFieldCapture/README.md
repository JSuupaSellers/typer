# Xactimate Field Capture

This is the thin iPhone/iPad companion app for your backend workflow.

It is intentionally small:

1. Capture room notes with audio.
2. Select supporting photos.
3. Upload that media to your backend.
4. Review the planned CAT/SEL items returned by the producer service.
5. Publish only after you approve the plan.

## Backend requirements

The app expects the producer API to be running with these endpoints:

- `POST /capture/intake`
- `POST /plan`
- `POST /publish`

Point the app at the same backend URL you use for the producer service.

To transcribe recorded room notes on the backend, configure the producer with:

- `openai_api_key`
- `openai_base_url`
- `transcription_model`

The current flow uses backend transcription for audio and sends selected photos along with the draft request so the same backend can expand into photo analysis later.

## Generate the Xcode project

```bash
cd apps/XactimateFieldCapture
xcodegen generate
```

## Open and run

1. Open `apps/XactimateFieldCapture/XactimateFieldCapture.xcodeproj` in Xcode.
2. Choose an iPhone simulator or device.
3. Run the `XactimateFieldCapture` scheme.

## Verify

```bash
cd apps/XactimateFieldCapture
xcodegen generate
xcodebuild -project XactimateFieldCapture.xcodeproj -scheme XactimateFieldCapture -destination "generic/platform=iOS Simulator" build
xcodebuild -project XactimateFieldCapture.xcodeproj -scheme XactimateFieldCapture -destination "platform=iOS Simulator,name=iPhone 16,OS=18.1" CODE_SIGNING_ALLOWED=NO test
```
