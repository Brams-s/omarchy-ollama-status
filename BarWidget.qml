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
  readonly property var effectiveSettings: ({
    refreshIntervalSec: integerSetting("refreshIntervalSec", 15, 5, 300),
    maxDisplayedModels: integerSetting("maxDisplayedModels", 12, 1, 12),
    compactMode: booleanSetting("compactMode", false)
  })
  // ModuleSlot is the injected bar's authoritative instance record. Its
  // screen, region, and module id identify one live widget without relying on
  // a transient QML object string.
  readonly property var configurationSlot: {
    var slots = root.bar && Array.isArray(root.bar.moduleSlots) ? root.bar.moduleSlots : []
    for (var i = 0; i < slots.length; i++) if (slots[i] && slots[i].activeItem === root) return slots[i]
    return null
  }
  readonly property string serviceConfigurationSource: {
    var slot = configurationSlot
    if (!root.bar || !slot || typeof root.bar.slotWindow !== "function") return ""
    var window = root.bar.slotWindow(slot)
    var screenName = window && window.screen ? String(window.screen.name || "") : ""
    if (!screenName || !slot.region || !slot.moduleName) return ""
    return "bar-slot:" + screenName + ":" + String(slot.region) + ":" + String(slot.moduleName)
  }
  property string configuredServiceSource: ""

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function shortModel(name) {
    name = OllamaModel.plainText(name, 160).replace(/:latest$/, "")
    return name.length > 13 ? name.slice(0, 12) + "…" : name
  }
  function integerSetting(name, fallback, minimum, maximum) {
    var value = Number(setting(name, fallback))
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, Math.floor(value)))
  }
  function booleanSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || value === "true" || value === 1 || value === "1"
  }
  function barLabel() {
    if (root.vertical) return "\uef3d"
    var compact = root.effectiveSettings.compactMode
    if (root.state === "loaded" && root.hasPrimaryModel) {
      var label = root.shortModel(root.primaryModel.name)
      if (!compact && root.primaryModel.sizeVram > 0)
        label += " · VRAM " + OllamaModel.formatBytes(root.primaryModel.sizeVram)
      return "\uef3d " + label
    }
    if (root.state === "idle" || root.state === "loaded") return "\uef3d " + (compact ? "Ollama" : "No model loaded")
    if (root.state === "checking") return "\uef3d " + (compact ? "…" : "Ollama…")
    return "\uef3d " + (compact ? "Offline" : "Ollama unavailable")
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
    if ("settings" in panel) panel.settings = root.effectiveSettings
    if ("effectiveSettings" in panel) panel.effectiveSettings = root.effectiveSettings
    configureService()
  }
  function configureService() {
    if (!ollamaService || !serviceConfigurationSource || typeof ollamaService.configure !== "function") return
    if (configuredServiceSource !== "" && configuredServiceSource !== serviceConfigurationSource
        && typeof ollamaService.unconfigure === "function")
      ollamaService.unconfigure(configuredServiceSource)
    ollamaService.configure(root.effectiveSettings, serviceConfigurationSource)
    configuredServiceSource = serviceConfigurationSource
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onOllamaServiceChanged: injectPanel()
  onEffectiveSettingsChanged: { injectPanel(); configureService() }
  onServiceConfigurationSourceChanged: configureService()
  Component.onCompleted: configureService()
  Component.onDestruction: if (ollamaService && configuredServiceSource !== "" && typeof ollamaService.unconfigure === "function") ollamaService.unconfigure(configuredServiceSource)

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
    text: root.barLabel()
    fontSize: Style.font.body
    horizontalMargin: root.vertical ? Style.space(2) : Style.space(4)
    foreground: root.state === "loaded" ? Color.accent : root.state === "unavailable" ? (root.bar ? root.bar.urgent : Color.urgent) : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: root.state === "loaded" && root.hasPrimaryModel ? "Ollama: " + OllamaModel.plainText(root.primaryModel.name, 160) + "\nEnter opens controls" : root.state === "idle" || root.state === "loaded" ? "Ollama is ready; no model loaded\nEnter opens controls" : (root.errorText || "Checking the Ollama API…")
    onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.togglePanel() }
  }
}
