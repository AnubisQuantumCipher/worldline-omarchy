import QtQuick
import qs.Commons

// A state chip. `tone` is a palette role name ("accent", "urgent", "muted", "foreground") so
// Model.js can decide tones without touching QML colors; `glyph` is the text cue that carries
// the meaning when color alone would not.
Rectangle {
  id: chip

  property string label: ""
  property string glyph: ""
  property string tone: "muted"
  property bool filled: false
  property string tooltipText: ""

  readonly property color toneColor: tone === "accent" ? Color.accent
    : tone === "urgent" ? Color.urgent
    : tone === "foreground" ? Color.foreground
    : Color.muted

  implicitWidth: row.implicitWidth + Style.spacing.md * 2
  implicitHeight: row.implicitHeight + Style.spacing.xs * 2
  radius: Style.cornerRadius > 0 ? height / 2 : 0
  color: filled ? Util.alpha(toneColor, 0.22) : Util.alpha(toneColor, 0.10)
  border.color: Util.alpha(toneColor, 0.6)
  border.width: 1

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.spacing.xs
    Text {
      textFormat: Text.PlainText
      visible: chip.glyph !== ""
      text: chip.glyph
      color: chip.toneColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      text: chip.label
      color: chip.toneColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: Style.spaceReal(0.4)
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: chip.tooltipText !== ""
    acceptedButtons: Qt.NoButton
  }
}
