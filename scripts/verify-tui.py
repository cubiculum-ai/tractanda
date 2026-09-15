#!/usr/bin/env python3
"""Exercise the actual terminal client through a PTY and independent native wire client.

Only disposable stores, terminal descriptors and recovery files are used. No GUI
terminal application or user's open shell is controlled. Python 3.9+, no packages.
"""
import argparse
import codecs
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time
import uuid

spec = importlib.util.spec_from_file_location("wire", Path(__file__).with_name("verify-ipc.py"))
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)
ESC = b"\x1b"
CONTROL_SEQUENCE = re.compile(
    r"\x1b\](?:[^\x07\x1b]|\x1b(?!\\))*(?:\x07|\x1b\\)"
    r"|\x1bP(?:[^\x1b]|\x1b(?!\\))*\x1b\\"
    r"|\x1b\[[0-?]*[ -/]*[@-~]"
)


def plain_terminal_text(value):
    return CONTROL_SEQUENCE.sub("", value).replace("\r", "")


class Terminal:
    def __init__(self, binary, path, recovery, arguments=None, environment=None, items_only=True,
                 terminal_replies=None):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.raw = ""
        self.terminal_replies = terminal_replies or {}
        self.answered_queries = set()
        self.decoder = codecs.getincrementaldecoder("utf-8")()
        self.width, self.height = 80, 25
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 25, 80, 0, 0))
        locale = "C.UTF-8" if platform.system() == "Linux" else "en_US.UTF-8"
        environment = {**os.environ, **(environment or {}), "TERM": "xterm-256color", "LANG": locale, "LC_ALL": locale}
        arguments = [str(path)] if arguments is None else arguments
        if items_only and "--items" not in arguments:
            arguments = [*arguments, "--items"]
        if recovery is not None and "--appearance-file" not in arguments:
            arguments = [*arguments, "--appearance-file", str(Path(recovery).with_suffix(".appearance.json"))]
        if recovery is not None:
            arguments = [*arguments, "--recovery-file", str(recovery)]
        self.process = subprocess.Popen([binary, *arguments],
            stdin=self.slave, stdout=self.slave, stderr=self.slave, env=environment, start_new_session=True)

    def read(self, timeout=0.05):
        if select.select([self.master], [], [], timeout)[0]:
            data = os.read(self.master, 65536)
            self.raw += self.decoder.decode(data)
            # Optional fake terminal responses exercise the same raw input path as
            # real xterm/iTerm replies, including queries split across PTY reads.
            for query, response in self.terminal_replies.items():
                for match in re.finditer(re.escape(query), self.raw):
                    token = (query, match.start())
                    if token not in self.answered_queries:
                        self.answered_queries.add(token)
                        self.send(response)

    @property
    def screen(self):
        frame = self.raw.rsplit("\x1b[H", 1)[-1]
        return plain_terminal_text(frame)

    @property
    def is_frame_complete(self):
        frame = self.raw.rsplit("\x1b[H", 1)[-1]
        before, ending, suffix = frame.rpartition("\x1b[0m\x1b[K")
        # Cursor position/visibility can follow a complete frame or move without
        # changing any frame text. Do not mistake a partial escape for completion.
        return (bool(ending) and before.count("\r\n") == self.height - 1
                and CONTROL_SEQUENCE.sub("", suffix) == "")

    @property
    def cursor(self):
        """Last explicit cursor position and style, interpreted from real output."""
        state = {"row": 1, "column": 1, "visible": True, "shape": None, "color": None}
        for match in CONTROL_SEQUENCE.finditer(self.raw):
            sequence = match[0]
            position = re.fullmatch(r"\x1b\[(\d*);?(\d*)H", sequence)
            shape = re.fullmatch(r"\x1b\[(\d+) q", sequence)
            color = re.fullmatch(r"\x1b\]12;(.+?)(?:\x07|\x1b\\)", sequence)
            if position:
                state.update(row=int(position[1] or 1), column=int(position[2] or 1))
            elif shape:
                state["shape"] = int(shape[1])
            elif color and color[1] != "?":
                state["color"] = color[1]
            elif sequence in ("\x1b]112\x07", "\x1b]112\x1b\\"):
                state["color"] = "default"
            elif sequence == "\x1b[?25h":
                state["visible"] = True
            elif sequence == "\x1b[?25l":
                state["visible"] = False
        return state

    def settle(self, duration=0.2):
        """Drain bounded cursor-only output after a key without waiting for new text."""
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            self.read(min(0.03, max(0, deadline - time.monotonic())))
        return self.screen

    def wait(self, text, *, absent=None):
        deadline = time.monotonic() + 10
        while text not in self.screen or (absent and absent in self.screen) or not self.is_frame_complete:
            self.read()
            assert self.process.poll() is None, (self.process.returncode, self.raw[-6000:])
            assert time.monotonic() < deadline, (text, self.screen)
        # A Darwin PTY can deliver one redraw in several short reads. Wait for the
        # last row's reset/erase sequence, not just a marker near the screen top.
        return self.screen

    def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        os.write(self.master, data)

    def paste(self, text):
        self.send(ESC + b"[200~" + text.encode() + ESC + b"[201~")

    def resize(self, columns, rows):
        self.width, self.height = columns, rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        os.kill(self.process.pid, signal.SIGWINCH)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            self.read(0.05)
            if self.is_frame_complete:
                return
        raise AssertionError((columns, rows, self.screen))

    def close(self, termination=None):
        if termination:
            self.process.send_signal(termination)
        else:
            # In the focused Views selector ordinary letters are literal search text;
            # Ctrl-Q is the global explicit quit command in every terminal context.
            self.send(b"\x11")
        # Keep consuming output while the child restores the screen. A wide redraw can
        # fill the PTY buffer; waiting without reading would deadlock the test itself.
        deadline = time.monotonic() + 10
        while self.process.poll() is None:
            self.read(0.05)
            if time.monotonic() >= deadline:
                raise AssertionError(("Terminal did not exit", self.screen))
        self.process.wait(timeout=1)
        while select.select([self.master], [], [], 0.1)[0]:
            self.read(0)
        assert self.process.returncode == 0, self.raw[-4000:]
        restored = termios.tcgetattr(self.slave)
        expected = list(self.original)
        if platform.system() == "Darwin":
            # Darwin sets PENDIN when ICANON is re-enabled, requesting kernel input
            # reprocessing. Compare all user modes/speeds/control bytes, excluding
            # only that kernel-maintained pending-input flag.
            restored[3] &= ~termios.PENDIN
            expected[3] &= ~termios.PENDIN
        assert restored == expected, ("Terminal modes were not restored", expected, restored)
        assert "\x1b[?2004l" in self.raw and "\x1b[?1049l" in self.raw and "\x1b[?25h" in self.raw
        os.close(self.master); os.close(self.slave)


