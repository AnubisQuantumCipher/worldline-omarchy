import QtQuick
import QtQuick.Layouts
import qs.Commons

// Key on the left, value on the right, value elided in the middle so hashes keep both ends.
// `full` shows the whole value wrapped instead (for the details disclosure).
RowLayout {
  id: row

  property string k: ""
  property string v: ""
  property color vColor: Color.foreground
  property bool full: false
  property bool mono: false

  Layout.fillWidth: true
  spacing: Style.spacing.sm

  Text {
    textFormat: Text.PlainText
    text: row.k
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    Layout.alignment: Qt.AlignTop
  }
  Item { Layout.fillWidth: true; visible: !row.full }
  Text {
    textFormat: Text.PlainText
    Layout.fillWidth: row.full
    Layout.maximumWidth: row.full ? -1 : Style.space(220)
    text: row.v
    color: row.vColor
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: row.full ? Text.ElideNone : Text.ElideMiddle
    wrapMode: row.full ? Text.WrapAnywhere : Text.NoWrap
    horizontalAlignment: row.full ? Text.AlignLeft : Text.AlignRight
    maximumLineCount: row.full ? 6 : 1
  }
}
