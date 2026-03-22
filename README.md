# Pi Keystream Bridge

This project contains the Raspberry Pi side bridge for your workflow:

1. Your main machine writes ordered keyboard commands into Firebase Realtime Database.
2. The Raspberry Pi listens live for those commands.
3. The Pi forwards them over USB serial to a Teensy 4.0.
4. The Teensy emits the actual USB keyboard events into the locked-down work laptop.

The Pi handles timing locally, so slow Xactimate screens can be paced with explicit delay commands and per-command post delays.

## Why this design

- Firebase Realtime Database gives you a simple low-latency queue source.
- The Pi keeps commands ordered by `seq`, even if events arrive out of order.
- The serial path is isolated in a dedicated worker thread so the UI never blocks.
- Delay commands are applied on the Pi instead of the Teensy, which keeps the USB side simpler.
- Tkinter is included with Python and stays light enough for Raspberry Pi deployments.

The native macOS curator app lives separately under `apps/XactimateCatalogCurator`.

Open [apps/XactimateCatalogCurator/README.md](/Users/joshuasellers/Documents/Development/App/Typer/apps/XactimateCatalogCurator/README.md) for the Mac app workflow and run instructions.

## Runtime Search API

Once you have curated your working set in the macOS app, export the catalog JSON and build a separate runtime database for the cloud agent to query. This keeps the Swift app as a one-time authoring tool and moves production lookup into a lightweight API service.

### Build the runtime database

```bash
python -m xactimate_catalog_runtime import \
  --export /path/to/xactimate-curated-export.json \
  --db runtime/catalog.sqlite
```

### Serve the runtime API

```bash
python -m xactimate_catalog_runtime serve \
  --db runtime/catalog.sqlite \
  --host 0.0.0.0 \
  --port 8787 \
  --api-key your-secret-key
```

You can also use the console script:

```bash
xactimate-runtime serve --db runtime/catalog.sqlite --port 8787
```

### Query it directly

```bash
python -m xactimate_catalog_runtime search \
  --db runtime/catalog.sqlite \
  --query "2x2 ceiling patch that needs picture frame and paint" \
  --room "Living room" \
  --surface "Ceiling" \
  --damage-type "Patch" \
  --keywords "picture frame"
```

### API endpoints

- `GET /health`: item and scenario counts for the loaded runtime database
- `GET /items/{code}`: item details plus saved usage scenarios for a CAT/SEL code like `DRY/PCH`
- `GET /items/{code}/scenarios`: scenarios only for a specific code
- `POST /search`: freeform search over the curated catalog
- `POST /recommend`: same ranking path, intended for AI-agent recommendation calls

Example request body for `POST /recommend`:

```json
{
  "query": "2x2 ceiling patch that needs picture frame and then ceiling painted",
  "room": "Living room",
  "surface": "Ceiling",
  "damage_type": "Patch",
  "keywords": "picture frame",
  "limit": 5
}
```

This service is where your cloud agent should search the curated catalog. Firebase remains only for the final execution queue that the Raspberry Pi bridge consumes.

## Producer Service

The producer sits between the cloud agent and Firebase:

1. It sends each scope item to the runtime API for CAT/SEL recommendations.
2. It auto-approves only when the top candidate meets the configured confidence threshold, or when you supply an explicit `approved_code`.
3. It compiles approved items into deterministic keyboard commands using a versioned Xactimate workflow profile.
4. It reserves the next command sequence range in Firebase state and appends the job to the queue for the Raspberry Pi bridge.

### Producer config

Start from [producer.example.json](/Users/joshuasellers/Documents/Development/App/Typer/producer.example.json):

```bash
cp producer.example.json producer.local.json
```

Fill in:

- `runtime_api_base_url`
- `runtime_api_key` if your runtime search API requires one
- `openai_api_key` if you want the producer to run the chat draft agent and transcribe uploaded field audio
- `transcription_model` if you want to override the default `gpt-4o-transcribe`
- `agent_model` if you want a different OpenAI orchestrator model than the default `gpt-5.4`
- `draft_storage_dir` for persisted room-by-room claim drafts
- `firebase_credentials_path`
- `firebase_database_url`
- `firebase_commands_path_template`
- `firebase_state_path_template`

The workflow profile is intentionally data-driven so you can tune the exact `F9`, `F6`, `TAB`, `ENTER`, and delay choreography without changing the producer code.

### Estimate job payload