@contextlib.contextmanager
def terminal(binary, path, recovery, arguments=None, environment=None, items_only=True, terminal_replies=None):
    session = Terminal(binary, path, recovery, arguments=arguments, environment=environment,
                       items_only=items_only, terminal_replies=terminal_replies)
    try:
        yield session
    finally:
        if session.process.poll() is None:
            session.close(signal.SIGTERM)


def query(client, expression):
    return client.call("TractandaItem/query", {"expression": expression})["ids"]


def wait_item(client, expression, terminal=None):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        ids = query(client, expression)
        if ids:
            return client.get(ids[0])
        # Consume redraws while polling the independent client. Otherwise a full
        # PTY output buffer can block the TUI before it processes the save key.
        if terminal is None:
            time.sleep(0.03)
        else:
            terminal.read(0.03)
    raise AssertionError(expression)


def choose(session, command, name, heading):
    session.send(command); session.wait(heading)
    session.send(b"\x15")
    session.paste(name); session.wait(name)
    # Category-manager Enter only focuses its retained Categories report.  The
    # explicit Meta-Return command applies that category path in Views.  Other
    # pickers (notably assignments) retain their ordinary Enter semantics.
    session.send(ESC + b"\r" if heading == "Category manager" else b"\r")


class LostResponseProxy:
    def __init__(self, source, target, drop_method="TractandaItem/commit"):
        self.path = source; self.target = target
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(source)); self.listener.listen(8); self.listener.settimeout(0.1)
        os.chmod(source, 0o600)
        self.stopping = False; self.drop_commit = True; self.error = None
        self.drop_method = drop_method
        self.thread = threading.Thread(target=self.run, daemon=True); self.thread.start()

    def run(self):
        try:
            while not self.stopping:
                try:
                    connection, _ = self.listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(10)
                    length = struct.unpack("!I", wire.read_exact(connection, 4))[0]
                    request = json.loads(wire.read_exact(connection, length))
                    response = wire.wire(self.target, request)
                    if self.drop_commit and request["methodCalls"][0][0] == self.drop_method:
                        self.drop_commit = False
                        continue
                    data = json.dumps(response).encode()
                    connection.sendall(struct.pack("!I", len(data)) + data)
        except Exception as error:
            if not self.stopping:
                self.error = repr(error)

    def close(self):
        self.stopping = True; self.thread.join(timeout=12)
        self.listener.close(); self.path.unlink()
        assert self.error is None, self.error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_binary", type=Path)
    parser.add_argument("tui_binary", type=Path)
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    binary, tui = str(options.native_binary.resolve()), str(options.tui_binary.resolve())
    checks = []; snapshots = []
    with tempfile.TemporaryDirectory(prefix="trac-tui-", dir="/tmp") as directory:
        root = Path(directory); path = root / "s"; recovery = root / "recovery" / "pending.json"
        with wire.server(binary, root / "store", path) as client:
            with terminal(tui, path, recovery) as ui:
                ui.wait("No items")
                assert termios.tcgetattr(ui.slave) != ui.original
                ui.send("c"); ui.wait("Category manager")
                ui.send(ESC + b"n"); ui.wait("New category")
                ui.paste("TUI Family"); ui.send(b"\x13"); ui.wait("Saved one revision")
                category = wait_item(client, 'subject == "TUI Family"', ui)
                ui.wait("Category manager")
                ui.send(ESC + b"[20~"); ui.wait("Views workspace")
                # This legacy capture workflow applies the category explicitly in
                # Views; category-manager Enter itself remains retained above.
                choose(ui, "c", "TUI Family", "Category manager"); ui.wait("Added category filter")
                ui.send("n"); ui.wait("New item")
                ui.paste("Family café 文"); ui.send(b"\t")
                body = "A Unicode note: 👩🏽‍💻\nSecond line stays intact after resizing."
                ui.paste(body); ui.wait("Second line")
                for width, height in [(132, 40), (52, 14), (30, 8), (160, 48), (80, 25)]:
                    ui.resize(width, height)
                    if width < 48:
                        ui.wait("Enlarge terminal"); ui.send("SHOULD NOT EDIT")
                    else:
                        ui.wait("Body / note")
                        assert "Second line" in ui.screen
                    snapshots.append({"name": "draft", "columns": width, "rows": height, "screen": ui.screen})
                ui.send(b"\x13"); ui.wait("Saved one revision")
                item = wait_item(client, 'subject == "Family café 文"', ui)
                identity = wire.item_id(item)
                assert item["fields"]["body"] == wire.text(body)
                assert item["fields"]["categoryOverrides"]["value"][wire.item_id(category)] == wire.text("include")
                assert client.call("TractandaItem/history", {"itemID": identity})["total"] == 1
                checks.append("PTY capture and Unicode multiline editing; live resize through 132x40, 52x14, 30x8, 160x48 and 80x25 preserves focus, draft and one whole edit")

                ui.resize(132, 40); ui.wait("Preview")
                snapshots.append({"name": "browse-wide", "columns": 132, "rows": 40, "screen": ui.screen})
                ui.resize(80, 25); ui.wait("Preview")
                ui.send(ESC + b"OQ"); ui.wait("Edit item")
                ui.send(" revised"); ui.send(b"\x13")
                item = wait_item(client, 'subject == "Family café 文 revised"', ui)
                assert wire.item_id(item) == identity
                assert client.call("TractandaItem/history", {"itemID": identity})["total"] == 2
                choose(ui, "w", "TUI Family", "Explain category")
                ui.wait("Included: manual include"); ui.send(ESC); ui.wait("Preview")
                ui.send("h"); ui.wait("History · newest first"); ui.send(b"\r")
                ui.wait(wire.revision_id(item)); ui.send(ESC); ui.wait("Preview")
                ui.send("s"); ui.wait("Save view as"); ui.paste("Family saved view"); ui.send(b"\x13")
                view = wait_item(client, 'subject == "Family saved view"', ui)
                assert client.call("TractandaItem/query", {"viewID": wire.item_id(view)})["ids"] == [identity]
                ui.send("a"); ui.wait("All readable items")
                choose(ui, "v", "Family saved view", "Open saved view"); ui.wait("Family saved view")
                choose(ui, "x", "TUI Family", "Exclude item"); ui.wait("No items.")
                assert client.call("TractandaItem/query", {"viewID": wire.item_id(view)})["ids"] == []
                ui.send("a"); ui.wait("All readable items")
                ui.send("f"); ui.wait("Filter items"); ui.send(b"\x15")
                ui.paste('subject == "Family café 文 revised"'); ui.send(b"\x13"); ui.wait("Filter applied")
                choose(ui, "u", "TUI Family", "Reset shared decision")
                deadline = time.monotonic() + 8
                while wire.item_id(category) in client.get(identity)["fields"]["categoryOverrides"]["value"]:
                    assert time.monotonic() < deadline; ui.read()
                checks.append("Category-name selection, explicit include/exclude/reset and server explanation; saved view selection, native filtering, F2 edit and immutable history")

                ui.send("e"); ui.wait("Edit item"); ui.send(" stale draft")
                before = client.get(identity)
                external = client.commit(wire.intent("revise", "outside-edit", identity, wire.revision_id(before), changes={"body": wire.text("External revision")}))["revision"]
                ui.send(b"\x13"); ui.wait("revisionConflict")
                ui.resize(120, 35); ui.wait("stale draft")
                assert wire.revision_id(client.get(identity)) == wire.revision_id(external)
                assert not recovery.exists()
                ui.send(ESC); ui.wait("Draft canceled")
                ui.send("r"); ui.wait("Refreshed")
                assert "External revision" in ui.screen
                checks.append("Concurrent edit rejected without overwrite; stale draft survives resizing; cancel and refresh recover the current item")

                ui.send("?"); ui.wait("Tractanda help"); ui.resize(60, 16); ui.wait("Tractanda help")
                ui.send(ESC); ui.wait("A All")
                ui.send("/"); ui.wait("Command menu"); ui.send(ESC); ui.wait("A All", absent="Command menu")
                ui.close()
                checks.append("Help/menu cancellation and normal exit restore original termios, cursor and main screen")

            proxy = LostResponseProxy(root / "proxy", path)
            try:
                with terminal(tui, proxy.path, root / "retry" / "pending.json") as ui:
                    ui.wait("Preview"); ui.send("n"); ui.wait("New item")
                    ui.paste("Lost response item"); ui.send(b"\x13"); ui.wait("Unconfirmed edit")
                    lost = wait_item(client, 'subject == "Lost response item"', ui)
                    saved_request = json.loads((root / "retry/pending.json").read_text())["request"]
                    ui.resize(120, 35); ui.wait("Unconfirmed edit"); ui.close()
                with terminal(tui, proxy.path, root / "retry" / "pending.json") as ui:
                    ui.wait("Recovered unconfirmed edit")
                    assert client.call("TractandaItem/history", {"itemID": wire.item_id(lost)})["total"] == 1
                    assert json.loads((root / "retry/pending.json").read_text())["request"] == saved_request
                    ui.send("r"); ui.wait("Recovered saved edit")
                    assert not (root / "retry/pending.json").exists()
                    assert client.call("TractandaItem/history", {"itemID": wire.item_id(lost)})["total"] == 1
                    ui.send("n"); ui.wait("New item"); ui.paste("Unsaved signal test")
                    ui.resize(100, 30); ui.close(signal.SIGTERM)
                checks.append("Actual lost native response, preserved request across TUI restart, explicit idempotent retry with one revision, and SIGTERM terminal restoration")
            finally:
                proxy.close()

            # Default journals use a temporary state root here. The first window retains the
            # historical primary slot; the second gets a deterministic alternate. After that
            # second window loses its reply and exits, the next default launch discovers the
            # alternate pending operation before selecting an empty primary journal.
            pooled_state = root / "pooled-recovery"
            pooled_environment = {"TRACTANDA_TUI_STATE_DIR": str(pooled_state)}
            proxy = LostResponseProxy(root / "pooled-proxy", path)
            try:
                with terminal(tui, proxy.path, None, environment=pooled_environment) as holder:
                    holder.wait("Preview")
                    with terminal(tui, proxy.path, None, environment=pooled_environment) as alternate:
                        alternate.wait("Preview")
                        alternate.send("n"); alternate.wait("New item")
                        alternate.paste("Pooled recovery item"); alternate.send(b"\x13")
                        alternate.wait("Unconfirmed edit")
                        journal_name = str(proxy.path).encode().hex()
                        primary = pooled_state / (journal_name + ".json")
                        alternate_journal = pooled_state / (journal_name + ".slot-1.json")
                        assert primary.with_suffix(".json.lock").exists()
                        assert alternate_journal.exists()
                        alternate.close(signal.SIGTERM)
                    holder.close()
                with terminal(tui, proxy.path, None, environment=pooled_environment) as recovered:
                    recovered.wait("Recovered unconfirmed edit")
                    recovered.send("r"); recovered.wait("Recovered saved edit")
                    assert not alternate_journal.exists()
                    recovered.close()
                checks.append("Two simultaneous default PTY windows use locked primary and alternate journals; an orphaned alternate pending edit is offered for explicit exact retry on the next default launch")
            finally:
                proxy.close()

    report = {"status": "passed", "platform": platform.platform(), "checks": checks, "snapshots": snapshots}
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"status": report["status"], "platform": report["platform"], "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
