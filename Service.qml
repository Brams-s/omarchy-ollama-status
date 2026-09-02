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
  property string versionErrorKind: ""
  property string statusErrorKind: ""
  property string actionErrorKind: ""
  property double lastSuccessfulRefreshMs: 0
  property double lastRefreshStartedMs: 0
  property double lastRefreshCompletedMs: 0
  property bool lastRefreshSucceeded: false
  property int refreshCompletionSerial: 0
  property bool refreshing: false
  property string localApiStatus: "checking"
  property string lastErrorKind: ""
  property bool busy: false
  property int failureCount: 0
  property string pendingModel: ""
  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("status.sh").toString().replace(/^file:\/\//, ""))
  property int refreshIntervalSec: 15
  property int maxDisplayedModels: 12
  property bool compactMode: false
  property var _configurations: ({})
  property string _configurationSource: ""
  readonly property int nextPollInterval: state === "unavailable"
    ? Math.min(refreshIntervalSec * 1000 * Math.pow(2, Math.min(failureCount, 3)), 300000)
    : refreshIntervalSec * 1000

  function normalizeSettings(settings) {
    settings = settings && typeof settings === "object" ? settings : ({})
    return {
      refreshIntervalSec: OllamaModel.boundedInteger(settings.refreshIntervalSec, 15, 5, 300),
      maxDisplayedModels: OllamaModel.boundedInteger(settings.maxDisplayedModels, 12, 1, 12),
      compactMode: settings.compactMode === true || settings.compactMode === "true" || settings.compactMode === 1 || settings.compactMode === "1"
    }
  }
  function sameSettings(left, right) {
    return left && right && left.refreshIntervalSec === right.refreshIntervalSec
      && left.maxDisplayedModels === right.maxDisplayedModels && left.compactMode === right.compactMode
  }
  function selectedConfiguration() {
    var keys = Object.keys(_configurations).sort()
    return keys.length > 0 ? { source: keys[0], settings: _configurations[keys[0]] } : null
  }
  function applyConfiguration() {
    var selected = selectedConfiguration()
    var next = selected ? selected.settings : normalizeSettings({})
    var previousLimit = maxDisplayedModels
    var changed = refreshIntervalSec !== next.refreshIntervalSec || previousLimit !== next.maxDisplayedModels || compactMode !== next.compactMode
    _configurationSource = selected ? selected.source : ""
    if (!changed) return false
    refreshIntervalSec = next.refreshIntervalSec
    maxDisplayedModels = next.maxDisplayedModels
    compactMode = next.compactMode
    if (models.length > maxDisplayedModels) models = models.slice(0, maxDisplayedModels)
    if (pollTimer.running) pollTimer.restart()
    if (maxDisplayedModels > previousLimit) Qt.callLater(function() { root.refresh() })
    return true
  }
  // Each bar registers rather than overwriting the singleton. The stable,
  // lexical source selection prevents monitor instances from flapping it.
  function configure(settings, sourceId) {
    var source = String(sourceId || "default")
    var nextSettings = normalizeSettings(settings)
    var current = _configurations[source]
    if (sameSettings(current, nextSettings)) return false
    var next = ({})
    for (var key in _configurations) next[key] = _configurations[key]
    next[source] = nextSettings
    _configurations = next
    return applyConfiguration()
  }
  function unconfigure(sourceId) {
    var source = String(sourceId || "default")
    if (!_configurations[source]) return false
    var next = ({})
    for (var key in _configurations) if (key !== source) next[key] = _configurations[key]
    _configurations = next
    return applyConfiguration()
  }

  function refresh() {
    if (status.running || busy) return false
    status.outputText = ""
    refreshing = true
    lastRefreshStartedMs = Date.now()
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

  function classifyErrorKind(result, fallback) {
    var kind = OllamaModel.plainText(result && result.kind, 80)
    if (kind === "missing_dependency") {
      var message = OllamaModel.plainText(result && result.error, 160).toLowerCase()
      if (message.indexOf("python3") !== -1) return "missing_python3"
      if (message.indexOf("curl") !== -1) return "missing_curl"
      return "missing_dependency"
    }
    var allowed = ["unsafe_endpoint", "transport_error", "response_too_large", "invalid_data", "invalid_request", "internal_error", "api_error"]
    return allowed.indexOf(kind) !== -1 ? kind : fallback
  }
  function updateLastErrorKind() {
    lastErrorKind = statusErrorKind || versionErrorKind || actionErrorKind || ""
  }
  function applyStatus(output, completedAt) {
    var result = OllamaModel.parseResult(output, "status")
    if (result.ok !== true) {
      models = []
      state = "unavailable"
      errorText = OllamaModel.errorFor(result, "Ollama status request failed.")
      localApiStatus = "unavailable"
      statusErrorKind = classifyErrorKind(result, "status_error")
      updateLastErrorKind()
      failureCount += 1
      return false
    }
    var next = OllamaModel.parseStatus(result, maxDisplayedModels)
    models = next.models
    state = next.state
    errorText = next.error
    localApiStatus = next.state === "unavailable" ? "unavailable" : "available"
    if (next.state === "unavailable") {
      statusErrorKind = "invalid_data"
      updateLastErrorKind()
    }
    else {
      lastSuccessfulRefreshMs = completedAt
      statusErrorKind = ""
      updateLastErrorKind()
    }
    failureCount = next.state === "unavailable" ? failureCount + 1 : 0
    if (next.state !== "unavailable" && apiVersion === "" && !version.running) {
      version.outputText = ""
      version.running = true
    }
    return next.state !== "unavailable"
  }

  function applyVersion(output) {
    var result = OllamaModel.parseResult(output, "version")
    if (result.ok === true && result.data && typeof result.data.version === "string") {
      apiVersion = OllamaModel.plainText(result.data.version, 80)
      versionError = ""
      versionErrorKind = ""
      updateLastErrorKind()
    } else {
      apiVersion = ""
      versionError = OllamaModel.errorFor(result, "Ollama version diagnostics failed.")
      versionErrorKind = classifyErrorKind(result, "version_error")
      updateLastErrorKind()
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
      var completedAt = Date.now()
      root.lastRefreshSucceeded = root.applyStatus(status.outputText, completedAt)
      root.lastRefreshCompletedMs = completedAt
      root.refreshCompletionSerial += 1
      root.refreshing = false
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
      if (result.ok !== true) {
        root.errorText = OllamaModel.errorFor(result, "The unload request failed.")
        root.actionErrorKind = root.classifyErrorKind(result, "unload_error")
        root.updateLastErrorKind()
      } else { root.actionErrorKind = ""; root.updateLastErrorKind() }
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
