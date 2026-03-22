# Xactimate Field Capture

This is the thin iPhone/iPad companion app for your backend workflow.

It is intentionally small:

1. Open a persistent claim draft by job ID.
2. Add room notes through text or recorded voice turns.
3. Let the backend draft agent evolve the claim room by room.
4. Review grouped sections like `Ceiling`, `Walls`, and `Floors`.
5. Accept or reject items before plan and publish.

## Backend requirements

The app expects the producer API to be running with these endpoints:

- `POST /drafts/open`
- `GET /drafts/{job_id}`
- `POST /drafts/{job_id}/chat`
- `POST /drafts/{job_id}/voice-turn`
- `POST /drafts/{job_id}/items/{item_id}/status`
- `POST /drafts/{job_id}/accept-all`
- `POST /drafts/{job_id}/plan`
- `POST /drafts/{job_id}/publish`

Point the app at the same backend URL you use for the producer service.

To run the room draft workflow on the backend, configure the producer with:

- `openai_api_key`
- `openai_base_url`
- `transcription_model`
- `agent_model`
- `draft_storage_dir`

The current app is chat-first. Voice turns are recorded locally, transcribed on the backend, and then passed into the same draft agent that handles typed messages.

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
