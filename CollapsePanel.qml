import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  property var world: ({})
  property var receipt: ({})
  property string actionKind: "collapse"
  property int confirmationStep: 0
  property bool enabledAction: world && world.instanceId !== undefined && (world.state === "VALID" || actionKind === "return")

  signal requestConfirm()
  signal requestExecute()
  signal requestCancel()

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.spacing.md

    Text { textFormat: Text.PlainText;
      Layout.fillWidth: true
      text: root.actionKind === "return"
        ? "RETURN TO " + String(root.world?.alias || "CHECKPOINT")
        : "COLLAPSE " + String(root.world?.alias || "WORLD") + " INTO PRIME"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
    }

    GridLayout {
      Layout.fillWidth: true
      columns: 2
      rowSpacing: Style.spacing.sm
      columnSpacing: Style.spacing.lg

      Repeater {
        model: [
          { label: "Parent world", value: root.receipt?.parentWorld || root.world?.parentId || "—" },
          { label: "Candidate world", value: root.receipt?.candidateWorld || root.world?.id || "—" },
          { label: "Base state", value: root.receipt?.baseState?.state || root.world?.baseRoot || "—" },
          { label: "Candidate delta", value: root.receipt?.candidateDelta?.hash || String(root.world?.delta?.files?.length || 0) + " paths" },
          { label: "Foreign contamination", value: root.receipt?.foreignWorldContamination?.state || "UNEVALUATED — computed at collapse.prepare" },
          { label: "Invariant preservation", value: root.receipt?.invariantPreservation?.state || "PENDING" },
          { label: "Atomic collapse", value: root.receipt?.atomicCollapse?.state || "NOT COMMITTED" },
          { label: "Conflicts", value: root.receipt ? String(root.receipt?.conflicts?.length || 0) : "—" }
        ]

        delegate: Item {
          required property var modelData
          Layout.fillWidth: true
          implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

          Text { textFormat: Text.PlainText;
            id: labelText
            width: parent.width * 0.42
            text: modelData.label
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text { textFormat: Text.PlainText;
            id: valueText
            anchors.right: parent.right
            width: parent.width * 0.56
            text: String(modelData.value)
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
          }
        }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      implicitHeight: warningText.implicitHeight + Style.spacing.lg
      color: Util.alpha(root.confirmationStep === 0 ? Color.muted : Color.urgent, 0.14)
      radius: Style.cornerRadius

      Text { textFormat: Text.PlainText;
        id: warningText
        anchors.fill: parent
        anchors.margins: Style.spacing.md
        wrapMode: Text.WordWrap
        text: root.confirmationStep === 0
          ? "Review the exact base, delta, conflicts, contamination, and managed roots before continuing."
          : (root.actionKind === "return"
              ? "Second confirmation: atomically replace PRIME with this checkpoint?"
              : "Second confirmation: Collapse " + String(root.world?.alias || "world") + " into PRIME?")
        color: root.confirmationStep === 0 ? Color.foreground : Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Item { Layout.fillHeight: true }

    RowLayout {
      Layout.alignment: Qt.AlignHCenter
      spacing: Style.spacing.md

      Button {
        text: "Cancel"
        onClicked: root.requestCancel()
      }
      Button {
        enabled: root.enabledAction
        text: root.confirmationStep === 0
          ? "Review collapse"
          : (root.actionKind === "return" ? "RETURN" : "Collapse into PRIME")
        onClicked: {
          if (root.confirmationStep === 0) root.requestConfirm()
          else root.requestExecute()
        }
      }
    }
  }
}
