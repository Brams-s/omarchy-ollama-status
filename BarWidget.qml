import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "OllamaModel.js" as OllamaModel

BarWidget {
  id: root
  moduleName: "brams.ollama-status"
  // This is the shell's generic third-party service registry. The widget never
  // owns a Process, so multiple bar instances share one polling client.
  readonly property var ollamaService: root.bar?.shell?.serviceFor("brams.ollama-status") || null
  readonly property string state: ollamaService ? ollamaService.state : "checking"
  readonly property string errorText: ollamaService ? ollamaService.errorText : ""
  readonly property bool busy: ollamaService ? ollamaService.busy : false
  readonly property string pendingModel: ollamaService ? ollamaService.pendingModel : ""
  readonly property var models: ollamaService && Array.isArray(ollamaService.models) ? ollamaService.models : []
  readonly property bool hasPrimaryModel: OllamaModel.hasPrimaryModel(models)
  readonly property var primaryModel: hasPrimaryModel ? models[0] : null

  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }
  function shortModel(name) {
    name = OllamaModel.plainText(name, 160).replace(/:latest$/, "")
    return name.length > 13 ? name.slice(0, 12) + "…" : name
  }
  function refresh() { if (ollamaService) ollamaService.refresh() }
  function toggleMenu() {
    if (menu.visible) menu.visible = false
    else { menu.visible = true; refresh() }
  }

  readonly property color normalForeground: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color accentForeground: Color.accent
  readonly property color urgentForeground: root.bar ? root.bar.urgent : Color.urgent
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    bar: root.bar
    text: "\uef3d " + (root.state === "loaded" && root.hasPrimaryModel ? root.shortModel(root.primaryModel.name) + " · " + (root.primaryModel.sizeVram > 0 ? "VRAM " + OllamaModel.formatBytes(root.primaryModel.sizeVram) : "loaded") : root.state === "idle" || root.state === "loaded" ? "No model loaded" : root.state === "checking" ? "Ollama…" : "Ollama unavailable")
    fontSize: Style.font.body
    horizontalMargin: 4.5
    foreground: root.state === "loaded" ? root.accentForeground : root.state === "unavailable" ? root.urgentForeground : root.normalForeground
    tooltipText: root.state === "loaded" && root.hasPrimaryModel ? "Ollama: " + root.primaryModel.name : root.state === "idle" || root.state === "loaded" ? "Ollama is ready; no model loaded" : (root.errorText || "Checking the Ollama API…")
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
          Text { text: "\uef3d"; color: root.accentForeground; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
          Text { text: "Ollama"; color: root.normalForeground; font.bold: true; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
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
            Text { visible: root.state === "unavailable"; text: "Ollama API unavailable\nCheck that Ollama is running and reachable."; color: root.normalForeground; font.pixelSize: Style.font.bodySmall; lineHeight: 1.2; textFormat: Text.PlainText }
            Text { visible: root.state === "checking"; text: "Checking Ollama…"; color: root.normalForeground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
            Text { visible: root.state === "idle"; text: "No model loaded\nReady for your next prompt."; color: root.normalForeground; font.pixelSize: Style.font.bodySmall; lineHeight: 1.2; textFormat: Text.PlainText }
            Repeater {
              model: root.models
              delegate: Rectangle {
                required property var modelData
                readonly property var modelItem: modelData || ({})
                width: body.width
                implicitHeight: info.implicitHeight + 16
                radius: 8
                color: root.alpha(root.normalForeground, 0.06)
                Column {
                  id: info
                  anchors.left: parent.left
                  anchors.leftMargin: 10
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - unloadButton.width - 26
                  spacing: 2
                  Text { text: parent.parent.modelItem.name || ""; color: root.normalForeground; font.pixelSize: Style.font.body; elide: Text.ElideRight; width: parent.width; textFormat: Text.PlainText }
                  Text {
                    text: (parent.parent.modelItem.size > 0 ? OllamaModel.formatBytes(parent.parent.modelItem.size) : "") + (parent.parent.modelItem.sizeVram > 0 ? " · VRAM " + OllamaModel.formatBytes(parent.parent.modelItem.sizeVram) : "") + (parent.parent.modelItem.context ? " · ctx " + parent.parent.modelItem.context : "")
                    visible: text !== ""
                    color: root.normalForeground
                    opacity: .72
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    width: parent.width
                    textFormat: Text.PlainText
                  }
                  Text { text: OllamaModel.relativeExpiry(parent.parent.modelItem.expiresAt); visible: text !== ""; color: root.normalForeground; opacity: .72; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
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
                  opacity: root.busy && root.pendingModel === parent.modelItem.name ? .5 : 1
                  Text { anchors.centerIn: parent; text: root.busy && root.pendingModel === parent.modelItem.name ? "…" : "Unload"; color: root.urgentForeground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
                  MouseArea { anchors.fill: parent; enabled: !root.busy; onClicked: if (root.ollamaService) root.ollamaService.unload(parent.parent.modelItem.name) }
                }
              }
            }
          }
        }
        Text { visible: root.errorText !== ""; text: root.errorText; color: root.urgentForeground; wrapMode: Text.Wrap; width: parent.width; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
        Text { text: root.busy ? "Unloading model…" : "Uses Ollama’s local API. Service control stays with your setup."; color: root.normalForeground; opacity: .65; wrapMode: Text.Wrap; width: parent.width; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
      }
    }
  }
}
