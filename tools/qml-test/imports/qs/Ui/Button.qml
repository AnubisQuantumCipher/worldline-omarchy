import QtQuick

// Test stand-in for the Omarchy shell's qs.Ui Button: a plain-text label and a clicked signal.
Rectangle {
  id: button
  property string text: ""
  property string tooltipText: ""
  property bool selected: false
  property bool bordered: false
  property real fontSize: 13
  signal clicked()
  implicitWidth: label.implicitWidth + 12
  implicitHeight: label.implicitHeight + 8
  color: "transparent"
  Text { id: label; textFormat: Text.PlainText; anchors.centerIn: parent; text: button.text }
}
