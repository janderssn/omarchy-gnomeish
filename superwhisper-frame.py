#!/usr/bin/env python3
"""Points Superwhisper's recording glow at a rectangle.

Superwhisper's indicator outlines Hyprland's active window. While a program
owns com.superwhisper.ShellOverlay on the session bus and publishes a Frame
(output name, x, y, width, height), it outlines that rectangle instead.
Gnomeish runs this while the overview is open, with the overview's monitor
as the rectangle, so the glow surrounds the overview rather than a window
hidden behind it.

Reads lines "output x y width height" on stdin; each one replaces the frame.
Exits, releasing the name, when stdin closes.
"""
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "com.superwhisper.ShellOverlay"
PATH = "/com/superwhisper/ShellOverlay"
XML = """<node>
  <interface name="com.superwhisper.ShellOverlay">
    <property name="Frame" type="(siiii)" access="read"/>
  </interface>
</node>"""

loop = GLib.MainLoop()
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
frame = None
owned = False


def get_property(connection, sender, path, interface, prop):
    if prop == "Frame" and frame:
        return GLib.Variant("(siiii)", frame)
    return None


def publish():
    if not frame:
        return
    bus.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    GLib.Variant("(sa{sv}as)", (NAME, {"Frame": GLib.Variant("(siiii)", frame)}, [])))


def own_or_publish():
    # The name is taken only once there is a frame to read, so the indicator
    # never finds the name without one.
    global owned
    if owned:
        publish()
        return
    owned = True
    Gio.bus_own_name_on_connection(bus, NAME, Gio.BusNameOwnerFlags.NONE, None, lambda *a: loop.quit())


def read_line(channel, condition):
    global frame
    # A last line can arrive together with the hangup; read before quitting.
    if not condition & GLib.IO_IN:
        loop.quit()
        return False
    line = channel.readline()
    if not line:
        loop.quit()
        return False
    parts = line.split()
    if len(parts) == 5:
        try:
            x, y, w, h = (int(round(float(v))) for v in parts[1:])
        except ValueError:
            return True
        if w > 0 and h > 0 and (parts[0], x, y, w, h) != frame:
            frame = (parts[0], x, y, w, h)
            own_or_publish()
    return True


info = Gio.DBusNodeInfo.new_for_xml(XML)
bus.register_object(PATH, info.interfaces[0], None, get_property, None)

stdin = GLib.IOChannel.unix_new(sys.stdin.fileno())
GLib.io_add_watch(stdin, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, read_line)
loop.run()
