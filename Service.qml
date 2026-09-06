import QtQuick
import Quickshell
import Quickshell.Io
import "OllamaModel.js" as OllamaModel
import "OllamaState.js" as OllamaState

Item {
  id: root

  property var shell: null
  property string state: "checking"
  property var models: []
  // Aggregate metadata is intentionally independent of the rendered model
  // limit. Panel.qml can adopt these fields without another API request.
  property int loadedModelCount: 0
  property double aggregateVramBytes: 0
  property string errorText: ""
  property string actionErrorText: ""
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
  property bool pendingRefresh: false
  readonly property string feedbackText: OllamaState.feedbackText(root)
  readonly property string pythonPath: "/usr/bin/python3"
  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("ollama_status.py").toString().replace(/^file:\/\//, ""))
  readonly property var processEnvironment: ({
    LANG: "C.UTF-8",
    LC_ALL: "C.UTF-8",
    OLLAMA_HOST: null
  })
  property int refreshIntervalSec: 15
  property int maxDisplayedModels: 12
  property bool compactMode: false
  property var _configurations: ({})
  property string _configurationSource: ""
  readonly property int nextPollInterval: state === "unavailable"
    ? Math.min(refreshIntervalSec * 1000 * Math.pow(2, Math.min(failureCount, 3)), 300000)
    : refreshIntervalSec * 1000

  function plain(value, maximum) { return OllamaModel.plainText(value, maximum) }
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
    var next = selected ? selected.settings : OllamaModel.normalizeSettings({})
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
    var nextSettings = OllamaModel.normalizeSettings(settings)
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
    if (busy) return false
    if (status.running) {
      pendingRefresh = true
      status.superseded = true
      refreshing = true
      terminate(status, statusKill)
      return true
    }
    status.outputText = ""
    status.expected = true
    status.timedOut = false
    status.superseded = false
    refreshing = true
    lastRefreshStartedMs = Date.now()
    statusDeadline.restart()
    status.running = true
    return true
  }

  function unload(name) {
    if (!OllamaState.beginUnload(root, name, action.running)) return false
    action.outputText = ""
    action.expected = true
    action.timedOut = false
    action.command = [pythonPath, scriptPath, "unload", pendingModel]
    actionDeadline.restart()
    action.running = true
    return true
  }

  function applyStatus(output, completedAt) {
    var result = OllamaModel.parseResult(output, "status")
    if (result.ok !== true) {
      return OllamaState.applyStatus(root, {
        state: "unavailable", models: [], loadedModelCount: 0, aggregateVramBytes: 0,
        error: OllamaModel.errorFor(result, "Ollama status request failed."),
        kind: OllamaModel.classifyErrorKind(result, "status_error")
      }, completedAt)
    }
    var next = OllamaModel.parseStatus(result, maxDisplayedModels)
    var succeeded = OllamaState.applyStatus(root, {
      state: next.state, models: next.models, loadedModelCount: next.loadedModelCount,
      aggregateVramBytes: next.aggregateVramBytes, error: next.error,
      kind: next.state === "unavailable" ? "invalid_data" : ""
    }, completedAt)
    if (next.state !== "unavailable" && apiVersion === "" && !version.running) {
      version.outputText = ""
      version.expected = true
      version.timedOut = false
      versionDeadline.restart()
      version.running = true
    }
    return succeeded
  }

  function applyVersion(output) {
    var result = OllamaModel.parseResult(output, "version")
    if (result.ok === true && result.data && typeof result.data.version === "string") {
      apiVersion = OllamaModel.plainText(result.data.version, 80)
      versionError = ""
      versionErrorKind = ""
      OllamaState.updateLastErrorKind(root)
    } else {
      apiVersion = ""
      versionError = OllamaModel.errorFor(result, "Ollama version diagnostics failed.")
      versionErrorKind = OllamaModel.classifyErrorKind(result, "version_error")
      OllamaState.updateLastErrorKind(root)
    }
  }

  function recoverStatusStart() {
    if (status.running || !status.expected) return
    status.expected = false
    var completedAt = Date.now()
    var output = '{"ok":false,"operation":"status","kind":"missing_dependency","error":"Missing dependency: python3 is required to run Ollama Status."}'
    lastRefreshSucceeded = applyStatus(output, completedAt)
    lastRefreshCompletedMs = completedAt
    refreshCompletionSerial += 1
    refreshing = false
    pollTimer.restart()
    if (pendingRefresh) pendingRefresh = false
  }

  function recoverVersionStart() {
    if (version.running || !version.expected) return
    version.expected = false
    applyVersion('{"ok":false,"operation":"version","kind":"missing_dependency","error":"Missing dependency: python3 is required to run Ollama Status."}')
  }

  function recoverActionStart() {
    if (action.running || !action.expected) return
    action.expected = false
    OllamaState.failUnloadStart(root)
    refresh()
  }

  function terminate(process, killTimer) {
    if (!process.running) return
    process.terminating = true
    process.running = false
    killTimer.restart()
  }

  function destroyProcess(process) {
    if (!process.running) return
    process.signal(15)
  }

  function shutdown() {
    pendingRefresh = false
    pollTimer.stop()
    statusDeadline.stop()
    statusKill.stop()
    versionDeadline.stop()
    versionKill.stop()
    actionDeadline.stop()
    actionKill.stop()
    destroyProcess(status)
    destroyProcess(version)
    destroyProcess(action)
  }

  Process {
    id: status
    command: [root.pythonPath, root.scriptPath, "status"]
    clearEnvironment: true
    environment: root.processEnvironment
    property string outputText: ""
    property bool expected: false
    property bool timedOut: false
    property bool terminating: false
    property bool superseded: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { status.outputText = text }
    }
    onRunningChanged: if (!running && expected) Qt.callLater(root.recoverStatusStart)
    onExited: function() {
      statusDeadline.stop()
      statusKill.stop()
      status.expected = false
      status.terminating = false
      var wasSuperseded = status.superseded
      status.superseded = false
      if (!wasSuperseded) {
        if (status.timedOut) status.outputText = '{"ok":false,"operation":"status","kind":"operation_timeout","error":"The local Ollama request timed out."}'
        var completedAt = Date.now()
        root.lastRefreshSucceeded = root.applyStatus(status.outputText, completedAt)
        root.lastRefreshCompletedMs = completedAt
        root.refreshCompletionSerial += 1
        root.refreshing = false
        pollTimer.restart()
      }
      status.timedOut = false
      if (pendingRefresh) {
        pendingRefresh = false
        Qt.callLater(function() { root.refresh() })
      }
    }
  }

  Process {
    id: version
    command: [root.pythonPath, root.scriptPath, "version"]
    clearEnvironment: true
    environment: root.processEnvironment
    property string outputText: ""
    property bool expected: false
    property bool timedOut: false
    property bool terminating: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { version.outputText = text }
    }
    onRunningChanged: if (!running && expected) Qt.callLater(root.recoverVersionStart)
    onExited: function() {
      versionDeadline.stop()
      versionKill.stop()
      version.expected = false
      version.terminating = false
      if (version.timedOut) version.outputText = '{"ok":false,"operation":"version","kind":"operation_timeout","error":"The local Ollama request timed out."}'
      version.timedOut = false
      root.applyVersion(version.outputText)
    }
  }

  Process {
    id: action
    command: []
    clearEnvironment: true
    environment: root.processEnvironment
    property string outputText: ""
    property bool expected: false
    property bool timedOut: false
    property bool terminating: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() { action.outputText = text }
    }
    onRunningChanged: if (!running && expected) Qt.callLater(root.recoverActionStart)
    onExited: function() {
      actionDeadline.stop()
      actionKill.stop()
      action.expected = false
      action.terminating = false
      if (action.timedOut) action.outputText = '{"ok":false,"operation":"unload","kind":"operation_timeout","error":"The local Ollama request timed out."}'
      action.timedOut = false
      var result = OllamaModel.parseResult(action.outputText, "unload")
      if (result.ok !== true) {
        OllamaState.finishUnload(root, OllamaModel.errorFor(result, "The unload request failed."), OllamaModel.classifyErrorKind(result, "unload_error"))
      } else OllamaState.finishUnload(root, "", "")
      root.refresh()
    }
  }

  Timer { id: statusDeadline; interval: 5000; repeat: false; onTriggered: { status.timedOut = true; root.terminate(status, statusKill) } }
  Timer { id: statusKill; interval: 750; repeat: false; onTriggered: if (status.running) status.signal(9) }
  Timer { id: versionDeadline; interval: 5000; repeat: false; onTriggered: { version.timedOut = true; root.terminate(version, versionKill) } }
  Timer { id: versionKill; interval: 750; repeat: false; onTriggered: if (version.running) version.signal(9) }
  Timer { id: actionDeadline; interval: 5000; repeat: false; onTriggered: { action.timedOut = true; root.terminate(action, actionKill) } }
  Timer { id: actionKill; interval: 750; repeat: false; onTriggered: if (action.running) action.signal(9) }

  Timer {
    id: pollTimer
    interval: root.nextPollInterval
    repeat: false
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
  Component.onDestruction: root.shutdown()
}
