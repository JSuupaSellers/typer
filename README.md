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