Start from [estimate-job.example.json](/Users/joshuasellers/Documents/Development/App/Typer/estimate-job.example.json):

```json
{
  "job_id": "claim-1024-living-room",
  "bridge_id": "default",
  "items": [
    {
      "item_id": "scope-1",
      "description": "2x2 ceiling patch that needs picture frame and then ceiling painted",
      "room": "Living room",
      "surface": "Ceiling",
      "damage_type": "Patch",
      "keywords": "picture frame",
      "quantity": 1
    }
  ]
}
```

Optional per-item safety controls:

- `approved_code`: bypass runtime search and use a known CAT/SEL
- `allow_auto_approve`: set to `false` to force a review step
- `min_confidence`: override the producer default of `high`

### Plan a job

```bash
python -m xactimate_producer --config producer.local.json plan \
  --job estimate-job.example.json
```

This resolves every scope item against the runtime API and shows whether each item is:

- `approved`
- `needs_review`
- `unresolved`

### Compile a preview

```bash
python -m xactimate_producer --config producer.local.json compile \
  --job estimate-job.example.json \
  --starting-seq 1
```

This returns the exact Firebase command objects that would be queued for the Pi bridge.

### Publish to Firebase

```bash
python -m xactimate_producer --config producer.local.json publish \
  --job estimate-job.example.json
```

Publish behavior:

- sequence numbers are reserved under the bridge state before writing commands
- new jobs append after the highest applied or reserved sequence
- the producer does not reset the queue back to `1`, so the Pi bridge stays in sync
- if any scope item still needs review, publish fails with a review plan instead of guessing

### Serve the producer as an API

```bash
python -m xactimate_producer --config producer.local.json serve --port 8790
```

Endpoints:

- `GET /health`
- `POST /capture/intake`
- `POST /drafts/open`
- `GET /drafts/{job_id}`
- `POST /drafts/{job_id}/chat`
- `POST /drafts/{job_id}/voice-turn`
- `POST /drafts/{job_id}/items/{item_id}/status`
- `POST /drafts/{job_id}/accept-all`
- `POST /drafts/{job_id}/plan`
- `POST /drafts/{job_id}/publish`
- `POST /plan`
- `POST /compile`
- `POST /publish`

`POST /drafts/*` is the new room-by-room claim workflow for the mobile app:

- open a persistent draft job
- send text turns or voice turns
- let the backend orchestrator search the curated catalog
- review accepted vs rejected line items grouped by room and section
- plan or publish the accepted draft to the Pi pipeline

When the draft is converted into an execution job, the producer automatically inserts section note rows ahead of each room section and compiles them through the `note_item` profile. That is where `Ceiling`, `Walls`, `Floors`, and similar separators become `F9` note entries for Xactimate.

`POST /capture/intake` still exists as a lower-level helper and accepts multipart form data with:

- estimate metadata like `job_id`, `bridge_id`, `room`, `surface`, `damage_type`, `keywords`, and `quantity`
- optional `description` text
- optional `audio` for OpenAI transcription on the backend
- optional repeated `photos`

Example:

```bash
curl -X POST http://127.0.0.1:8790/capture/intake \
  -H "X-API-Key: your-producer-key" \
  -F "job_id=claim-1024-living-room" \
  -F "bridge_id=default" \
  -F "room=Living room" \
  -F "surface=Ceiling" \
  -F "damage_type=Patch" \
  -F "keywords=picture frame" \
  -F "quantity=1" \
  -F "description=2x2 ceiling patch that needs picture frame and then ceiling painted" \
  -F "audio=@room-note.m4a"
```

The response includes a draft estimate job payload you can send to `POST /plan` and then `POST /publish`.

This is the service your cloud agent or mobile capture app should call once it has a transcript or other structured room description ready.

## iPhone Field App

The thin capture app lives under [apps/XactimateFieldCapture/README.md](/Users/joshuasellers/Documents/Development/App/Typer/apps/XactimateFieldCapture/README.md).

Use it when you want a field-friendly front end for:

- room-by-room chat turns
- backend voice transcription
- grouped review by room and section
- accept/reject control before plan and publish

The app is intentionally light. Your backend still holds the OpenAI key, runs the draft agent and producer API, and decides when a plan is safe to publish.

## OpenAI MCP Server

If you want this to plug into OpenAI tool calling cleanly, use the MCP server instead of calling the runtime and producer REST APIs directly.

Start it like this:

