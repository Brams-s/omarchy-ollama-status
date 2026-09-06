import QtQuick
import QtQuick.Window
import "../../OllamaModel.js" as OllamaModel
import "RowTestStyle.js" as Style
import "RowTestStyle.js" as Color

Window {
  id: harness
  width: 400
  height: 300
  visible: true
  property bool mutateMissingIndex: Qt.application.arguments.indexOf("--mutate-missing-index") !== -1

  function fail(message) {
    var text = String(message)
    console.error("FAIL: " + text)
    Qt.exit(text.indexOf("row-index:") === 0 ? 1 : 2)
  }
  function require(condition, message) { if (!condition) throw new Error(message) }
  function count(source, needle) {
    var at = 0, total = 0
    while ((at = source.indexOf(needle, at)) !== -1) { total++; at += needle.length }
    return total
  }
  function fileText(url) {
    var request = new XMLHttpRequest()
    request.open("GET", url, false)
    request.send()
    if (request.status !== 0 && request.status !== 200) throw new Error("Panel.qml read failed: " + request.status)
    return request.responseText.replace(/\r\n/g, "\n")
  }
  function functionText(source, name) {
    var start = "  function " + name + "("
    require(count(source, start) === 1, "function anchor drift: " + name)
    var offset = source.indexOf(start)
    var end = source.indexOf("\n  }", offset)
    require(end !== -1, "function close drift: " + name)
    return source.slice(offset, end + 4)
  }
  function repeaterText(source) {
    var start = "          Repeater {\n            id: modelRepeater"
    require(count(source, start) === 1, "repeater anchor drift")
    var offset = source.indexOf(start), depth = 0
    for (var i = offset; i < source.length; i++) {
      if (source[i] === "{") depth++
      else if (source[i] === "}" && --depth === 0) return source.slice(offset, i + 1)
    }
    throw new Error("repeater close drift")
  }
  function dynamicSource() {
    var panel = fileText(Qt.resolvedUrl("../../Panel.qml"))
    var repeater = repeaterText(panel)
    var requiredIndex = "              required property int index"
    require(count(repeater, requiredIndex) === 1, "row-index declaration missing or duplicated")
    if (mutateMissingIndex) repeater = repeater.replace(requiredIndex + "\n", "")
    return 'import QtQuick\nimport "../../OllamaModel.js" as OllamaModel\nimport "RowTestStyle.js" as Style\nimport "RowTestStyle.js" as Color\n'
      + 'Item { id: root; width: 380; height: 260; property var models: [{ displayName: "first", modelId: "first-id", actionable: true, size: 0, sizeVram: 0, context: "", expiresAt: "" }, { displayName: "second", modelId: "second-id", actionable: true, size: 0, sizeVram: 0, context: "", expiresAt: "" }]; property int selectedIndex: 0; property bool confirmUnload: false; property string confirmedModelName: ""; property color foreground: "white"; property color urgent: "red"; property var ollamaService: ({ busy: false, pendingModel: "", calls: [], unload: function(name) { this.calls.push(name); return true } }); function plain(value, limit) { return OllamaModel.plainText(value, limit) } function ensureSelectedVisible() {} function setCopyFeedback() {}\n'
      + functionText(panel, "clearUnloadConfirmation") + "\n"
      + functionText(panel, "actionableModelIdAt") + "\n"
      + functionText(panel, "selectStep") + "\n"
      + functionText(panel, "requestUnload") + "\n"
      + 'Column { id: contentColumn; width: parent.width; ' + repeater + ' } property alias rows: modelRepeater }'
  }
  function directChild(row, propertyName) {
    var matches = []
    for (var i = 0; i < row.children.length; i++) if (propertyName in row.children[i]) matches.push(row.children[i])
    require(matches.length === 1, "row-index: expected one " + propertyName + " child, got " + matches.length)
    return matches[0]
  }
  function verifyRow(row, index, expectedBorder, expectedLabel) {
    require(row.index === index, "row-index: expected " + index + ", got " + row.index)
    var border = directChild(row, "border")
    var label = directChild(row, "text")
    var mouse = directChild(row, "clicked")
    require(border.border.width === expectedBorder, "row-index: border for row " + index)
    require(label.text === expectedLabel, "row-index: label for row " + index + " is " + label.text)
    return mouse
  }
  function run() {
    try {
      var root = Qt.createQmlObject(dynamicSource(), harness, "actual-panel-row.qml")
      Qt.callLater(function() {
        try {
          require(root.rows.count === 2, "row-index: expected two rows")
          var first = root.rows.itemAt(0), second = root.rows.itemAt(1)
          require(first && second, "row-index: repeater items missing")
          verifyRow(first, 0, 1, "Unload")
          var secondMouse = verifyRow(second, 1, 0, "Unload")
          secondMouse.clicked(null)
          verifyRow(first, 0, 0, "Unload")
          verifyRow(second, 1, 1, "Confirm")
          require(root.ollamaService.calls.length === 0, "row-index: first second-row click unloaded")
          secondMouse.clicked(null)
          require(root.ollamaService.calls.length === 1 && root.ollamaService.calls[0] === "second-id", "row-index: second row exact ID")
          require(!root.confirmUnload && root.confirmedModelName === "", "row-index: confirmation did not clear")
          verifyRow(second, 1, 1, "Unload")
          root.selectStep(-1)
          var firstMouse = verifyRow(first, 0, 1, "Unload")
          firstMouse.clicked(null)
          verifyRow(first, 0, 1, "Confirm")
          firstMouse.clicked(null)
          require(root.ollamaService.calls.length === 2 && root.ollamaService.calls[1] === "first-id", "row-index: first row exact ID")
          console.warn("PASS: model row interaction" + (mutateMissingIndex ? " mutation" : ""))
          Qt.callLater(function() { Qt.exit(0) })
        } catch (error) { fail(error.message || error) }
      })
    } catch (error) { fail(error.message || error) }
  }
  Component.onCompleted: run()
}
