import QtQuick
import Quickshell
import Quickshell.Io
import "OllamaModel.js" as OllamaModel

Item {
  id: root

  property var shell: null
  property string state: "checking"
  property var models: []
  property string errorText: ""
  property string apiVersion: ""
  property string versionError: ""
  property bool busy: false
  property int failureCount: 0
  property string pendingModel: ""
  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("status.sh").toString().replace(/^file:\/\//, ""))
  readonly property int nextPollInterval: state === "unavailable"
    ? Math.min(15000 * Math.pow(2, Math.min(failureCount, 3)), 300000)
    : 15000

  function refresh() {
    if (status.running || busy) return false
    status.outputText = ""
    status.running = true
    return true
  }

  function unload(name) {
    var model = OllamaModel.plainText(name, 160)
    if (busy || action.running || !model) return false
    busy = true
    pendingModel = model
    errorText = ""
    action.outputText = ""
    action.command = ["bash", scriptPath, "unload", model]
    action.running = true
    return true
  }

  function applyStatus(output) {
    var result = OllamaModel.parseResult(output, "status")
    if (result.ok !== true) {
      models = []
      state = "unavailable"
      errorText = OllamaModel.errorFor(result, "Ollama status request failed.")
      failureCount += 1
      return
    }
    var next = OllamaModel.parseStatus(result, 12)
    models = next.models
    state = next.state
    errorText = next.error
    failureCount = next.state === "unavailable" ? failureCount + 1 : 0
    if (next.state !== "unavailable" && apiVersion === "" && !version.running) {
      version.outputText = ""
      version.running = true
    }
  }

  function applyVersion(output) {
    var result = OllamaModel.parseResult(output, "version")
    if (result.ok === true && result.data && typeof result.data.version === "string") {
      apiVersion = OllamaModel.plainText(result.data.version, 80)
      versionError = ""
    } else {
      apiVersion = ""
      versionError = OllamaModel.errorFor(result, "Ollama version diagnostics failed.")
    }
  }

  Process {
    id: status
    command: ["bash", root.scriptPath, "status"]
    property string outputText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { status.outputText = text }
    }
    onExited: function() {
      root.applyStatus(status.outputText)
      pollTimer.restart()
    }
  }

  Process {
    id: version
    command: ["bash", root.scriptPath, "version"]
    property string outputText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { version.outputText = text }
    }
    onExited: function() { root.applyVersion(version.outputText) }
  }

  Process {
    id: action
    command: []
    property string outputText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { action.outputText = text }
    }
    onExited: function() {
      var result = OllamaModel.parseResult(action.outputText, "unload")
      if (result.ok !== true) root.errorText = OllamaModel.errorFor(result, "The unload request failed.")
      root.busy = false
      root.pendingModel = ""
      root.refresh()
    }
  }

  Timer {
    id: pollTimer
    interval: root.nextPollInterval
    repeat: false
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}
