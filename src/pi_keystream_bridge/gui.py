from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk

from serial.tools import list_ports

from .config import AppConfig
from .controller import BridgeController


class BridgeApp:
    def __init__(self, root: tk.Tk, config_path: Path) -> None:
        self._root = root
        self._config_path = config_path
        self._root.title("Pi Keystream Bridge")
        self._root.geometry("980x720")
        self._root.minsize(860, 620)

        self._config = self._load_config(config_path)
        self._controller = BridgeController(self._config)

        self._config_vars = {
            "firebase_credentials_path": tk.StringVar(value=self._config.firebase_credentials_path),
            "firebase_database_url": tk.StringVar(value=self._config.firebase_database_url),
            "firebase_commands_path": tk.StringVar(value=self._config.firebase_commands_path),
            "firebase_state_path": tk.StringVar(value=self._config.firebase_state_path),
            "serial_port": tk.StringVar(value=self._config.serial_port),
            "serial_baudrate": tk.StringVar(value=str(self._config.serial_baudrate)),
            "state_file": tk.StringVar(value=self._config.state_file),
        }
        self._status_vars = {
            "running": tk.StringVar(value="Stopped"),
            "firebase": tk.StringVar(value="Disconnected"),
            "serial": tk.StringVar(value="Disconnected"),
            "last_seq": tk.StringVar(value="0"),
            "queue": tk.StringVar(value="0"),
            "last_command": tk.StringVar(value="-"),
            "last_error": tk.StringVar(value="-"),
        }

        self._log_text: scrolledtext.ScrolledText | None = None
        self._build()
        self._refresh_ports()
        self._schedule_refresh()
        self._root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build(self) -> None:
        outer = ttk.Frame(self._root, padding=16)
        outer.pack(fill=tk.BOTH, expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(3, weight=1)

        file_frame = ttk.LabelFrame(outer, text="Config", padding=12)
        file_frame.grid(row=0, column=0, sticky="ew")
        file_frame.columnconfigure(1, weight=1)
        ttk.Label(file_frame, text="Config File").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self._config_path_var = tk.StringVar(value=str(self._config_path))
        ttk.Entry(file_frame, textvariable=self._config_path_var).grid(row=0, column=1, sticky="ew")
        ttk.Button(file_frame, text="Browse", command=self._browse_config).grid(row=0, column=2, padx=(8, 0))
        ttk.Button(file_frame, text="Load", command=self._load_from_ui).grid(row=0, column=3, padx=(8, 0))
        ttk.Button(file_frame, text="Save", command=self._save_from_ui).grid(row=0, column=4, padx=(8, 0))

        settings = ttk.LabelFrame(outer, text="Bridge Settings", padding=12)
        settings.grid(row=1, column=0, sticky="ew", pady=(12, 0))
        settings.columnconfigure(1, weight=1)
        settings.columnconfigure(3, weight=1)

        self._add_row(
            settings,
            0,
            "Firebase Credentials",
            "firebase_credentials_path",
            browse=self._browse_credentials,
        )
        self._add_row(settings, 1, "Database URL", "firebase_database_url")
        self._add_row(settings, 2, "Commands Path", "firebase_commands_path")
        self._add_row(settings, 3, "State Path", "firebase_state_path")
        self._add_row(
            settings,
            4,
            "Serial Port",
            "serial_port",
            control=self._build_port_selector(settings),
        )
        self._add_row(settings, 5, "Serial Baudrate", "serial_baudrate")
        self._add_row(settings, 6, "Local State File", "state_file")

        buttons = ttk.Frame(outer, padding=(0, 12, 0, 0))
        buttons.grid(row=2, column=0, sticky="ew")
        ttk.Button(buttons, text="Start Bridge", command=self._start_bridge).pack(side=tk.LEFT)
        ttk.Button(buttons, text="Stop Bridge", command=self._stop_bridge).pack(side=tk.LEFT, padx=(8, 0))

        monitor = ttk.PanedWindow(outer, orient=tk.VERTICAL)
        monitor.grid(row=3, column=0, sticky="nsew", pady=(12, 0))

        status_frame = ttk.LabelFrame(monitor, text="Status", padding=12)
        log_frame = ttk.LabelFrame(monitor, text="Log", padding=12)
        monitor.add(status_frame, weight=1)
        monitor.add(log_frame, weight=3)

        for column in range(2):
            status_frame.columnconfigure(column * 2 + 1, weight=1)

        self._status_label(status_frame, 0, 0, "Bridge", "running")
        self._status_label(status_frame, 1, 0, "Firebase", "firebase")
        self._status_label(status_frame, 2, 0, "Serial", "serial")
        self._status_label(status_frame, 0, 2, "Last Seq", "last_seq")
        self._status_label(status_frame, 1, 2, "Buffered", "queue")
        self._status_label(status_frame, 2, 2, "Last Command", "last_command")
        self._status_label(status_frame, 3, 0, "Last Error", "last_error")

        self._log_text = scrolledtext.ScrolledText(log_frame, wrap=tk.WORD, state=tk.DISABLED, font=("Menlo", 11))
        self._log_text.pack(fill=tk.BOTH, expand=True)

    def _build_port_selector(self, parent: ttk.Frame) -> ttk.Frame:
        frame = ttk.Frame(parent)
        combo = ttk.Combobox(frame, textvariable=self._config_vars["serial_port"])
        combo.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self._port_combo = combo
        ttk.Button(frame, text="Refresh", command=self._refresh_ports).pack(side=tk.LEFT, padx=(8, 0))
        return frame

    def _add_row(
        self,
        parent: ttk.Frame,
        row: int,
        label: str,
        key: str,
        browse: Callable[[], None] | None = None,
        control: ttk.Frame | None = None,
    ) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=5)
        if control is None:
            entry = ttk.Entry(parent, textvariable=self._config_vars[key])
            entry.grid(row=row, column=1, sticky="ew", pady=5)
        else:
            control.grid(row=row, column=1, sticky="ew", pady=5)
        if browse is not None:
            ttk.Button(parent, text="Browse", command=browse).grid(row=row, column=2, padx=(8, 0))

    def _status_label(self, parent: ttk.Frame, row: int, column: int, label: str, key: str) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=column, sticky="w", pady=4, padx=(0, 8))
        ttk.Label(parent, textvariable=self._status_vars[key]).grid(row=row, column=column + 1, sticky="w", pady=4)

    def _load_config(self, path: Path) -> AppConfig:
        if path.exists():
            return AppConfig.load(path)
        config = AppConfig().resolved(path.parent)
        config.save(path)
        return config

    def _schedule_refresh(self) -> None:
        self._refresh_status()
        self._root.after(self._config.ui_refresh_ms, self._schedule_refresh)

    def _refresh_status(self) -> None:
        snapshot = self._controller.snapshot()
        self._status_vars["running"].set("Running" if snapshot.running else "Stopped")
        self._status_vars["firebase"].set("Connected" if snapshot.firebase_connected else "Disconnected")
        self._status_vars["serial"].set("Connected" if snapshot.serial_connected else "Disconnected")
        self._status_vars["last_seq"].set(str(snapshot.last_applied_seq))
        self._status_vars["queue"].set(str(snapshot.buffered_commands))
        self._status_vars["last_command"].set(snapshot.last_command)
        self._status_vars["last_error"].set(snapshot.last_error or "-")
        if self._log_text is not None:
            new_text = self._controller.logs_text()
            current = self._log_text.get("1.0", tk.END).rstrip("\n")
            if new_text != current:
                self._log_text.configure(state=tk.NORMAL)
                self._log_text.delete("1.0", tk.END)
                self._log_text.insert("1.0", new_text)
                self._log_text.configure(state=tk.DISABLED)
                self._log_text.see(tk.END)

    def _collect_config(self) -> AppConfig:
        config = AppConfig(
            firebase_credentials_path=self._config_vars["firebase_credentials_path"].get().strip(),
            firebase_database_url=self._config_vars["firebase_database_url"].get().strip(),
            firebase_commands_path=self._config_vars["firebase_commands_path"].get().strip(),
            firebase_state_path=self._config_vars["firebase_state_path"].get().strip(),
            serial_port=self._config_vars["serial_port"].get().strip(),
            serial_baudrate=int(self._config_vars["serial_baudrate"].get().strip()),
            state_file=self._config_vars["state_file"].get().strip(),
            serial_write_timeout_s=self._config.serial_write_timeout_s,
            serial_reconnect_interval_s=self._config.serial_reconnect_interval_s,
            log_limit=self._config.log_limit,
            ui_refresh_ms=self._config.ui_refresh_ms,
            ack_debounce_ms=self._config.ack_debounce_ms,
        )
        return config.resolved(Path(self._config_path_var.get().strip()).parent)

    def _start_bridge(self) -> None:
        try:
            self._config = self._collect_config()
            self._controller.stop()
            self._controller = BridgeController(self._config)
            self._controller.start()
        except Exception as exc:
            messagebox.showerror("Bridge Start Failed", str(exc))

    def _stop_bridge(self) -> None:
        self._controller.stop()

    def _save_from_ui(self) -> None:
        try:
            self._config = self._collect_config()
            self._config_path = Path(self._config_path_var.get().strip()).expanduser().resolve()
            self._config.save(self._config_path)
            messagebox.showinfo("Saved", f"Config saved to {self._config_path}")
        except Exception as exc:
            messagebox.showerror("Save Failed", str(exc))

    def _load_from_ui(self) -> None:
        try:
            path = Path(self._config_path_var.get().strip()).expanduser().resolve()
            self._config = self._load_config(path)
            self._config_path = path
            self._controller.stop()
            self._controller = BridgeController(self._config)
            self._config_vars["firebase_credentials_path"].set(self._config.firebase_credentials_path)
            self._config_vars["firebase_database_url"].set(self._config.firebase_database_url)
            self._config_vars["firebase_commands_path"].set(self._config.firebase_commands_path)
            self._config_vars["firebase_state_path"].set(self._config.firebase_state_path)
            self._config_vars["serial_port"].set(self._config.serial_port)
            self._config_vars["serial_baudrate"].set(str(self._config.serial_baudrate))
            self._config_vars["state_file"].set(self._config.state_file)
        except Exception as exc:
            messagebox.showerror("Load Failed", str(exc))

    def _browse_config(self) -> None:
        selected = filedialog.askopenfilename(initialdir=str(self._config_path.parent), title="Select config file")
        if selected:
            self._config_path_var.set(selected)

    def _browse_credentials(self) -> None:
        selected = filedialog.askopenfilename(title="Select Firebase service account JSON")
        if selected:
            self._config_vars["firebase_credentials_path"].set(selected)

    def _refresh_ports(self) -> None:
        ports = sorted(port.device for port in list_ports.comports())
        self._port_combo["values"] = ports
        if not self._config_vars["serial_port"].get() and ports:
            self._config_vars["serial_port"].set(ports[0])

    def _on_close(self) -> None:
        self._controller.stop()
        self._root.destroy()


def run_gui(config_path: Path) -> None:
    root = tk.Tk()
    BridgeApp(root, config_path)
    root.mainloop()
