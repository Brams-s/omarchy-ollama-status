import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
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
  // BarWidget forwards bounded effective settings here so any future panel
  // behavior uses the same per-widget configuration as the shared service.
  property var effectiveSettings: ({})
  property int selectedIndex: -1
  property bool confirmUnload: false
  property string confirmedModelName: ""
  property double nowMs: Date.now()
  property string copyFeedback: ""
  property double copyFeedbackUntilMs: 0
  property bool copyBusy: false
  property bool copyTimedOut: false
  readonly property var clipboardEnvironment: ({
    LANG: "C.UTF-8",
    LC_ALL: "C.UTF-8",
    WAYLAND_DISPLAY: null,
    XDG_RUNTIME_DIR: null
  })
  readonly property var barIdentity: hostWidget || root
  readonly property var models: ollamaService && Array.isArray(ollamaService.models) ? ollamaService.models : []
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property double lastSuccessfulRefreshMs: ollamaService ? Number(ollamaService.lastSuccessfulRefreshMs || 0) : 0
  readonly property double lastRefreshCompletedMs: ollamaService ? Number(ollamaService.lastRefreshCompletedMs || 0) : 0
  readonly property bool lastRefreshSucceeded: ollamaService ? ollamaService.lastRefreshSucceeded === true : false
  readonly property bool refreshing: ollamaService ? ollamaService.refreshing === true : false
  readonly property int configuredRefreshSec: boundedSetting(effectiveSettings.refreshIntervalSec, 15, 5, 300)
  readonly property int configuredModelLimit: boundedSetting(effectiveSettings.maxDisplayedModels, 12, 1, 12)

  function plain(value, limit) { return OllamaModel.plainText(value, limit) }
  function boundedSetting(value, fallback, minimum, maximum) {
    value = Number(value)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, Math.floor(value)))
  }
  function refreshNow() {
    if (ollamaService) ollamaService.refresh()
  }
  function refreshFeedback() {
    if (refreshing) return "Refreshing…"
    if (lastRefreshCompletedMs > 0 && nowMs - lastRefreshCompletedMs < 4000)
      return lastRefreshSucceeded ? "Refresh complete" : "Refresh failed"
    return ""
  }
  function totalLoadedCount() {
    if (!ollamaService) return models.length
    var count = Number(ollamaService.loadedModelCount)
    return isFinite(count) && count >= 0 ? Math.floor(count) : models.length
  }
  function aggregateVram() {
    var serviceTotal = Number(ollamaService && ollamaService.aggregateVramBytes)
    if (isFinite(serviceTotal) && serviceTotal > 0) return OllamaModel.formatBytes(serviceTotal)
    var total = 0
    for (var i = 0; i < models.length; i++) {
      var amount = Number(models[i] && models[i].sizeVram)
      if (isFinite(amount) && amount > 0) total += amount
    }
    return isFinite(total) && total > 0 ? OllamaModel.formatBytes(total) : ""
  }
  function setCopyFeedback(message) {
    copyFeedback = message
    copyFeedbackUntilMs = Date.now() + 3000
    nowMs = Date.now()
  }
  function activeCopyFeedback() {
    return copyFeedbackUntilMs > nowMs ? copyFeedback : ""
  }
  function copySelectedModelName() {
    var modelId = actionableModelIdAt(selectedIndex)
    if (!modelId) {
      setCopyFeedback("Copy unavailable for this model")
      return
    }
    if (copyBusy || copyTimedOut || copyProcess.running) {
      setCopyFeedback(copyTimedOut ? "Clipboard is resetting" : "Copy already in progress")
      return
    }
    // Normal wl-copy mode returns once it has established the selection. The
    // short deadline below is only for this startup/setup step, not serving
    // clipboard ownership after the request has completed.
    copyProcess.command = ["/usr/bin/wl-copy", "--type", "text/plain;charset=utf-8", "--", modelId]
    copyBusy = true
    copyTimeout.restart()
    copyProcess.running = true
    setCopyFeedback("Copying…")
  }
  function refreshAge() {
    if (!isFinite(lastSuccessfulRefreshMs) || lastSuccessfulRefreshMs <= 0) return "No successful refresh yet"
    var seconds = Math.max(0, Math.floor((nowMs - lastSuccessfulRefreshMs) / 1000))
    if (seconds < 10) return "Updated just now"
    if (seconds < 60) return "Updated " + seconds + "s ago"
    if (seconds < 3600) return "Updated " + Math.ceil(seconds / 60) + "m ago"
    return "Updated " + Math.ceil(seconds / 3600) + "h ago"
  }
  function statusFailure() {
    if (!ollamaService || ollamaService.localApiStatus !== "unavailable") return ""
    var kind = plain(ollamaService.statusErrorKind, 80)
    if (kind === "missing_python3") return "Local status check needs Python 3"
    if (kind === "missing_curl") return "Local status check needs curl"
    if (kind === "invalid_data") return "Local API returned invalid data"
    if (kind === "response_too_large") return "Local API response was too large"
    return "Local API is unavailable"
  }
  function versionFailure() {
    if (!ollamaService || plain(ollamaService.versionError, 300) === "") return ""
    var kind = plain(ollamaService.versionErrorKind, 80)
    if (kind === "missing_python3") return "Version check needs Python 3"
    if (kind === "missing_curl") return "Version check needs curl"
    if (kind === "invalid_data") return "Version check returned invalid data"
    return "Version check unavailable"
  }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") bar.switchPanelFrom(barIdentity, direction)
  }
  function clearUnloadConfirmation() {
    confirmUnload = false
    confirmedModelName = ""
  }
  function actionableModelIdAt(index) {
    if (index < 0 || index >= models.length || !models[index]) return ""
    var model = models[index]
    // modelId has already passed the data lane's canonical validation. Do not
    // route it through display truncation: valid actionable IDs can be longer.
    return model.actionable === true && typeof model.modelId === "string" ? model.modelId : ""
  }
  function selectStep(step) {
    if (models.length === 0) { selectedIndex = -1; clearUnloadConfirmation(); return }
    var next = Math.max(0, Math.min(models.length - 1, selectedIndex + step))
    if (next !== selectedIndex) selectedIndex = next
    clearUnloadConfirmation()
  }
  function requestUnload(index) {
    if (index < 0 || index >= models.length) return
    if (selectedIndex !== index) {
      selectedIndex = index
      clearUnloadConfirmation()
    }
    var modelId = actionableModelIdAt(index)
    if (!modelId) {
      clearUnloadConfirmation()
      setCopyFeedback("Unload unavailable for this model")
      return
    }
    if (!ollamaService || ollamaService.busy) return
    // Confirmation binds to the sanitized model identity, not the list slot:
    // a refresh may reorder or replace the list between the two activations.
    if (!confirmUnload || confirmedModelName !== modelId || actionableModelIdAt(selectedIndex) !== confirmedModelName) {
      confirmUnload = true
      confirmedModelName = modelId
      return
    }
    if (ollamaService.unload(modelId)) clearUnloadConfirmation()
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

  function shutdownClipboard() {
    copyTimeout.stop()
    copyKill.stop()
    if (copyProcess.running) {
      copyProcess.signal(15)
    }
    copyBusy = false
    copyTimedOut = false
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
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
    if (confirmedModelName !== "" && actionableModelIdAt(selectedIndex) !== confirmedModelName) clearUnloadConfirmation()
    Qt.callLater(ensureSelectedVisible)
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: copyTimeout
    interval: 3000
    repeat: false
    onTriggered: {
      if (!root.copyBusy) return
      root.copyTimedOut = true
      copyProcess.running = false
      copyKill.restart()
      root.setCopyFeedback("Clipboard setup timed out")
    }
  }

  Timer {
    id: copyKill
    interval: 250
    repeat: false
    onTriggered: if (copyProcess.running) copyProcess.signal(9)
  }

  // The fixed helper receives only the Wayland connection fields it needs.
  // Both output channels remain closed, so helper output cannot allocate in QML.
  Process {
    id: copyProcess
    command: []
    clearEnvironment: true
    environment: root.clipboardEnvironment
    // A missing wl-copy may fail during process startup without emitting
    // exited. Defer this recovery so a normal exited handler always gets the
    // first chance to report its accurate zero/nonzero result.
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (copyProcess.running) return
      if (root.copyBusy) {
        root.copyBusy = false
        copyTimeout.stop()
        copyKill.stop()
        if (!root.copyTimedOut) root.setCopyFeedback("Clipboard unavailable")
        root.copyTimedOut = false
      }
    })
    onExited: function(exitCode) {
      copyTimeout.stop()
      copyKill.stop()
      if (root.copyTimedOut) {
        root.copyBusy = false
        root.copyTimedOut = false
        return
      }
      if (!root.copyBusy) return
      root.copyBusy = false
      if (exitCode === 0) root.setCopyFeedback("Model name copied")
      else root.setCopyFeedback("Clipboard unavailable")
    }
  }

  Component.onDestruction: root.shutdownClipboard()

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
        else if (text === "c" || text === "C") root.copySelectedModelName()
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

          Item {
            id: refreshControl
            width: parent.width
            height: Style.space(30)
            Rectangle {
              anchors.fill: parent
              radius: Style.space(7)
              color: refreshMouse.containsMouse
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            }
            Row {
              anchors.centerIn: parent
              spacing: Style.space(6)
              Text { text: "↻"; color: Color.accent; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
              Text { text: root.refreshing ? "Refreshing…" : root.ollamaService && root.ollamaService.busy ? "Busy — retry shortly" : "Refresh status"; color: root.foreground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              Text { text: "R"; color: root.foreground; opacity: .6; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
            }
            MouseArea {
              id: refreshMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refreshNow()
            }
          }

          Item {
            id: copyControl
            visible: root.models.length > 0
            width: parent.width
            height: Style.space(30)
            Rectangle {
              anchors.fill: parent
              radius: Style.space(7)
              color: copyMouse.containsMouse
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
              opacity: root.actionableModelIdAt(root.selectedIndex) !== "" ? 1 : .55
            }
            Row {
              anchors.centerIn: parent
              spacing: Style.space(6)
              Text { text: "⧉"; color: Color.accent; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
              Text { text: root.activeCopyFeedback() !== "" ? root.activeCopyFeedback() : root.actionableModelIdAt(root.selectedIndex) !== "" ? "Copy model name" : "Copy unavailable"; color: root.foreground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              Text { text: "C"; color: root.foreground; opacity: .6; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
            }
            MouseArea {
              id: copyMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.copySelectedModelName()
            }
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
              Text { visible: root.totalLoadedCount() > 0; text: root.totalLoadedCount() + " total loaded model" + (root.totalLoadedCount() === 1 ? "" : "s") + (root.aggregateVram() !== "" ? " · VRAM " + root.aggregateVram() : ""); color: root.foreground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
            }
          }

          Rectangle {
            width: parent.width
            implicitHeight: diagnostics.implicitHeight + Style.space(18)
            radius: Style.space(8)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
            Column {
              id: diagnostics
              anchors.fill: parent
              anchors.margins: Style.space(9)
              spacing: Style.space(3)
              Text { text: "LOCAL DIAGNOSTICS"; color: root.foreground; opacity: .58; font.pixelSize: Style.font.bodySmall; font.bold: true; textFormat: Text.PlainText }
              Text { text: "API · " + (root.ollamaService && root.ollamaService.localApiStatus === "available" ? "Available" : root.ollamaService && root.ollamaService.localApiStatus === "checking" ? "Checking" : "Unavailable"); color: root.foreground; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              Text { visible: root.ollamaService && root.ollamaService.apiVersion !== ""; text: root.ollamaService ? "Version · v" + root.plain(root.ollamaService.apiVersion, 80) : ""; color: root.foreground; opacity: .7; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              Text { text: root.refreshAge() + " · every " + root.configuredRefreshSec + "s · up to " + root.configuredModelLimit + " models"; color: root.foreground; opacity: .7; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              Text { visible: root.statusFailure() !== ""; text: root.statusFailure(); color: root.urgent; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              Text { visible: root.versionFailure() !== ""; text: root.versionFailure(); color: root.urgent; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
            }
          }

          Repeater {
            id: modelRepeater
            model: root.models
            delegate: FocusScope {
              required property var modelData
              required property int index
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
                Text { width: parent.width; text: root.plain(parent.parent.modelItem.displayName, 160); color: root.foreground; font.pixelSize: Style.font.body; elide: Text.ElideRight; textFormat: Text.PlainText }
                Text { width: parent.width; text: (parent.parent.modelItem.size > 0 ? OllamaModel.formatBytes(parent.parent.modelItem.size) : "") + (parent.parent.modelItem.sizeVram > 0 ? " · VRAM " + OllamaModel.formatBytes(parent.parent.modelItem.sizeVram) : "") + (parent.parent.modelItem.context ? " · ctx " + root.plain(parent.parent.modelItem.context, 20) : ""); visible: text !== ""; color: root.foreground; opacity: .7; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight; textFormat: Text.PlainText }
                Text { text: OllamaModel.relativeExpiry(parent.parent.modelItem.expiresAt); visible: text !== ""; color: root.foreground; opacity: .7; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
              }
              Text {
                id: unloadLabel
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.ollamaService && root.ollamaService.busy && root.ollamaService.pendingModel === root.actionableModelIdAt(index) ? "…" : root.actionableModelIdAt(index) === "" ? "Unavailable" : selected && root.confirmUnload && root.confirmedModelName === root.actionableModelIdAt(index) ? "Confirm" : "Unload"
                color: root.urgent
                font.pixelSize: Style.font.bodySmall
                font.underline: selected
                textFormat: Text.PlainText
              }
              MouseArea {
                anchors.fill: parent
                enabled: !root.ollamaService || !root.ollamaService.busy
                cursorShape: root.actionableModelIdAt(index) !== "" && enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.requestUnload(index)
              }
            }
          }

          Text { visible: root.ollamaService && root.ollamaService.feedbackText !== ""; width: parent.width; text: root.ollamaService ? root.ollamaService.feedbackText : ""; color: root.urgent; wrapMode: Text.Wrap; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
          Text { width: parent.width; text: root.ollamaService && root.ollamaService.busy ? "Unloading model…" : root.activeCopyFeedback() !== "" ? root.activeCopyFeedback() : root.refreshFeedback() !== "" ? root.refreshFeedback() : root.models.length > 0 ? "Select a model, then press Enter again to confirm unload." : "Uses Ollama’s local API. Service control stays with your setup."; color: root.foreground; opacity: .65; wrapMode: Text.Wrap; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText }
        }
      }
    }
  }
}
