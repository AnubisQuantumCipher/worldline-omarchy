pragma Singleton
import QtQuick

// Test stand-in for the Omarchy shell's qs.Commons Util.
QtObject {
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
}
