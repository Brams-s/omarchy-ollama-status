const assert = require("assert")
const fs = require("fs")
const model = require("./OllamaModel.js")

function normalizeSettings(settings) {
  settings = settings && typeof settings === "object" ? settings : {}
  return {
    refreshIntervalSec: model.boundedInteger(settings.refreshIntervalSec, 15, 5, 300),
    maxDisplayedModels: model.boundedInteger(settings.maxDisplayedModels, 12, 1, 12),
    compactMode: settings.compactMode === true || settings.compactMode === "true" || settings.compactMode === 1 || settings.compactMode === "1"
  }
}

function classifyErrorKind(result, fallback) {
  const kind = model.plainText(result && result.kind, 80)
  if (kind === "missing_dependency") {
    const message = model.plainText(result && result.error, 160).toLowerCase()
    if (message.includes("python3")) return "missing_python3"
    if (message.includes("curl")) return "missing_curl"
    return "missing_dependency"
  }
  return ["unsafe_endpoint", "transport_error", "response_too_large", "invalid_data", "invalid_request", "internal_error", "api_error"].includes(kind) ? kind : fallback
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
assert.deepStrictEqual(normalizeSettings({ refreshIntervalSec: 1, maxDisplayedModels: 99, compactMode: "true" }), { refreshIntervalSec: 5, maxDisplayedModels: 12, compactMode: true })
assert.deepStrictEqual(normalizeSettings({ refreshIntervalSec: "invalid", maxDisplayedModels: 0, compactMode: false }), { refreshIntervalSec: 15, maxDisplayedModels: 1, compactMode: false })
assert.strictEqual(classifyErrorKind({ kind: "missing_dependency", error: "Missing dependency: python3 is required." }, "status_error"), "missing_python3")
assert.strictEqual(classifyErrorKind({ kind: "missing_dependency", error: "Missing dependency: curl is required." }, "status_error"), "missing_curl")
assert.strictEqual(classifyErrorKind({ kind: "<b>unexpected</b>" }, "status_error"), "status_error")
const serviceSource = fs.readFileSync("Service.qml", "utf8")
assert.match(serviceSource, /function configure\(settings, sourceId\)/)
assert.match(serviceSource, /function unconfigure\(sourceId\)/)
assert.match(serviceSource, /maxDisplayedModels\)/)
assert.match(serviceSource, /models = models\.slice\(0, maxDisplayedModels\)/)
assert.match(serviceSource, /lastRefreshCompletedMs/)
assert.match(serviceSource, /versionErrorKind/)
assert.match(serviceSource, /loadedModelCount/)
assert.match(serviceSource, /aggregateVramBytes/)
assert.match(serviceSource, /item\.actionable === true && item\.modelId === name/)
const widgetSource = fs.readFileSync("BarWidget.qml", "utf8")
assert.doesNotMatch(widgetSource, /String\(root\)/)
assert.match(widgetSource, /moduleSlots/)
assert.match(widgetSource, /slotWindow\(slot\)/)
assert.match(widgetSource, /configuredServiceSource/)
console.log("ollama-status: helper checks passed")
