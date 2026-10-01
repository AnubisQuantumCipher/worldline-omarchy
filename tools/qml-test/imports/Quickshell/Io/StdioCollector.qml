import QtQuick

// Test stand-in for Quickshell.Io StdioCollector: `text` and `data` (with byteLength), set by
// the fake Process in one piece, which fires onDataChanged once as a pipe read would.
QtObject {
  property bool waitForEnd: false
  property string text: ""
  property var data: ({ byteLength: 0 })
}
