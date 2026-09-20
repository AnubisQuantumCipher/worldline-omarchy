import QtQuick
import qs.Commons

Text {
  textFormat: Text.PlainText
  color: Color.muted
  font.family: Style.font.family
  font.pixelSize: Style.font.caption
  font.bold: true
  font.letterSpacing: Style.spaceReal(0.8)
  topPadding: Math.ceil(Style.font.caption * 0.15)
  elide: Text.ElideRight
}
