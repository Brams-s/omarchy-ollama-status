// API data is untrusted even when it comes from a loopback service.
var MAX_MODELS = 12
var MAX_TEXT = 160
var MAX_ERROR = 300

function plainText(value, maximum) {
  if (typeof value !== "string") return ""
  var text = value
    .replace(/<[^>]*>/g, " ")
    .replace(/[<>]/g, " ")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
  return text.slice(0, Math.max(0, Math.min(Number(maximum) || 0, MAX_ERROR)))
}

function boundedInteger(value, fallback, minimum, maximum) {
  var number = Number(value)
  if (!isFinite(number)) return fallback
  return Math.max(minimum, Math.min(maximum, Math.floor(number)))
}

function safeNumber(value) {
  var number = Number(value)
  return isFinite(number) && number >= 0 ? number : 0
}

function safeContext(value) {
  var number = safeNumber(value)
  return number > 0 ? String(Math.min(Math.floor(number), 10000000)) : ""
}

function modelFrom(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  var name = plainText(typeof value.name === "string" ? value.name : value.model, MAX_TEXT)
  if (!name) return null
  return {
    name: name,
    size: safeNumber(value.size),
    sizeVram: safeNumber(value.size_vram),
    context: safeContext(value.context_length),
    expiresAt: plainText(value.expires_at, 80)
  }
}

function hasPrimaryModel(models) {
  return Array.isArray(models) && models.length > 0 && !!models[0] && typeof models[0].name === "string" && models[0].name !== ""
}

function parseStatus(result, maximum) {
  var limit = boundedInteger(maximum, MAX_MODELS, 1, MAX_MODELS)
  if (!result || typeof result !== "object" || result.ok !== true || !result.data || !Array.isArray(result.data.models))
    return { state: "unavailable", models: [], error: "Ollama returned an invalid status response." }

  var models = []
  for (var i = 0; i < result.data.models.length && models.length < limit; i++) {
    var model = modelFrom(result.data.models[i])
    if (model) models.push(model)
  }
  return { state: models.length ? "loaded" : "idle", models: models, error: "" }
}

function parseResult(output, operation) {
  try {
    var result = JSON.parse(String(output || ""))
    if (!result || typeof result !== "object" || result.operation !== operation)
      throw new Error("invalid result")
    return result
  } catch (error) {
    return { ok: false, operation: operation, error: "Ollama returned an invalid response.", kind: "invalid_data" }
  }
}

function errorFor(result, fallback) {
  if (!result || result.ok === true) return ""
  return plainText(result.error, MAX_ERROR) || fallback
}

function formatBytes(value) {
  var amount = safeNumber(value), units = ["B", "KB", "MB", "GB", "TB"], index = 0
  if (amount <= 0) return ""
  while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index++ }
  return amount.toFixed(index > 1 ? 1 : 0) + " " + units[index]
}

function relativeExpiry(value) {
  var seconds = Math.floor((Date.parse(value) - Date.now()) / 1000)
  if (!isFinite(seconds)) return ""
  if (seconds <= 0) return "Unloads soon"
  if (seconds < 60) return "Unloads in <1m"
  if (seconds < 3600) return "Unloads in " + Math.ceil(seconds / 60) + "m"
  return "Unloads in " + Math.ceil(seconds / 3600) + "h"
}

if (typeof module !== "undefined") {
  module.exports = {
    plainText: plainText,
    boundedInteger: boundedInteger,
    safeNumber: safeNumber,
    safeContext: safeContext,
    hasPrimaryModel: hasPrimaryModel,
    parseStatus: parseStatus,
    parseResult: parseResult,
    errorFor: errorFor,
    formatBytes: formatBytes,
    relativeExpiry: relativeExpiry
  }
}
