import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "OllamaModel.js" as OllamaModel

Panel {
  id: root
  moduleName: "brams.ollama-status"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var ollamaService: null
  property int selectedIndex: -1
  property bool confirmUnload: false
  property string confirmedModelName: ""
  readonly property var barIdentity: hostWidget || root
  readonly property var models: ollamaService && Array.isArray(ollamaService.models) ? ollamaService.models : []
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  function plain(value, limit) { return OllamaModel.plainText(value, limit) }
  function refreshNow() { if (ollamaService) ollamaService.refresh() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") bar.switchPanelFrom(barIdentity, direction)
  }
  function clearUnloadConfirmation() {
    confirmUnload = false
    confirmedModelName = ""
  }
  function modelNameAt(index) {
    if (index < 0 || index >= models.length || !models[index]) return ""
    return plain(models[index].name, 160)
  }
  function selectStep(step) {
    if (models.length === 0) { selectedIndex = -1; clearUnloadConfirmation(); return }
    var next = Math.max(0, Math.min(models.length - 1, selectedIndex + step))
    if (next !== selectedIndex) selectedIndex = next
    clearUnloadConfirmation()
  }
  function requestUnload(index) {
    if (!ollamaService || ollamaService.busy || index < 0 || index >= models.length) return
    var modelName = modelNameAt(index)
    if (!modelName) return
    if (selectedIndex !== index) {
      selectedIndex = index
      clearUnloadConfirmation()
    }
    // Confirmation binds to the sanitized model identity, not the list slot:
    // a refresh may reorder or replace the list between the two activations.
    if (!confirmUnload || confirmedModelName !== modelName || modelNameAt(selectedIndex) !== confirmedModelName) {
      confirmUnload = true
      confirmedModelName = modelName
      return
    }
    if (ollamaService.unload(modelName)) clearUnloadConfirmation()
  }
  function ensureSelectedVisible() {
    if (selectedIndex < 0 || !modelRepeater || !modelFlick) return
    var item = modelRepeater.itemAt(selectedIndex)
    if (!item) return
    var point = item.mapToItem(modelFlick.contentItem || modelFlick, 0, 0)
    var top = point.y
    var bottom = top + item.height
    var margin = Style.space(6)
    var viewTop = modelFlick.contentY
    var viewBottom = viewTop + modelFlick.height
    var maximum = Math.max(0, modelFlick.contentHeight - modelFlick.height)
    if (top < viewTop + margin)
      modelFlick.contentY = Math.max(0, Math.min(maximum, top - margin))
    else if (bottom > viewBottom - margin)
      modelFlick.contentY = Math.max(0, Math.min(maximum, bottom + margin - modelFlick.height))
  }

  onOpenedChanged: if (opened) {
    refreshNow()
    selectedIndex = models.length > 0 ? 0 : -1
    clearUnloadConfirmation()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onModelsChanged: {
    if (selectedIndex >= models.length) selectedIndex = models.length - 1
    clearUnloadConfirmation()
    Qt.callLater(ensureSelectedVisible)
  }
  onSelectedIndexChanged: {
    if (confirmedModelName !== "" && modelNameAt(selectedIndex) !== confirmedModelName) clearUnloadConfirmation()
    Qt.callLater(ensureSelectedVisible)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.selectStep(dy)
        if (dx !== 0) root.clearUnloadConfirmation()
      }
      onActivateRequested: {
        if (root.selectedIndex >= 0) root.requestUnload(root.selectedIndex)
        else root.refreshNow()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshNow()
        else if ((text === "u" || text === "U") && root.selectedIndex >= 0) root.requestUnload(root.selectedIndex)
      }

      Flickable {
        id: modelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: modelFlick.width
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text { text: "\uef3d"; color: Color.accent; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
            Column {
              width: parent.width - parent.spacing - titleIcon.implicitWidth
              Text { id: titleText; text: "Ollama"; color: root.foreground; font.bold: true; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
              Text { text: "R refreshes · Esc closes"; color: root.foreground; opacity: .6; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
            }
            // Kept separate for a stable width calculation above.
            Text { id: titleIcon; visible: false; text: "\uef3d" }
          }

          Rectangle {
            width: parent.width
            implicitHeight: summary.implicitHeight + Style.space(20)
            radius: Style.space(8)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            Column {
              id: summary
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(4)
              Text { visible: !root.ollamaService || root.ollamaService.state === "checking"; text: "Checking Ollama…"; color: root.foreground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              Text { visible: root.ollamaService && root.ollamaService.state === "unavailable"; text: "Ollama API unavailable\nCheck that Ollama is running and reachable."; color: root.foreground; font.pixelSize: Style.font.bodySmall; lineHeight: 1.2; textFormat: Text.PlainText }
              Text { visible: root.ollamaService && (root.ollamaService.state === "idle" || (root.ollamaService.state === "loaded" && root.models.length === 0)); text: "No model loaded\nReady for your next prompt."; color: root.foreground; font.pixelSize: Style.font.bodySmall; lineHeight: 1.2; textFormat: Text.PlainText }
              Text { visible: root.models.length > 0; text: root.models.length + " model" + (root.models.length === 1 ? "" : "s") + " held in memory"; color: root.foreground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
            }
          }

          Repeater {
            id: modelRepeater
            model: root.models
            delegate: FocusScope {
              required property var modelData
              readonly property var modelItem: modelData || ({})
              readonly property bool selected: root.selectedIndex === index
              width: contentColumn.width
              implicitHeight: modelInfo.implicitHeight + Style.space(20)
              activeFocusOnTab: true
              Keys.onReturnPressed: root.requestUnload(index)
              Keys.onSpacePressed: root.requestUnload(index)
              onSelectedChanged: if (selected) Qt.callLater(root.ensureSelectedVisible)
              Rectangle {
                anchors.fill: parent
                radius: Style.space(8)
                color: selected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                border.width: selected ? 1 : 0
                border.color: Color.accent
              }
              Column {
                id: modelInfo
                anchors.left: parent.left
                anchors.right: unloadLabel.left
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                Text { width: parent.width; text: root.plain(parent.parent.modelItem.name, 160); color: root.foreground; font.pixelSize: Style.font.body; elide: Text.ElideRight; textFormat: Text.PlainText }
                Text { width: parent.width; text: (parent.parent.modelItem.size > 0 ? OllamaModel.formatBytes(parent.parent.modelItem.size) : "") + (parent.parent.modelItem.sizeVram > 0 ? " · VRAM " + OllamaModel.formatBytes(parent.parent.modelItem.sizeVram) : "") + (parent.parent.modelItem.context ? " · ctx " + root.plain(parent.parent.modelItem.context, 20) : ""); visible: text !== ""; color: root.foreground; opacity: .7; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight; textFormat: Text.PlainText }
                Text { text: OllamaModel.relativeExpiry(parent.parent.modelItem.expiresAt); visible: text !== ""; color: root.foreground; opacity: .7; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              }
              Text {
                id: unloadLabel
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.ollamaService && root.ollamaService.busy && root.ollamaService.pendingModel === parent.modelItem.name ? "…" : selected && root.confirmUnload && root.confirmedModelName === root.modelNameAt(index) ? "Confirm" : "Unload"
                color: root.urgent
                font.pixelSize: Style.font.bodySmall
                font.underline: selected
                textFormat: Text.PlainText
              }
              MouseArea {
                anchors.fill: parent
                enabled: !root.ollamaService || !root.ollamaService.busy
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.requestUnload(index)
              }
            }
          }

          Text { visible: root.ollamaService && root.ollamaService.errorText !== ""; width: parent.width; text: root.plain(root.ollamaService.errorText, 300); color: root.urgent; wrapMode: Text.Wrap; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
          Text { width: parent.width; text: root.ollamaService && root.ollamaService.busy ? "Unloading model…" : root.models.length > 0 ? "Select a model, then press Enter again to confirm unload." : "Uses Ollama’s local API. Service control stays with your setup."; color: root.foreground; opacity: .65; wrapMode: Text.Wrap; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
        }
      }
    }
  }
}
