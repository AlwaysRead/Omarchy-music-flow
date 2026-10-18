#!/usr/bin/env python3
"""Run with dbus-run-session -- /usr/bin/python tests/playback-integration.py.

Uses private MPRIS fixtures and a separate Quickshell process. Never sends
commands to the desktop's players or session bus.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import gi
from gi.repository import Gio, GLib

ROOT = Path(__file__).resolve().parents[1]
XML = """<node>
<interface name="org.mpris.MediaPlayer2">
 <property name="Identity" type="s" access="read"/>
 <property name="DesktopEntry" type="s" access="read"/>
 <property name="CanQuit" type="b" access="read"/>
 <property name="CanRaise" type="b" access="read"/>
 <property name="HasTrackList" type="b" access="read"/>
 <property name="SupportedUriSchemes" type="as" access="read"/>
 <property name="SupportedMimeTypes" type="as" access="read"/>
</interface>
<interface name="org.mpris.MediaPlayer2.Player">
 <property name="PlaybackStatus" type="s" access="read"/>
 <property name="Metadata" type="a{sv}" access="read"/>
 <property name="Position" type="x" access="read"/>
 <property name="Rate" type="d" access="read"/>
 <property name="MinimumRate" type="d" access="read"/>
 <property name="MaximumRate" type="d" access="read"/>
 <property name="CanControl" type="b" access="read"/>
 <property name="CanPlay" type="b" access="read"/>
 <property name="CanPause" type="b" access="read"/>
 <property name="CanSeek" type="b" access="read"/>
 <property name="CanGoNext" type="b" access="read"/>
 <property name="CanGoPrevious" type="b" access="read"/>
 <method name="Play"/><method name="Pause"/><method name="PlayPause"/>
 <method name="SetPosition"><arg type="o" direction="in"/><arg type="x" direction="in"/></method>
 <signal name="Seeked"><arg type="x"/></signal>
