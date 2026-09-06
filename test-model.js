const assert = require("assert")
const fs = require("fs")
const model = require("./OllamaModel.js")
const stateModel = require("./OllamaState.js")

function fixture() {
  return {
    plain: model.plainText,
    models: [{ actionable: true, modelId: "exact-model", displayName: "Exact model" }],
    loadedModelCount: 1,
    aggregateVramBytes: 4,
    state: "loaded",
    errorText: "",
    actionErrorText: "",
    statusErrorKind: "",
    versionError: "",
    versionErrorKind: "",
    actionErrorKind: "",
    lastErrorKind: "",
    lastSuccessfulRefreshMs: 0,
    localApiStatus: "available",
    failureCount: 0,
    busy: false,
    pendingModel: ""
  }
}

function successfulStatus() {
  return { state: "loaded", models: [{ actionable: true, modelId: "refreshed-model", displayName: "Refreshed model" }], loadedModelCount: 3, aggregateVramBytes: 96, error: "", kind: "" }
}

function failedStatus(message) {
  return { state: "unavailable", models: [], loadedModelCount: 0, aggregateVramBytes: 0, error: message, kind: "transport_error" }
}

assert.strictEqual(model.plainText(" <b>model</b>\n\u061c\u202Ename\u0000 ", 160), "model name")
assert.strictEqual(model.plainText("<img src=x>", 160), "")
assert.strictEqual(model.boundedInteger(999, 12, 1, 12), 12)
assert.strictEqual(model.canonicalModelId("exact-model:1"), "exact-model:1")
assert.strictEqual(model.canonicalModelId(" model"), "")
assert.strictEqual(model.canonicalModelId("x".repeat(257)), "")

const parsed = model.parseStatus({
  ok: true,
  operation: "status",
  data: { models: [
    { name: "<b>safe</b>\nname", size: 9, size_vram: 2, context_length: 4096 },
    { name: "\u202E", size: 1 }
  ] }
}, 1)
assert.strictEqual(parsed.state, "loaded")
assert.deepStrictEqual(parsed.models, [{ name: "safe name", displayName: "safe name", modelId: "", actionable: false, size: 9, sizeVram: 2, context: "4096", expiresAt: "" }])
assert.strictEqual(parsed.loadedModelCount, 2)
assert.strictEqual(parsed.aggregateVramBytes, 0)
assert.strictEqual(model.hasPrimaryModel(parsed.models), true)
assert.strictEqual(model.hasPrimaryModel([]), false)
assert.strictEqual(model.hasPrimaryModel(null), false)
assert.strictEqual(model.parseStatus({ ok: true, data: { models: "bad" } }, 12).state, "unavailable")
const canonical = model.parseStatus({ ok: true, operation: "status", data: { models: [{ name: "exact-model", action_id: "exact-model", size_vram: 12 }, { name: "x".repeat(300), size_vram: 8 }], loadedModelCount: 42, aggregateVramBytes: 20 } }, 1)
assert.strictEqual(canonical.models.length, 1)
assert.deepStrictEqual(canonical.models[0], { name: "exact-model", displayName: "exact-model", modelId: "exact-model", actionable: true, size: 0, sizeVram: 12, context: "", expiresAt: "" })
assert.strictEqual(canonical.loadedModelCount, 42)
assert.strictEqual(canonical.aggregateVramBytes, 20)
const overlong = model.parseStatus({ ok: true, operation: "status", data: { models: [{ name: "x".repeat(257) }], loadedModelCount: 1, aggregateVramBytes: 0 } }, 12)
assert.strictEqual(overlong.models[0].displayName.length, 160)
assert.strictEqual(overlong.models[0].modelId, "")
assert.strictEqual(overlong.models[0].actionable, false)
assert.deepStrictEqual(model.normalizeSettings({ refreshIntervalSec: 1, maxDisplayedModels: 99, compactMode: "true" }), { refreshIntervalSec: 5, maxDisplayedModels: 12, compactMode: true })
assert.deepStrictEqual(model.normalizeSettings({ refreshIntervalSec: "invalid", maxDisplayedModels: 0, compactMode: false }), { refreshIntervalSec: 15, maxDisplayedModels: 1, compactMode: false })
assert.strictEqual(model.classifyErrorKind({ kind: "missing_dependency", error: "Missing dependency: python3 is required." }, "status_error"), "missing_python3")
assert.strictEqual(model.classifyErrorKind({ kind: "missing_dependency", error: "Missing dependency: curl is required." }, "status_error"), "missing_curl")
assert.strictEqual(model.classifyErrorKind({ kind: "operation_timeout" }, "status_error"), "operation_timeout")
assert.strictEqual(model.classifyErrorKind({ kind: "<b>unexpected</b>" }, "status_error"), "status_error")

