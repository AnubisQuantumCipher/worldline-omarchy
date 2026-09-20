import QtQuick
import QtQuick.Layouts
import qs.Commons

// A cockpit card: optional small-caps title, then content. Fill, border, radius, and spacing
// come from the shared control tokens so themes restyle it with the rest of the shell.
Rectangle {
  id: card

  property string title: ""
  property string hint: ""          // right-aligned caption next to the title
  property bool urgent: false
  property color accentColor: Color.accent
  default property alias content: inner.data

  Layout.fillWidth: true
  implicitHeight: column.implicitHeight + Style.spacing.md * 2
  color: card.urgent ? Util.alpha(Color.urgent, 0.06) : Style.normalFill
  border.color: card.urgent ? Util.alpha(Color.urgent, 0.55) : Style.normalBorderColor
  border.width: Math.max(1, Style.normalBorderWidth)
  radius: Style.cornerRadius

  ColumnLayout {
    id: column
    anchors.fill: parent
    anchors.margins: Style.spacing.md
    spacing: Style.spacing.xs

    RowLayout {
      Layout.fillWidth: true
      visible: card.title !== ""
      spacing: Style.spacing.sm
      WlSectionTitle {
        text: card.title
        color: card.urgent ? Color.urgent : Color.muted
      }
      Item { Layout.fillWidth: true }
      Text {
        textFormat: Text.PlainText
        visible: card.hint !== ""
        text: card.hint
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        Layout.maximumWidth: Style.space(200)
      }
    }

    ColumnLayout {
      id: inner
      Layout.fillWidth: true
      spacing: Style.spacing.xs
    }
  }
}
