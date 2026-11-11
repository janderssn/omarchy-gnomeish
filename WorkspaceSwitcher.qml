import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Workspace Switcher: a GNOME-style Activities overview for Omarchy.
//  - Workspaces as large cards with live window previews, current one centered.
//  - Left/Right, scroll wheel / touchpad, or swipe to move between workspaces;
//    Enter or click to go there; click a window to focus it.
//  - Start typing to search apps; arrows move, Enter launches.
//  - Esc clears the search, then closes.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "janderssn.workspace-switcher"
  readonly property var appLibrary: shell ? shell.appLibrary : null

  property bool opened: false
  property string query: ""
  // Whitespace alone is not a search (e.g. a stray Space from Super+Space).
  readonly property bool searching: query.trim().length > 0
  property int wsIndex: 0
  property int appIndex: 0
  property var workspaces: []
  property string workspacesSignature: ""
  property int autoSelectedId: -1
  property var apps: []

  // Focused monitor geometry in logical pixels.
  property real monX: 0
  property real monY: 0
  property real monW: 1440
  property real monH: 900
  // Space the bar reserves on the monitor: left, top, right, bottom.
  property var reserved: [0, 0, 0, 0]
  readonly property rect barRect: {
    var r = reserved
    if (r[1] > 0) return Qt.rect(0, 0, monW, r[1])
    if (r[3] > 0) return Qt.rect(0, monH - r[3], monW, r[3])
    if (r[0] > 0) return Qt.rect(0, 0, r[0], monH)
    if (r[2] > 0) return Qt.rect(monW - r[2], 0, r[2], monH)
    return Qt.rect(0, 0, 0, 0)
  }

  // Everything follows the theme: its accent (the colour Hyprland draws
  // around the active window), foreground for text and tints, background for
  // the dim over the wallpaper.
  readonly property color accent: Commons.Color.accent
  readonly property color textColor: Commons.Color.foreground
  readonly property color baseColor: Commons.Color.background
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int radius: Math.max(10, Style.cornerRadius)

  function tint(alpha) {
    return Qt.rgba(textColor.r, textColor.g, textColor.b, alpha)
  }

  // ---------------------------------------------------------------- settings
  // Optional, from an [workspace-switcher] section in ~/.config/omarchy/shell.toml:
  //   animate = "auto" | "always" | "never"   (auto follows `omarchy toggle animations`)
  //   dim     = 0.5                           (darkening of the wallpaper, 0 to 1)
  //   bar     = "fade" | "keep"               (fade the bar away, or leave it showing and usable)
  function setting(key, fallback) {
    var values = Commons.Color.shellValues
    var value = values ? values["workspace-switcher." + key] : undefined
    return typeof value === "string" && value.length > 0 ? value : fallback
  }

  readonly property string animateMode: String(setting("animate", "auto")).toLowerCase()
  readonly property bool keepBar: String(setting("bar", "fade")).toLowerCase() === "keep"
    && barRect.width > 0 && barRect.height > 0
  // What the overview draws on and takes clicks in: the whole monitor, or
  // everything but the bar when it is kept. Leaving the bar's strip of the
  // overlay undrawn lets the real bar show through.
  readonly property rect stageRect: {
    if (!keepBar) return Qt.rect(0, 0, monW, monH)
    var r = reserved
    if (r[1] > 0) return Qt.rect(0, r[1], monW, monH - r[1])
    if (r[3] > 0) return Qt.rect(0, 0, monW, monH - r[3])
    if (r[0] > 0) return Qt.rect(r[0], 0, monW - r[0], monH)
    return Qt.rect(0, 0, monW - r[2], monH)
  }
  readonly property real backdropDim: {
    var n = Number(setting("dim", "0.5"))
    return isFinite(n) ? Math.max(0, Math.min(1, n)) : 0.5
  }

  function duration(ms) {
    if (animateMode === "always") return ms
    if (animateMode === "never") return 0
    return Style.duration(ms)
  }

  // Hyprland's window borders, drawn on the previews while they still fill
  // the screen so the first and last frames match the desktop.
  property real borderSize: 0
  property color activeBorder: accent
  property color inactiveBorder: "transparent"

  function hyprColor(option) {
    // "ff7aa2f7 0deg" (AARRGGBB, first gradient stop) -> "#ff7aa2f7"
    var token = String((option && (option.gradient || option.custom || option.str)) || "").trim().split(/\s+/)[0]
    return /^[0-9a-fA-F]{8}$/.test(token) ? "#" + token : ""
  }

  Process {
    id: borderOptions
    command: ["hyprctl", "-j", "--batch",
      "getoption general:border_size ; getoption general:col.active_border ; getoption general:col.inactive_border"]
    stdout: StdioCollector {
      onStreamFinished: {
        var chunks = String(text || "").split(/\n\s*\n/)
        for (var i = 0; i < chunks.length; i++) {
          var option = null
          try { option = JSON.parse(chunks[i]) } catch (e) { continue }
          if (!option || !option.option) continue
          if (option.option === "general:border_size") root.borderSize = Number(option.int || 0)
          else if (option.option === "general:col.active_border") {
            var active = root.hyprColor(option)
            if (active) root.activeBorder = active
          } else if (option.option === "general:col.inactive_border") {
            var inactive = root.hyprColor(option)
            if (inactive) root.inactiveBorder = inactive
          }
        }
      }
    }
  }


  // GNOME-style zoom. progress 0 = the current workspace fills the screen
  // exactly as it does outside the overview; 1 = the overview at rest.
  //
  // The overlay surface maps transparent, so nothing may be drawn until the
  // zoom can start from a frame that matches the desktop: the live previews
  // of the current workspace's windows, laid exactly over the real ones, and
  // a one-off capture of the screen ("shot") standing in for the bar, which
  // stays put and fades while the windows shrink.
  property real progress: 0
  property bool armed: false            // overview content is being drawn
  property bool shotWanted: false       // screen capture in use for the bar
  property bool waitForCaptures: false  // hold the zoom until captures land
  property bool closing: false
  property bool closeViaShell: false

  onOpenedChanged: {
    zoomAnim.stop()
    armTimeout.stop()
    progress = 0
    armed = false
    closing = false
    shotWanted = opened && !keepBar && barRect.width > 0 && barRect.height > 0
    waitForCaptures = opened
    if (opened) failsafe.restart()
    else failsafe.stop()
  }

  // Whatever happens to the captures or the reveal, the overview must not
  // stay invisible while it holds the keyboard.
  Timer {
    id: failsafe
    interval: 500
    onTriggered: {
      if (!root.opened || root.armed) return
      var shot = shotLoader.item
      if (!(shot && shot.hasContent)) root.shotWanted = false
      root.waitForCaptures = false
      root.armed = true
      zoomAnim.from = 0
      zoomAnim.to = 1
      zoomAnim.duration = root.duration(260)
      zoomAnim.start()
    }
  }

  NumberAnimation {
    id: zoomAnim
    target: root
    property: "progress"
    easing.type: Easing.OutCubic
    onFinished: {
      if (!root.closing) return
      if (root.closeViaShell) root.dismiss()
      else root.opened = false
    }
  }

  function tryArm() {
    // contentRevealed comes from the shell's OverlayWindow; a shell without
    // it is treated as revealed.
    if (!root.opened || root.armed || panel.contentRevealed === false) return
    if (root.waitForCaptures) {
      var shot = shotLoader.item
      if (root.shotWanted && !(shot && shot.hasContent)) return
      var card = strip.currentItem
      if (!card || !card.previewsReady()) return
    }
    root.armed = true
    zoomAnim.from = 0
    zoomAnim.to = 1
    zoomAnim.duration = root.duration(260)
    zoomAnim.start()
  }

  // Captures that do not arrive in time are not waited for. A late screen
  // capture would show the overview itself, so it is dropped.
  Timer {
    id: armTimeout
    interval: 150
    onTriggered: {
      if (root.armed) return
      var shot = shotLoader.item
      if (!(shot && shot.hasContent)) root.shotWanted = false
      root.waitForCaptures = false
      root.tryArm()
    }
  }

  Connections {
    target: panel
    function onContentRevealedChanged() {
      if (!panel.contentRevealed) return
      armTimeout.restart()
      root.tryArm()
    }
  }

  // Grow the selected workspace back to full screen, then hide. Only when it
  // is the workspace that will be showing; otherwise hide at once.
  function zoomOut(viaShell) {
    var ws = root.workspaces[root.wsIndex]
    if (!root.armed || root.searching || !ws || ws.id !== root.activeWorkspaceId()) {
      if (viaShell) root.dismiss()
      else root.opened = false
      return
    }
    if (root.closing) return
    root.closing = true
    root.closeViaShell = viaShell
    zoomAnim.stop()
    zoomAnim.from = root.progress
    zoomAnim.to = 0
    zoomAnim.duration = root.duration(150)
    zoomAnim.start()
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------------------------------------------------------------- wallpaper
  // Resolved once at startup and kept decoded, so the backdrop is there on the
  // first frame of every open. Re-resolved on each open (off the open path) so
  // a wallpaper change is picked up; only a changed path reloads the image.
  // Decoded at the monitor's pixel size, like the desktop background, so the
  // backdrop is indistinguishable from the real wallpaper when the zoom starts.
  property string wallpaperPath: ""
  property int wallpaperPxW: 0
  property int wallpaperPxH: 0
  readonly property string wallpaperSource: wallpaperPath && wallpaperPxW > 0 ? "file://" + wallpaperPath : ""

  Process {
    id: wallpaperResolver
    command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path && path !== root.wallpaperPath) root.wallpaperPath = path
      }
    }
  }

  Component.onCompleted: {
    wallpaperResolver.running = true
    borderOptions.running = true
    root.rebuildWorkspaces()
  }

  // ---------------------------------------------------------------- state

  function open(payloadJson) {
    if (!wallpaperResolver.running) wallpaperResolver.running = true
    if (!borderOptions.running) borderOptions.running = true
    root.query = ""
    root.apps = []
    root.appIndex = 0
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
    root.rebuildWorkspaces()
    root.opened = true
    // Hyprland answers the refreshes asynchronously; rebuild once they land.
    refreshTimer.restart()
    if (root.appLibrary) root.appLibrary.refreshIcons()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The shell calls close() both when the plugin dismisses itself and when the
  // Super-tap binding toggles it shut. Only the Super close commits the
  // workspace picked in the overview (GNOME-style); Esc / background click /
  // launching an app go through dismiss() and leave the workspace alone.
  property bool dismissing: false

  function close() {
    if (root.closing) return
    var commit = root.opened && !root.dismissing && !root.searching
    var ws = root.workspaces[root.wsIndex]
    if (!commit || !ws) { root.opened = false; return }
    // Super-tap close: switch first, hide once the new workspace is showing.
    root.switchThenHide([root.focusWorkspaceExpr(ws.id)], ws.id, false)
  }

  function dismiss() {
    root.dismissing = true
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    root.dismissing = false
  }

  // ---------------------------------------------------------------- switching
  // Switching runs before the overlay hides, so the old workspace never shows
  // through. Dispatches go over Quickshell's own Hyprland socket (no process
  // spawn); the overlay stays up until Hyprland reports the target workspace
  // active, with a short timeout as a safety net.
  property int pendingWorkspace: -1
  property bool pendingViaShell: false

  function focusWorkspaceExpr(id) {
    return "hl.dsp.focus({ workspace = \"" + id + "\" })"
  }

  function activeWorkspaceId() {
    var monitor = Hyprland.focusedMonitor
    return monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
  }

  function switchThenHide(expressions, targetId, viaShell) {
    for (var i = 0; i < expressions.length; i++) Hyprland.dispatch(expressions[i])
    if (targetId < 1 || targetId === root.activeWorkspaceId()) {
      root.finishSwitch(viaShell)
      return
    }
    root.pendingWorkspace = targetId
    root.pendingViaShell = viaShell
    switchTimeout.restart()
  }

  function finishSwitch(viaShell) {
    switchTimeout.stop()
    root.pendingWorkspace = -1
    root.zoomOut(viaShell)
  }

  Timer {
    id: switchTimeout
    interval: 250
    onTriggered: if (root.pendingWorkspace > 0) root.finishSwitch(root.pendingViaShell)
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() {
      if (root.pendingWorkspace > 0 && root.activeWorkspaceId() === root.pendingWorkspace)
        Qt.callLater(function() { root.finishSwitch(root.pendingViaShell) })
    }
  }

  function toggle() {
    if (root.opened) root.zoomOut(true)
    else root.open("{}")
  }

  Timer {
    id: refreshTimer
    interval: 80
    onTriggered: root.rebuildWorkspaces()
  }

  function rebuildWorkspaces() {
    var monitor = Hyprland.focusedMonitor
    if (monitor) {
      var ipc = monitor.lastIpcObject || {}
      var scale = Number(ipc.scale || monitor.scale || 1)
      root.monX = Number(ipc.x || 0)
      root.monY = Number(ipc.y || 0)
      root.monW = Number(ipc.width || monitor.width || 1440) / scale
      root.monH = Number(ipc.height || monitor.height || 900) / scale
      if (ipc.transform === 1 || ipc.transform === 3) {
        var t = root.monW; root.monW = root.monH; root.monH = t
      }
      var res = ipc.reserved
      if (res && res.length === 4) root.reserved = [Number(res[0]), Number(res[1]), Number(res[2]), Number(res[3])]
      root.wallpaperPxW = Math.round(root.monW * scale)
      root.wallpaperPxH = Math.round(root.monH * scale)
    }

    var activeId = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
    var byId = {}
    var list = []
    var values = Hyprland.workspaces.values || []
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!ws || ws.id < 1) continue
      if (monitor && ws.monitor && ws.monitor !== monitor) continue
      byId[ws.id] = { id: ws.id, name: String(ws.name || ws.id), windows: [] }
      list.push(byId[ws.id])
    }
    if (!byId[activeId] && activeId >= 1) {
      byId[activeId] = { id: activeId, name: String(activeId), windows: [] }
      list.push(byId[activeId])
    }

    var toplevels = Hyprland.toplevels.values || []
    for (var j = 0; j < toplevels.length; j++) {
      var tl = toplevels[j]
      var w = tl.workspace
      if (!w || !byId[w.id]) continue
      var info = tl.lastIpcObject || {}
      if (!info.at || !info.size || info.hidden) continue
      byId[w.id].windows.push({
        address: String(tl.address || info.address || ""),
        toplevel: tl.wayland || null,
        title: String(tl.title || info.title || ""),
        x: Number(info.at[0]) - root.monX,
        y: Number(info.at[1]) - root.monY,
        w: Number(info.size[0]),
        h: Number(info.size[1]),
        // Lower focusHistoryID is more recent; draw recent windows last (on top).
        order: Number(info.focusHistoryID === undefined ? 0 : info.focusHistoryID),
        focused: info.focusHistoryID === 0
      })
    }

    list.sort(function(a, b) { return a.id - b.id })
    for (var k = 0; k < list.length; k++) {
      list[k].windows.sort(function(a, b) { return b.order - a.order })
    }

    // GNOME keeps one empty workspace at the end to drop into.
    // Its id must be free on every monitor, or going there would jump to
    // another monitor's workspace.
    var last = list.length > 0 ? list[list.length - 1] : null
    if (!last || last.windows.length > 0) {
      var used = {}
      for (var u = 0; u < values.length; u++) if (values[u]) used[values[u].id] = true
      var spareId = last ? last.id + 1 : 1
      while (used[spareId]) spareId++
      list.push({ id: spareId, name: "", windows: [], spare: true })
    }

    var previousId = root.workspaces.length > 0 && root.wsIndex < root.workspaces.length
      ? root.workspaces[root.wsIndex].id : -1
    // Replacing the model rebuilds every card and restarts its captures, so
    // only do it when something actually changed.
    var signature = JSON.stringify(list.map(function(ws) {
      return [ws.id, ws.name, ws.windows.map(function(w) { return [w.address, !!w.toplevel, w.x, w.y, w.w, w.h, w.order] })]
    }))
    if (signature !== root.workspacesSignature) {
      root.workspacesSignature = signature
      root.workspaces = list
    }

    // Keep the user's pick across a refresh; a selection they never moved
    // follows the active workspace (Hyprland's state can lag on the first open).
    var keep = root.opened && previousId > 0 && previousId !== root.autoSelectedId
    var want = keep ? previousId : activeId
    if (!keep) root.autoSelectedId = activeId
    var index = 0
    for (var n = 0; n < list.length; n++) if (list[n].id === want) index = n
    root.wsIndex = index
  }

  function selectWorkspace(delta) {
    if (root.workspaces.length === 0) return
    root.wsIndex = Math.max(0, Math.min(root.workspaces.length - 1, root.wsIndex + delta))
  }

  function activateWorkspace(index) {
    var ws = root.workspaces[index]
    if (!ws) return
    root.switchThenHide([root.focusWorkspaceExpr(ws.id)], ws.id, true)
  }

  function focusWindow(address) {
    if (!address) return
    if (address.indexOf("0x") !== 0) address = "0x" + address
    var target = "window = \"address:" + address + "\""
    var ws = root.workspaces[root.wsIndex]
    root.switchThenHide([
      "hl.dsp.focus({ " + target + " })",
      "hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })"
    ], ws ? ws.id : -1, true)
  }

  // ---------------------------------------------------------------- search

  function setQuery(next) {
    root.query = next
    root.appIndex = 0
    root.rebuildApps()
  }

  function rebuildApps() {
    var q = root.query.trim()
    if (!q) { root.apps = []; return }
    var out = []
    if (root.appLibrary) {
      var rows = root.appLibrary.sortedEntries(q)
      for (var i = 0; i < rows.length && out.length < 24; i++) {
        var entry = rows[i].entry
        if (!entry || !entry.id) continue
        out.push({
          id: String(entry.id),
          name: root.appLibrary.entryName(entry) || String(entry.name || entry.id),
          icon: root.appLibrary.iconSource(entry.icon)
        })
      }
    } else {
      var values = DesktopEntries.applications.values || []
      var lower = q.toLowerCase()
      for (var j = 0; j < values.length && out.length < 24; j++) {
        var e = values[j]
        if (e.noDisplay || String(e.name).toLowerCase().indexOf(lower) < 0) continue
        out.push({ id: String(e.id), name: String(e.name), icon: Quickshell.iconPath(e.icon, true) })
      }
    }
    root.apps = out
  }

  // Apps installed after the shell started only get icons once the app
  // library rescans; redraw the results when it does (or when apps change).
  Connections {
    target: root.appLibrary
    ignoreUnknownSignals: true
    function onIconIndexChanged() { if (root.opened && root.searching) root.rebuildApps() }
    function onAppsChanged() { if (root.opened && root.searching) root.rebuildApps() }
  }

  function moveApp(delta) {
    if (root.apps.length === 0) return
    root.appIndex = Math.max(0, Math.min(root.apps.length - 1, root.appIndex + delta))
  }

  function launchApp(index) {
    var app = root.apps[index]
    if (!app) return
    root.dismiss()
    if (root.appLibrary) root.appLibrary.launch(app.id, app.name)
    else Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(app.id + ".desktop"))
  }

  // ---------------------------------------------------------------- window

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "workspace-switcher"

    // With the bar kept, clicks on it go to the bar.
    mask: root.keepBar ? stageRegion : null
    Region {
      id: stageRegion
      x: root.stageRect.x
      y: root.stageRect.y
      width: root.stageRect.width
      height: root.stageRect.height
    }

    // GNOME-style backdrop: the current wallpaper, sharp and dimmed. The dim
    // fades in with the zoom, so the first frame matches the desktop. It is
    // clipped to the stage, which leaves a kept bar uncovered.
    Item {
      x: root.stageRect.x
      y: root.stageRect.y
      width: root.stageRect.width
      height: root.stageRect.height
      clip: true
      visible: root.armed

      Item {
        x: -root.stageRect.x
        y: -root.stageRect.y
        width: panel.width
        height: panel.height

        Rectangle {
          anchors.fill: parent
          color: root.baseColor
        }

        Image {
          id: wallpaper
          anchors.fill: parent
          // Always loaded (the plugin is keepLoaded) and cached: no decode
          // work happens when the overview opens.
          source: root.wallpaperSource
          sourceSize.width: root.wallpaperPxW
          sourceSize.height: root.wallpaperPxH
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
        }

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, root.backdropDim * root.progress)
        }
      }
    }

    // Clicking empty space closes, like GNOME.
    MouseArea {
      anchors.fill: parent
      onClicked: root.zoomOut(true)
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.closing) { event.accepted = true; return }
        var key = Util.readingKey(event)
        if (event.key === Qt.Key_Escape) {
          if (root.query) root.setQuery("")
          else root.zoomOut(true)
          event.accepted = true
        } else if (Util.editsFilter(event, root.query)) {
          root.setQuery(Util.editedFilter(event, root.query))
          event.accepted = true
        } else if (key === Qt.Key_Left) {
          if (root.searching) root.moveApp(-1)
          else root.selectWorkspace(-1)
          event.accepted = true
        } else if (key === Qt.Key_Right) {
          if (root.searching) root.moveApp(1)
          else root.selectWorkspace(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          if (root.searching) root.moveApp(-appGrid.columns)
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          if (root.searching) root.moveApp(appGrid.columns)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          var step = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1
          if (root.searching) root.moveApp(step)
          else root.selectWorkspace(step)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (root.searching) root.launchApp(root.appIndex)
          else root.activateWorkspace(root.wsIndex)
          event.accepted = true
        } else if (event.text === " " && !root.searching) {
          event.accepted = true
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
          root.setQuery(root.query + event.text)
          event.accepted = true
        }
      }
    }

    // ---------------------------------------------------- search field

    Rectangle {
      id: searchBox
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Math.round(parent.height * 0.06) + root.stageRect.y
      width: Math.min(Style.space(560), parent.width * 0.7)
      height: Style.space(46)
      radius: height / 2
      opacity: root.progress
      color: root.tint(root.searching ? 0.16 : 0.10)
      border.width: root.searching ? 2 : 0
      border.color: root.accent

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Text {
        textFormat: Text.PlainText
        anchors.fill: parent
        anchors.leftMargin: Style.space(22)
        anchors.rightMargin: Style.space(22)
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: root.searching ? Text.AlignLeft : Text.AlignHCenter
        text: root.searching ? root.query : strings.t("search")
        color: root.textColor
        opacity: root.searching ? 1 : 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        elide: Text.ElideLeft
      }
    }

    // ---------------------------------------------------- workspaces

    ListView {
      id: strip
      visible: !root.searching
      // The zoom: at progress 0 the current card covers the screen exactly,
      // window for window; at 1 the strip sits at rest.
      readonly property real fullZoom: panel.width / Math.max(1, cardWidth)
      readonly property real zoom: 1 + (fullZoom - 1) * (1 - root.progress)
      readonly property real restCenterY: y + cardHeight / 2
      transform: [
        Scale { origin.x: strip.width / 2; origin.y: strip.cardHeight / 2; xScale: strip.zoom; yScale: strip.zoom },
        Translate { y: (panel.height / 2 - strip.restCenterY) * (1 - root.progress) }
      ]
      orientation: ListView.Horizontal
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: Math.round(parent.height * 0.03)
      height: cardHeight + Style.space(24)
      spacing: Style.space(36)
      clip: false
      model: root.opened ? root.workspaces : []
      // wsIndex drives the strip one way. A model reset puts ListView back at
      // index 0 (even when the count is unchanged), so re-snap on every reset
      // and never copy currentIndex back except after the user swipes.
      onCountChanged: snapToSelection()
      onModelChanged: Qt.callLater(strip.snapToSelection)
      // ListView can settle on an index of its own after a reset or when the
      // cards get their real size as the window maps; only a swipe by the
      // user may move the selection away from wsIndex.
      onCardWidthChanged: Qt.callLater(strip.snapToSelection)
      onCurrentIndexChanged: {
        if (moving || dragging || currentIndex === root.wsIndex) return
        Qt.callLater(function() {
          if (!strip.moving && !strip.dragging && strip.currentIndex !== root.wsIndex) strip.snapToSelection()
        })
      }
      onMovementEnded: if (currentIndex >= 0 && currentIndex !== root.wsIndex) root.wsIndex = currentIndex

      // Opening jumps straight to the current workspace; only moves made
      // inside the overview slide.
      property bool snapping: false
      function snapToSelection() {
        if (count === 0) return
        snapping = true
        currentIndex = root.wsIndex
        positionViewAtIndex(root.wsIndex, ListView.Center)
        Qt.callLater(function() { strip.snapping = false })
      }

      Connections {
        target: root
        function onWsIndexChanged() {
          if (strip.currentIndex !== root.wsIndex) strip.currentIndex = root.wsIndex
        }
        function onOpenedChanged() {
          if (root.opened) Qt.callLater(strip.snapToSelection)
        }
      }
      highlightRangeMode: ListView.StrictlyEnforceRange
      preferredHighlightBegin: (width - cardWidth) / 2
      preferredHighlightEnd: (width + cardWidth) / 2
      highlightMoveDuration: snapping ? 0 : root.duration(220)
      boundsBehavior: Flickable.StopAtBounds

      readonly property real cardWidth: {
        var byWidth = width * 0.62
        var byHeight = (panel.height * 0.62) * root.monW / Math.max(1, root.monH)
        return Math.max(Style.space(200), Math.min(byWidth, byHeight))
      }
      readonly property real cardHeight: cardWidth * root.monH / Math.max(1, root.monW)


      delegate: Item {
        id: card
        required property int index
        required property var modelData
        function previewsReady() {
          for (var i = 0; i < winRepeater.count; i++) {
            var item = winRepeater.itemAt(i)
            if (!item || !item.ready) return false
          }
          return true
        }
        readonly property bool current: index === root.wsIndex
        readonly property real sc: strip.cardWidth / Math.max(1, root.monW)

        width: strip.cardWidth
        height: strip.cardHeight + Style.space(24)
        opacity: current ? 1 : 0.55
        scale: current ? 1 : 0.9
        Behavior on opacity { NumberAnimation { duration: root.duration(160); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: root.duration(160); easing.type: Easing.OutCubic } }

        Rectangle {
          id: frame
          width: strip.cardWidth
          height: strip.cardHeight
          // Square, clear and borderless while it fills the screen.
          radius: root.radius * root.progress
          color: root.tint(0.06 * root.progress)
          border.width: card.current ? 2 : 1
          border.color: card.current
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.progress)
            : root.tint(0.12)
          clip: true

          MouseArea {
            anchors.fill: parent
            onClicked: {
              if (card.current) root.activateWorkspace(card.index)
              else root.wsIndex = card.index
            }
          }

          Repeater {
            id: winRepeater
            model: card.modelData.windows
            delegate: Item {
              id: win
              required property var modelData
              readonly property bool ready: preview.hasContent || !modelData.toplevel
              onReadyChanged: if (ready) root.tryArm()
              x: modelData.x * card.sc
              y: modelData.y * card.sc
              width: Math.max(8, modelData.w * card.sc)
              height: Math.max(8, modelData.h * card.sc)

              Rectangle {
                anchors.fill: parent
                radius: Math.max(4, root.radius / 2)
                color: root.tint(0.08)
                visible: !preview.hasContent
                opacity: root.progress

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  width: parent.width - 8
                  horizontalAlignment: Text.AlignHCenter
                  text: win.modelData.title
                  color: root.textColor
                  opacity: 0.7
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              ScreencopyView {
                id: preview
                anchors.fill: parent
                captureSource: root.opened ? win.modelData.toplevel : null
                live: root.opened && card.current
              }

              // The window's Hyprland border, there while the workspace fills
              // the screen and gone by the time it is a card.
              Rectangle {
                readonly property real size: root.borderSize * card.sc
                visible: card.current && root.borderSize > 0 && root.progress < 1
                anchors.fill: parent
                anchors.margins: -size
                color: "transparent"
                radius: (Style.cornerRadius + root.borderSize) * card.sc
                border.width: size
                border.color: win.modelData.focused ? root.activeBorder : root.inactiveBorder
                opacity: 1 - root.progress
              }

              MouseArea {
                id: winMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (card.current) root.focusWindow(win.modelData.address)
                  else root.wsIndex = card.index
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: card.modelData.windows.length === 0
            text: card.modelData.spare ? strings.t("newWorkspace") : strings.t("emptyWorkspace")
            color: root.textColor
            opacity: 0.45 * root.progress
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }

        // Workspace number under the card.
        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: frame.horizontalCenter
          anchors.top: frame.bottom
          anchors.topMargin: Style.space(6)
          text: card.modelData.spare ? "+" : String(card.modelData.name)
          color: root.textColor
          opacity: card.current ? 0.9 : 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: card.current
        }
      }
    }

    // The bar does not shrink with the workspace: a capture of the screen
    // taken as the overview opened, clipped to the bar, stays in place and
    // fades out (and back in on close).
    Item {
      x: root.barRect.x
      y: root.barRect.y
      width: root.barRect.width
      height: root.barRect.height
      clip: true
      opacity: 1 - root.progress

      Loader {
        id: shotLoader
        active: root.opened && root.shotWanted
        x: -root.barRect.x
        y: -root.barRect.y
        width: panel.width
        height: panel.height
        sourceComponent: ScreencopyView {
          captureSource: panel.screen
          live: false
          onHasContentChanged: root.tryArm()
        }
      }
    }

    // Wheel / touchpad scrolling over the strip. Sits above the ListView so the
    // Flickable never sees wheel events (it would nudge, then snap back).
    // Accepts no buttons, so clicks, hover and touchscreen swipes pass through.
    MouseArea {
      id: wheelCatcher
      visible: strip.visible
      anchors.fill: strip
      acceptedButtons: Qt.NoButton

      property real accum: 0
      property bool stepped: false

      onWheel: function(wheel) {
        wheel.accepted = true
        var px = wheel.pixelDelta
        // Touchpads report pixel deltas; mouse wheels report only angle deltas.
        var touchpad = px.x !== 0 || px.y !== 0
        var dx = touchpad ? px.x : wheel.angleDelta.x
        var dy = touchpad ? px.y : wheel.angleDelta.y
        var d = Math.abs(dx) > Math.abs(dy) ? dx : dy
        if (touchpad) {
          // One swipe = one workspace; the next swipe counts once fingers pause.
          gestureEnd.restart()
          if (stepped) return
          accum += d
          if (Math.abs(accum) >= 40) {
            root.selectWorkspace(accum > 0 ? -1 : 1)
            stepped = true
            accum = 0
          }
        } else {
          accum += d
          while (accum >= 120) { root.selectWorkspace(-1); accum -= 120 }
          while (accum <= -120) { root.selectWorkspace(1); accum += 120 }
        }
      }

      Timer {
        id: gestureEnd
        interval: 200
        onTriggered: { wheelCatcher.stepped = false; wheelCatcher.accum = 0 }
      }
    }

    // Workspace dots, like GNOME's overview indicator.
    Row {
      visible: !root.searching && root.workspaces.length > 1
      opacity: root.progress
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: strip.bottom
      anchors.topMargin: Style.space(18)
      spacing: Style.space(8)
      Repeater {
        model: root.opened ? root.workspaces.length : 0
        delegate: Rectangle {
          required property int index
          width: index === root.wsIndex ? Style.space(22) : Style.space(8)
          height: Style.space(8)
          radius: height / 2
          color: root.textColor
          opacity: index === root.wsIndex ? 0.9 : 0.35
          MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: root.wsIndex = parent.index }
        }
      }
    }

    // ---------------------------------------------------- app results

    GridView {
      id: appGrid
      visible: root.searching
      anchors.top: searchBox.bottom
      anchors.topMargin: Style.space(40)
      anchors.horizontalCenter: parent.horizontalCenter
      readonly property int columns: Math.max(1, Math.min(6, Math.floor((parent.width * 0.8) / cellWidth)))
      width: columns * cellWidth
      height: parent.height - y - Style.space(40)
      cellWidth: Style.space(132)
      cellHeight: Style.space(132)
      clip: true
      model: root.apps
      currentIndex: root.appIndex
      boundsBehavior: Flickable.StopAtBounds

      delegate: Item {
        id: appCell
        required property int index
        required property var modelData
        width: appGrid.cellWidth
        height: appGrid.cellHeight

        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(6)
          radius: root.radius
          color: appCell.index === root.appIndex ? root.tint(0.16)
            : (appMouse.containsMouse ? root.tint(0.08) : "transparent")
        }

        Image {
          id: appIcon
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: Style.space(16)
          width: Style.space(64)
          height: Style.space(64)
          sourceSize.width: width * 2
          sourceSize.height: height * 2
          source: appCell.modelData.icon
          fillMode: Image.PreserveAspectFit
          asynchronous: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.top: appIcon.bottom
          anchors.topMargin: Style.space(8)
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width - Style.space(16)
          horizontalAlignment: Text.AlignHCenter
          text: appCell.modelData.name
          color: root.textColor
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: appMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.launchApp(appCell.index)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.searching && root.apps.length === 0
      anchors.centerIn: parent
      text: strings.t("noResults").arg(root.query)
      color: root.textColor
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }
  }
}