// These cover pure production transition semantics, not Qt process/timer signals.
{
  const state = fixture()
  assert.strictEqual(stateModel.beginUnload(state, "exact-model", false), true)
  assert.strictEqual(state.pendingModel, "exact-model")
  stateModel.finishUnload(state, "Unload rejected", "api_error")
  assert.strictEqual(state.actionErrorText, "Unload rejected")
  state.errorText = "Older status error"
  state.statusErrorKind = "transport_error"
  state.failureCount = 2
  state.lastSuccessfulRefreshMs = 3
  const outcome = successfulStatus()
  assert.strictEqual(stateModel.applyStatus(state, outcome, 10), true)
  assert.deepStrictEqual(state.models, outcome.models)
  assert.strictEqual(state.loadedModelCount, 3)
  assert.strictEqual(state.aggregateVramBytes, 96)
  assert.strictEqual(state.state, "loaded")
  assert.strictEqual(state.localApiStatus, "available")
  assert.strictEqual(state.actionErrorText, "Unload rejected", "successful status retains unload feedback")
  assert.strictEqual(state.actionErrorKind, "api_error", "successful status retains unload feedback kind")
  assert.strictEqual(state.errorText, "")
  assert.strictEqual(state.statusErrorKind, "")
  assert.strictEqual(state.failureCount, 0)
  assert.strictEqual(state.lastSuccessfulRefreshMs, 10)
}
{
  const state = fixture()
  stateModel.beginUnload(state, "exact-model", false)
  stateModel.finishUnload(state, "Unload rejected", "api_error")
  state.failureCount = 2
  state.lastSuccessfulRefreshMs = 7
  assert.strictEqual(stateModel.applyStatus(state, failedStatus("Status unavailable"), 11), false)
  assert.strictEqual(state.actionErrorText, "Unload rejected")
  assert.strictEqual(state.actionErrorKind, "api_error")
  assert.strictEqual(state.errorText, "Status unavailable")
  assert.deepStrictEqual(state.models, [])
  assert.strictEqual(state.loadedModelCount, 0)
  assert.strictEqual(state.aggregateVramBytes, 0)
  assert.strictEqual(state.state, "unavailable")
  assert.strictEqual(state.localApiStatus, "unavailable")
  assert.strictEqual(state.statusErrorKind, "transport_error")
  assert.strictEqual(state.failureCount, 3)
  assert.strictEqual(state.lastSuccessfulRefreshMs, 7)
  assert.strictEqual(stateModel.feedbackText(state), "Unload: Unload rejected\nStatus: Status unavailable")
}
{
  const state = fixture()
  stateModel.finishUnload(state, "Older unload failure", "api_error")
  stateModel.applyStatus(state, successfulStatus(), 12)
  assert.strictEqual(state.actionErrorText, "Older unload failure")
  stateModel.applyStatus(state, failedStatus("Older status failure"), 13)
  assert.strictEqual(state.actionErrorText, "Older unload failure")
  assert.strictEqual(state.errorText, "Older status failure")
  stateModel.applyStatus(state, failedStatus("Repeated status failure"), 14)
  assert.strictEqual(state.actionErrorText, "Older unload failure", "repeated status retains action feedback")
}
{
  const state = fixture()
  state.actionErrorText = "Keep this unload error"
  state.actionErrorKind = "api_error"
  state.busy = true
  assert.strictEqual(stateModel.beginUnload(state, "exact-model", false), false)
  assert.strictEqual(state.actionErrorText, "Keep this unload error")
  state.busy = false
  for (const [name, running] of [["exact-model", true], [42, false], ["missing", false]]) {
    assert.strictEqual(stateModel.beginUnload(state, name, running), false)
    assert.strictEqual(state.actionErrorText, "Keep this unload error")
    assert.strictEqual(state.actionErrorKind, "api_error")
  }
  state.models.push({ actionable: false, modelId: "not-actionable" })
  assert.strictEqual(stateModel.beginUnload(state, "not-actionable", false), false)
  assert.strictEqual(state.actionErrorText, "Keep this unload error")
}
{
  const state = fixture()
  state.errorText = "Existing status error"
  state.statusErrorKind = "transport_error"
  state.versionError = "Existing version diagnostic"
  state.versionErrorKind = "version_error"
  state.actionErrorText = "Old unload error"
  state.actionErrorKind = "api_error"
  assert.strictEqual(stateModel.beginUnload(state, "exact-model", false), true)
  assert.strictEqual(state.pendingModel, "exact-model")
  assert.strictEqual(state.actionErrorText, "")
  assert.strictEqual(state.actionErrorKind, "")
  assert.strictEqual(state.errorText, "Existing status error")
  assert.strictEqual(state.versionError, "Existing version diagnostic")
  assert.strictEqual(state.versionErrorKind, "version_error")
  assert.strictEqual(state.lastErrorKind, "transport_error")
  stateModel.finishUnload(state, "", "")
  assert.strictEqual(state.errorText, "Existing status error", "successful unload keeps unrelated status error")
}
{
  const state = fixture()
  assert.strictEqual(stateModel.beginUnload(state, "exact-model", false), true)
  stateModel.failUnloadStart(state)
  assert.strictEqual(state.busy, false)
  assert.strictEqual(state.pendingModel, "")
  assert.strictEqual(state.actionErrorKind, "missing_python3")
  stateModel.applyStatus(state, successfulStatus(), 15)
  assert.strictEqual(state.actionErrorText, "The unload helper could not start.")
  stateModel.applyStatus(state, failedStatus("Status after start failure"), 16)
  assert.strictEqual(state.actionErrorText, "The unload helper could not start.")
  assert.strictEqual(state.errorText, "Status after start failure")
}
{
  const first = fixture()
  const second = fixture()
  stateModel.finishUnload(first, "First only", "api_error")
  stateModel.applyStatus(second, failedStatus("Second only"), 17)
  assert.strictEqual(first.errorText, "")
  assert.strictEqual(second.actionErrorText, "")
}
{
  const state = fixture()
  state.actionErrorText = "<b>" + "a".repeat(400) + "</b>"
  state.errorText = "<i>" + "s".repeat(400) + "</i>"
  const feedback = stateModel.feedbackText(state)
  const [actionLine, statusLine] = feedback.split("\n")
  assert.strictEqual(actionLine.length, "Unload: ".length + 300)
  assert.strictEqual(statusLine.length, "Status: ".length + 300)
}
const serviceSource = fs.readFileSync("Service.qml", "utf8")
assert.match(serviceSource, /function configure\(settings, sourceId\)/)
assert.match(serviceSource, /function unconfigure\(sourceId\)/)
assert.match(serviceSource, /maxDisplayedModels\)/)
assert.match(serviceSource, /models = models\.slice\(0, maxDisplayedModels\)/)
assert.match(serviceSource, /lastRefreshCompletedMs/)
assert.match(serviceSource, /versionErrorKind/)
assert.match(serviceSource, /loadedModelCount/)
assert.match(serviceSource, /aggregateVramBytes/)
assert.match(serviceSource, /OllamaState\.beginUnload\(root, name, action\.running\)/)
assert.match(serviceSource, /readonly property string feedbackText: OllamaState\.feedbackText\(root\)/)
const widgetSource = fs.readFileSync("BarWidget.qml", "utf8")
assert.doesNotMatch(widgetSource, /String\(root\)/)
assert.match(widgetSource, /moduleSlots/)
assert.match(widgetSource, /slotWindow\(slot\)/)
assert.match(widgetSource, /configuredServiceSource/)
console.log("ollama-status: helper checks passed")
