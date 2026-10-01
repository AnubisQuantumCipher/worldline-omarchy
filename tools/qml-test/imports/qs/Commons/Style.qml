pragma Singleton
import QtQuick

// Test stand-in for the Omarchy shell's qs.Commons Style (only the tokens the plugin reads).
QtObject {
  readonly property QtObject font: QtObject {
    readonly property string family: "monospace"
    readonly property real caption: 11
    readonly property real body: 13
    readonly property real title: 15
    readonly property real heading: 18
    readonly property real icon: 14
  }
  readonly property QtObject spacing: QtObject {
    readonly property real xxs: 2
    readonly property real xs: 4
    readonly property real sm: 6
    readonly property real md: 10
    readonly property real lg: 14
  }
  readonly property real cornerRadius: 4
  readonly property color normalFill: "#161b22"
  readonly property color normalBorderColor: "#30363d"
  readonly property real normalBorderWidth: 1
  function space(n) { return n * 4 }
  function spaceReal(n) { return n }
}