</interface></node>"""
NODE = Gio.DBusNodeInfo.new_for_xml(XML)
PATH = "/org/mpris/MediaPlayer2"


class Player:
    def __init__(self, label):
        self.label, self.state, self.position = label, "Playing", 10_000_000
        self.commands = []
        self.connection = Gio.DBusConnection.new_for_address_sync(
            os.environ["DBUS_SESSION_BUS_ADDRESS"],
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        for interface in NODE.interfaces:
            self.connection.register_object(PATH, interface, self.method, self.get, None)
        self.connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "RequestName",
            GLib.Variant("(su)", ("org.mpris.MediaPlayer2.fixture" + label, 0)), None,
            Gio.DBusCallFlags.NONE, -1, None)

    def get(self, connection, sender, path, interface, prop):
        if prop in ("Identity", "DesktopEntry"):
            return GLib.Variant("s", "Fixture " + self.label)
        if prop == "PlaybackStatus":
            return GLib.Variant("s", self.state)
        if prop == "Metadata":
            return GLib.Variant("a{sv}", {
                "xesam:title": GLib.Variant("s", "Fixture track " + self.label),
                "xesam:artist": GLib.Variant("as", ["Fixture artist"]),
                "mpris:trackid": GLib.Variant("o", "/fixture/track"),
                "mpris:length": GLib.Variant("x", 180_000_000),
            })
        if prop == "Position":
            return GLib.Variant("x", self.position)
        if prop in ("Rate", "MinimumRate", "MaximumRate"):
            return GLib.Variant("d", 1.0)
        if prop.startswith("Supported"):
            return GLib.Variant("as", [])
        return GLib.Variant("b", prop.startswith("Can") and prop not in ("CanQuit", "CanRaise"))

    def set_state(self, state):
        self.state = state
        self.connection.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
            GLib.Variant("(sa{sv}as)", ("org.mpris.MediaPlayer2.Player",
                {"PlaybackStatus": GLib.Variant("s", state)}, [])))

    def method(self, connection, sender, path, interface, method, args, invocation):
        self.commands.append(method)
        if method == "Play":
            self.set_state("Playing")
        elif method == "Pause":
            self.set_state("Paused")
        elif method == "PlayPause":
            self.set_state("Paused" if self.state == "Playing" else "Playing")
        elif method == "SetPosition":
            self.position = args.unpack()[1]
            self.connection.emit_signal(None, PATH, interface, "Seeked", GLib.Variant("(x)", (self.position,)))
        invocation.return_value(None)

    def close(self):
        self.connection.close_sync(None)


QML = """import QtQuick
import Quickshell
import Quickshell.Services.Mpris
ShellRoot {
  id: root
  Service { id: media }
  readonly property var activePlayer: media.activePlayer
  readonly property bool isPlaying: media.isPlaying
  readonly property bool widgetVisible: __WIDGET_VISIBILITY__
  property bool seekTested: false
  property var seen: ({})
  Timer {
    interval: 50; running: true; repeat: true
    onTriggered: {
      var p = media.activePlayer
      var state = p ? MprisPlaybackState.toString(p.playbackState) : "none"
      var key = p ? p.identity + ":" + state.toLowerCase() : "none"
      seen[key] = true
      seen[key + ":visible"] = root.widgetVisible
      if (p && p.identity === "Fixture One" && p.canSeek && p.positionSupported && !root.seekTested) {
        p.position = 45
        root.seekTested = true
      }
    }
  }
  Timer {
    interval: 1300; running: true
    onTriggered: media.runAction("pause", false)
  }
  Timer {
    interval: 1600; running: true
    onTriggered: media.runAction("play", false)
  }
  Timer {
    interval: 8500; running: true
    onTriggered: {
      var required = ["none", "Fixture One:playing", "Fixture One:paused", "Fixture One:stopped", "Fixture Two:playing"]
      for (var i = 0; i < required.length; i++) {
        if (!seen[required[i]]) { console.error("FAIL missing transition", required[i], JSON.stringify(seen)); Qt.quit(); return }
      }
      if (media.activePlayer !== null) { console.error("FAIL closed players remain selected"); Qt.quit(); return }
      if (!seen["Fixture One:playing:visible"] || !seen["Fixture One:paused:visible"]
          || seen["Fixture One:stopped:visible"] || root.widgetVisible) {
        console.error("FAIL widget visibility", JSON.stringify(seen)); Qt.quit(); return
      }
      console.log("PASS playback transitions: playing, paused, stopped, multiple players, closed")
      Qt.quit()
    }
  }
}
"""


def main():
    fixtures = {}
    def at(milliseconds, action):
        def invoke():
            action()
            return False
        GLib.timeout_add(milliseconds, invoke)

    with tempfile.TemporaryDirectory(prefix="music-flow-playback-") as folder:
        target = Path(folder)
        for name in ("Service.qml", "MediaModel.js", "AudioSpectrum.js", "config"):
            source = ROOT / name
            if source.is_dir(): shutil.copytree(source, target / name)
            else: shutil.copy2(source, target / name)
        visibility = next(line.strip().removeprefix("visible: ") for line in
            (ROOT / "BarWidget.qml").read_text().splitlines() if line.startswith("  visible: Boolean(root.activePlayer"))
        (target / "shell.qml").write_text(QML.replace("__WIDGET_VISIBILITY__", visibility))
        env = {**os.environ, "QT_QPA_PLATFORM": "offscreen", "QT_NO_XDG_DESKTOP_PORTAL": "1", "NO_AT_BRIDGE": "1", "GIO_USE_VFS": "local", "XDG_CACHE_HOME": str(target / "cache")}
        with (target / "output.log").open("w+") as output:
            process = subprocess.Popen(["quickshell", "-p", str(target)], env=env, stdout=output, stderr=subprocess.STDOUT)
            at(800, lambda: fixtures.update(one=Player("One")))
            at(1800, lambda: fixtures["one"].set_state("Paused"))
            at(2800, lambda: fixtures["one"].set_state("Stopped"))
            at(3800, lambda: fixtures["one"].set_state("Playing"))
            at(4300, lambda: fixtures["one"].set_state("Paused"))
            at(4800, lambda: fixtures.update(two=Player("Two")))
            at(6000, lambda: fixtures["two"].close())
            at(7000, lambda: fixtures["one"].close())
            loop = GLib.MainLoop()
            def finished():
                if process.poll() is not None:
                    loop.quit()
                    return False
                return True
            GLib.timeout_add(100, finished)
            at(12000, lambda: (process.kill(), loop.quit()))
            loop.run()
            process.wait()
            output.seek(0)
            logs = output.read()
            print(logs)
            assert process.returncode == 0 and "PASS playback transitions" in logs
            assert "Binding loop detected" not in logs
            assert fixtures["one"].position == 45_000_000, "seek did not reach the target player"
            assert {"Play", "Pause"}.issubset(fixtures["one"].commands), "play/pause commands were not delivered"
            print("PASS visibility, targeted play/pause, and 45-second seek")


if __name__ == "__main__":
    main()
