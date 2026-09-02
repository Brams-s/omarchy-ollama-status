import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "brams.ollama-status"
  property string state: "checking"
  property string errorText: ""
  property bool busy: false
  property string pendingModel: ""

  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }
  function formatBytes(value) {
    var amount = Number(value), units = ["B", "KB", "MB", "GB", "TB"], index = 0
    if (!isFinite(amount) || amount <= 0) return ""
    while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index++ }
    return amount.toFixed(index > 1 ? 1 : 0) + " " + units[index]
  }
  function relativeExpiry(value) {
    var seconds = Math.floor((Date.parse(value) - Date.now()) / 1000)
    if (!isFinite(seconds)) return ""
    if (seconds <= 0) return "Unloads soon"
    if (seconds < 60) return "Unloads in <1m"
    if (seconds < 3600) return "Unloads in " + Math.ceil(seconds / 60) + "m"
    return "Unloads in " + Math.ceil(seconds / 3600) + "h"
  }
  function shortModel(name) { name = String(name || "").replace(/:latest$/, ""); return name.length > 13 ? name.slice(0, 12) + "…" : name }
  function safeText(value, maximum) {
    if (typeof value !== "string") return ""
    value = value.trim()
    return value.slice(0, maximum)
  }
  function safeNumber(value) {
    var number = Number(value)
    return isFinite(number) && number >= 0 ? number : 0
  }
  function safeContext(value) {
    var number = safeNumber(value)
    return number > 0 ? String(Math.min(Math.floor(number), 10000000)) : ""
  }
  function setUnavailable(message) {
    state = "unavailable"
    models.clear()
    errorText = safeText(String(message || "Ollama status request failed."), 300) || "Ollama status request failed."
  }
  function parseStatus(output) {
    try {
      var response = JSON.parse(String(output).trim())
      if (!response || typeof response !== "object") throw new Error("not an object")
      if (response.error) { setUnavailable(typeof response.error === "string" ? response.error : "Ollama returned an API error."); return }
      if (!Array.isArray(response.models)) throw new Error("missing models")
      models.clear()
      // Keep a hostile or unexpectedly large local response from filling the bar.
      for (var i = 0; i < Math.min(response.models.length, 12); i++) {
        var item = response.models[i]
        if (!item || typeof item !== "object") continue
        var name = safeText(typeof item.name === "string" ? item.name : item.model, 160)
        if (name === "") continue
        models.append({ name: name, sizeText: formatBytes(safeNumber(item.size)), vramText: formatBytes(safeNumber(item.size_vram)), contextText: safeContext(item.context_length), expiryText: safeText(item.expires_at, 80) })
      }
      state = models.count > 0 ? "loaded" : "idle"
      errorText = ""
    } catch (e) { setUnavailable("Ollama returned an invalid API response.") }
  }
  function pollStatus() {
    if (status.running || busy) return
    status.receivedOutput = false
    status.stderrText = ""
    status.running = true
  }
  function refresh() { pollStatus() }
  function toggleMenu() { if (menu.visible) menu.visible = false; else { menu.visible = true; refresh() } }
  function unload(name) {
    if (busy || name === "") return
    busy = true; pendingModel = name; errorText = ""
    action.receivedOutput = false
    action.stderrText = ""
    action.command = ["bash", scriptPath, "unload", name]
    action.running = true
  }

  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("status.sh").toString().replace(/^file:\/\//, ""))
  readonly property color normalForeground: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color accentForeground: Color.accent
  readonly property color urgentForeground: root.bar ? root.bar.urgent : Color.urgent
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: status
    command: ["bash", root.scriptPath]
    property bool receivedOutput: false
    property string stderrText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        status.receivedOutput = text.trim() !== ""
        if (status.receivedOutput) root.parseStatus(text)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { status.stderrText = text.trim() }
    }
    onExited: function(code) {
      if (code !== 0) root.setUnavailable(status.stderrText || "Ollama status request failed.")
      else if (!status.receivedOutput) root.setUnavailable(status.stderrText || "Ollama status request returned no data.")
    }
  }
  // The bar needs freshness, not a request every second. Opening the card refreshes immediately.
  Timer {
    interval: menu.visible ? 5000 : 15000
    repeat: true
    running: true
    onTriggered: root.pollStatus()
  }
  Process {
    id: action
    command: []
    property bool receivedOutput: false
    property string stderrText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        action.receivedOutput = text.trim() !== ""
        if (!action.receivedOutput) return
        try {
          var response = JSON.parse(text)
          if (!response || typeof response !== "object") throw new Error("not an object")
          if (response.error) root.errorText = root.safeText(typeof response.error === "string" ? response.error : "The unload request failed.", 300)
        } catch (e) { root.errorText = "The unload request returned an invalid response." }
      }
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: function() { action.stderrText = text.trim() } }
    onExited: function(code) {
      if (code !== 0) root.errorText = action.stderrText || root.errorText || "The unload request failed."
      else if (!action.receivedOutput && root.errorText === "") root.errorText = action.stderrText || "The unload request returned no data."
      root.busy = false; root.pendingModel = ""; root.refresh()
    }
  }
  ListModel { id: models }

  WidgetButton {
    id: button
    bar: root.bar
    text: "\uef3d " + (root.state === "loaded" ? root.shortModel(models.get(0).name) + " · " + (models.get(0).vramText !== "" ? "VRAM " + models.get(0).vramText : "loaded") : root.state === "idle" ? "No model loaded" : root.state === "checking" ? "Ollama…" : "Ollama unavailable")
    fontSize: Style.font.body
    horizontalMargin: 4.5
    foreground: root.state === "loaded" ? root.accentForeground : root.state === "unavailable" ? root.urgentForeground : root.normalForeground
    tooltipText: root.state === "loaded" ? "Ollama: " + models.get(0).name : root.state === "idle" ? "Ollama is ready; no model loaded" : (root.errorText || "Checking the Ollama API…")
    onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.toggleMenu() }
  }

  PopupWindow {
    id: menu
    visible: false
    grabFocus: true
    anchor.item: button
    anchor.rect.y: button.height + Style.spaceReal(2)
    anchor.adjustment: PopupAdjustment.Slide
    implicitWidth: 390
    implicitHeight: card.implicitHeight
    color: "transparent"
    Rectangle {
      id: card
      width: parent.width
      implicitHeight: content.implicitHeight + 32
      color: Color.background
      radius: 12
      border.width: 1
      border.color: root.alpha(root.normalForeground, 0.18)
      Column {
        id: content
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10
        Row {
          width: parent.width
          height: 22
          spacing: 8
          Text {
            text: "\uef3d"
            color: root.accentForeground
            font.pixelSize: Style.font.body
          }
          Text {
            text: "Ollama"
            color: root.normalForeground
            font.bold: true
            font.pixelSize: Style.font.body
          }
        }
        Rectangle {
          width: parent.width
          implicitHeight: body.implicitHeight + 24
          radius: 12
          color: root.alpha(root.normalForeground, 0.06)
          Column {
            id: body
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            Text { visible: root.state === "unavailable"; text: "Ollama API unavailable\nCheck that Ollama is running and reachable."; color: root.normalForeground; font.pixelSize: Style.font.bodySmall; lineHeight: 1.2 }
            Text { visible: root.state === "checking"; text: "Checking Ollama…"; color: root.normalForeground; font.pixelSize: Style.font.bodySmall }
            Text { visible: root.state === "idle"; text: "No model loaded\nReady for your next prompt."; color: root.normalForeground; font.pixelSize: Style.font.bodySmall; lineHeight: 1.2 }
            Repeater {
              model: models
              delegate: Rectangle {
                required property string name
                required property string sizeText
                required property string vramText
                required property string contextText
                required property string expiryText
                width: body.width; implicitHeight: info.implicitHeight + 16; radius: 8
                color: root.alpha(root.normalForeground, 0.06)
                Column {
                  id: info
                  anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - unloadButton.width - 26; spacing: 2
                  Text { text: parent.parent.name; color: root.normalForeground; font.pixelSize: Style.font.body; elide: Text.ElideRight; width: parent.width }
                  Text { text: (parent.parent.sizeText !== "" ? parent.parent.sizeText : "") + (parent.parent.vramText !== "" ? " · VRAM " + parent.parent.vramText : "") + (parent.parent.contextText !== "" ? " · ctx " + parent.parent.contextText : ""); visible: text !== ""; color: root.normalForeground; opacity: .72; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight; width: parent.width }
                  Text { text: root.relativeExpiry(parent.parent.expiryText); visible: text !== ""; color: root.normalForeground; opacity: .72; font.pixelSize: Style.font.bodySmall }
                }
                Rectangle {
                  id: unloadButton
                  width: 54
                  height: 24
                  anchors.right: parent.right
                  anchors.rightMargin: 10
                  anchors.verticalCenter: parent.verticalCenter
                  radius: 6
                  color: root.alpha(root.urgentForeground, .10)
                  opacity: root.busy && root.pendingModel === parent.name ? .5 : 1
                  Text {
                    anchors.centerIn: parent
                    text: root.busy && root.pendingModel === parent.name ? "…" : "Unload"
                    color: root.urgentForeground
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: !root.busy
                    onClicked: root.unload(parent.parent.name)
                  }
                }
              }
            }
          }
        }
        Text { visible: root.errorText !== ""; text: root.errorText; color: root.urgentForeground; wrapMode: Text.Wrap; width: parent.width; font.pixelSize: Style.font.bodySmall }
        Text { text: root.busy ? "Unloading model…" : "Uses Ollama’s local API. Service control stays with your setup."; color: root.normalForeground; opacity: .65; wrapMode: Text.Wrap; width: parent.width; font.pixelSize: Style.font.bodySmall }
      }
    }
  }
}
