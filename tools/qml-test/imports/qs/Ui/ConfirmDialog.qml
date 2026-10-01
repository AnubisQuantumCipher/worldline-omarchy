import QtQuick

// Test stand-in for the Omarchy shell's qs.Ui ConfirmDialog.
Item {
  id: dialog
  property bool opened: false
  property string message: ""
  property string cancelText: "Cancel"
  property string confirmText: "Confirm"
  signal canceled()
  signal confirmed()
  visible: opened
  function handleKey(event) { return false }
  Text { textFormat: Text.PlainText; text: dialog.message }
}
