// Stateless service transitions shared by QML and Node semantics tests.
function clean(state, value, limit) {
  return state && typeof state.plain === "function" ? state.plain(value, limit) : ""
}

function updateLastErrorKind(state) {
  state.lastErrorKind = state.statusErrorKind || state.versionErrorKind || state.actionErrorKind || ""
}

function beginUnload(state, name, actionRunning) {
  if (!state || state.busy || actionRunning || typeof name !== "string" || !Array.isArray(state.models)) return false
  var model = ""
  for (var i = 0; i < state.models.length; i++) {
    var item = state.models[i]
    if (item && item.actionable === true && item.modelId === name) {
      model = item.modelId
      break
    }
  }
  if (model === "") return false
  state.busy = true
  state.pendingModel = model
  state.actionErrorText = ""
  state.actionErrorKind = ""
  updateLastErrorKind(state)
  return true
}

function applyStatus(state, outcome, completedAt) {
  state.models = outcome.models
  state.loadedModelCount = outcome.loadedModelCount
  state.aggregateVramBytes = outcome.aggregateVramBytes
  state.state = outcome.state
  state.errorText = clean(state, outcome.error, 300)
  state.localApiStatus = outcome.state === "unavailable" ? "unavailable" : "available"
  state.statusErrorKind = outcome.state === "unavailable" ? outcome.kind : ""
  if (outcome.state !== "unavailable") state.lastSuccessfulRefreshMs = completedAt
  state.failureCount = outcome.state === "unavailable" ? state.failureCount + 1 : 0
  updateLastErrorKind(state)
  return outcome.state !== "unavailable"
}

function finishUnload(state, message, kind) {
  state.busy = false
  state.pendingModel = ""
  if (message) {
    state.actionErrorText = clean(state, message, 300)
    state.actionErrorKind = kind || "unload_error"
  }
  updateLastErrorKind(state)
}

function failUnloadStart(state) {
  finishUnload(state, "The unload helper could not start.", "missing_python3")
}

function feedbackText(state) {
  var action = clean(state, state.actionErrorText, 300)
  var status = clean(state, state.errorText, 300)
  if (action && status) return "Unload: " + action + "\nStatus: " + status
  return action || status
}

if (typeof module !== "undefined") {
  module.exports = {
    updateLastErrorKind: updateLastErrorKind,
    beginUnload: beginUnload,
    applyStatus: applyStatus,
    finishUnload: finishUnload,
    failUnloadStart: failUnloadStart,
    feedbackText: feedbackText
  }
}
