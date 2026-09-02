const assert = require("assert")
const model = require("./OllamaModel.js")

assert.strictEqual(model.plainText(" <b>model</b>\n\u061c\u202Ename\u0000 ", 160), "model name")
assert.strictEqual(model.plainText("<img src=x>", 160), "")
assert.strictEqual(model.boundedInteger(999, 12, 1, 12), 12)

const parsed = model.parseStatus({
  ok: true,
  operation: "status",
  data: { models: [
    { name: "<b>safe</b>\nname", size: 9, size_vram: 2, context_length: 4096 },
    { name: "\u202E", size: 1 }
  ] }
}, 1)
assert.strictEqual(parsed.state, "loaded")
assert.deepStrictEqual(parsed.models, [{ name: "safe name", size: 9, sizeVram: 2, context: "4096", expiresAt: "" }])
assert.strictEqual(model.hasPrimaryModel(parsed.models), true)
assert.strictEqual(model.hasPrimaryModel([]), false)
assert.strictEqual(model.hasPrimaryModel(null), false)
assert.strictEqual(model.parseStatus({ ok: true, data: { models: "bad" } }, 12).state, "unavailable")
console.log("ollama-status: helper checks passed")
