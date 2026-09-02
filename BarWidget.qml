import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "OllamaModel.js" as OllamaModel

// The small bar face hosts the real Panel so Omarchy can summon, switch, and
// mark it like every built-in panel. Service.qml remains the only API owner.
BarWidget {
  id: root
  moduleName: "brams.ollama-status"
  readonly property var ollamaService: root.bar?.shell?.serviceFor("brams.ollama-status") || null
  readonly property string state: ollamaService ? ollamaService.state : "checking"
  readonly property string errorText: ollamaService ? OllamaModel.plainText(ollamaService.errorText, 300) : ""
  readonly property bool hasPrimaryModel: ollamaService && OllamaModel.hasPrimaryModel(ollamaService.models || [])
  readonly property var primaryModel: hasPrimaryModel ? ollamaService.models[0] : null

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function shortModel(name) {
    name = OllamaModel.plainText(name, 160).replace(/:latest$/, "")
    return name.length > 13 ? name.slice(0, 12) + "…" : name
  }
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function togglePanel() { if (opened) close(); else open() }
  function injectPanel() {
    var panel = panelLoader.item
    if (!panel) return
    if ("bar" in panel) panel.bar = root.bar
    if ("anchorItem" in panel) panel.anchorItem = button
    if ("hostWidget" in panel) panel.hostWidget = root
    if ("ollamaService" in panel) panel.ollamaService = root.ollamaService
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onOllamaServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  WidgetButton {
    id: button
    bar: root.bar
    text: root.vertical ? "\uef3d" : "\uef3d " + (root.state === "loaded" && root.hasPrimaryModel ? root.shortModel(root.primaryModel.name) : root.state === "idle" || root.state === "loaded" ? "No model loaded" : root.state === "checking" ? "Ollama…" : "Ollama unavailable")
    fontSize: Style.font.body
    horizontalMargin: root.vertical ? Style.space(2) : Style.space(4)
    foreground: root.state === "loaded" ? Color.accent : root.state === "unavailable" ? (root.bar ? root.bar.urgent : Color.urgent) : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: root.state === "loaded" && root.hasPrimaryModel ? "Ollama: " + OllamaModel.plainText(root.primaryModel.name, 160) + "\nEnter opens controls" : root.state === "idle" || root.state === "loaded" ? "Ollama is ready; no model loaded\nEnter opens controls" : (root.errorText || "Checking the Ollama API…")
    onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.togglePanel() }
  }
}
