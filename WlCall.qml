import QtQuick
import Quickshell.Io

// One `worldline …` invocation at a time. Every action the cockpit takes goes through the
// CLI as an argv array (never a shell string), so an agent-chosen alias or path is data.
// `run(argv, done)` returns false when a call is already in flight; `done(exitCode, stdout,
// stderr)` fires once both streams have drained.
Item {
  id: root

  readonly property bool busy: process.running
  property var _done: null
  property string lastCommand: ""

  function run(argv, done) {
    if (process.running) return false
    root._done = done
    root.lastCommand = argv.join(" ")
    process.command = argv
    process.running = true
    return true
  }

  Process {
    id: process
    running: false
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var callback = root._done
      root._done = null
      if (callback) callback(exitCode, String(out.text || ""), String(err.text || ""))
    }
  }
}