```bash
xactimate-openai-mcp \
  --runtime-db runtime/catalog.sqlite \
  --producer-config producer.local.json \
  --host 0.0.0.0 \
  --port 8000
```

By default it serves Streamable HTTP at `/mcp` and SSE at `/sse`.

Exposed tools:

- `search_line_items`
- `get_line_item`
- `plan_estimate_job`
- `compile_estimate_job`
- `publish_estimate_job`

The publish tool is intentionally guarded and requires `confirm_publish=true` before it will write anything to Firebase.

Example OpenAI Responses API tool configuration:

```python
from openai import OpenAI

client = OpenAI()

response = client.responses.create(
    model="gpt-5.4",
    tools=[
        {
            "type": "mcp",
            "server_label": "xactimate",
            "server_url": "https://your-public-host.example.com/mcp",
            "require_approval": "never",
        }
    ],
    input="Plan an estimate for a 2x2 ceiling patch, compile it, and stop before publishing."
)
```

Recommended tool flow for OpenAI:

1. `search_line_items`
2. `get_line_item` if the model needs more scenario detail
3. `plan_estimate_job`
4. `compile_estimate_job`
5. `publish_estimate_job` only after explicit user approval

This lets OpenAI use the curated catalog, deterministic compiler, and Firebase publisher as one remote tool surface.

## Command contract

The producer should write immutable commands under the configured `firebase_commands_path`.

Example database shape:

```json
{
  "bridges": {
    "default": {
      "commands": {
        "1": { "seq": 1, "kind": "key", "key": "F6", "delay_after_ms": 250 },
        "2": { "seq": 2, "kind": "text", "text": "Drywall repair", "delay_after_ms": 80 },
        "3": { "seq": 3, "kind": "combo", "key": "TAB", "modifiers": ["SHIFT"], "delay_after_ms": 120 },
        "4": { "seq": 4, "kind": "delay", "duration_ms": 500 }
      },
      "state": {
        "last_applied_seq": 4
      }
    }
  }
}
```

Supported command kinds:

- `key`: single key action, ex. `{"seq": 5, "kind": "key", "key": "ENTER"}`
- `combo`: key plus modifiers, ex. `{"seq": 6, "kind": "combo", "key": "S", "modifiers": ["CTRL"]}`
- `text`: literal text payload for the Teensy firmware, ex. `{"seq": 7, "kind": "text", "text": "Line item"}`
- `delay`: local wait on the Pi, ex. `{"seq": 8, "kind": "delay", "duration_ms": 450}`

Optional fields:

- `delay_after_ms`: local wait after any non-delay command
- `repeat`: forwarded to the Teensy payload
- extra keys are preserved under `payload` in the serial JSON line

## Serial protocol to the Teensy

Every non-delay command is emitted as one JSON line over serial:

```json
{"seq":2,"type":"text","repeat":1,"text":"Drywall repair"}
```

That lets you keep the Teensy firmware very small:

- read one line
- parse JSON
- perform the requested key or text action

## Local setup

### 1. Install dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -e .
```

### 2. Create a config

```bash
cp config.example.json config.local.json
```

Update:

- `firebase_credentials_path`
- `firebase_database_url`
- `firebase_commands_path`
- `firebase_state_path`
- `serial_port`

### 3. Run the GUI

```bash
python -m pi_keystream_bridge.cli --config config.local.json gui
```

### 4. Run headless

```bash
python -m pi_keystream_bridge.cli --config config.local.json daemon
```

## Raspberry Pi deployment

On the Raspberry Pi:

```bash
sudo apt update
sudo apt install -y git python3-venv python3-tk
git clone <your-repo-url> pi-keystream-bridge
cd pi-keystream-bridge
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -e .
cp config.example.json config.local.json
```

Then either:

- run `python -m pi_keystream_bridge.cli --config config.local.json gui`
- or install the sample systemd unit from [deploy/pi-keybridge.service](/Users/joshuasellers/Documents/Development/App/Typer/deploy/pi-keybridge.service)

## Notes for the producer

- Commands must be immutable after they are written. If you update child fields later, the Pi intentionally ignores partial patches.
- Keep `seq` contiguous so the Pi can enforce ordering.
- Use `delay` and `delay_after_ms` generously for Xactimate screens.
- Once your producer sees `last_applied_seq` advance, it can safely prune older commands.

## Verification

Run the built-in tests:

```bash
python -m unittest discover -s tests
```
