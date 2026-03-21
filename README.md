# Pi Keystream Bridge

This project is a Raspberry Pi side bridge for your workflow:

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
