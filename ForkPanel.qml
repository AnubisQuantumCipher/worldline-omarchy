import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Mission creation. Two deliberate shapes:
//   SINGLE   one adapter, one alias  -> `worldline fork ALIAS --mission-text T --json -- AGENT`
//   RACE     exactly three adapters  -> `worldline race --detach --name N --mission-text T --agent A --agent B --agent C --json`
// Nothing is auto-picked: the operator chooses the agents, sees each adapter's probe state and
// reason, and reads the spend statement before launching.
Item {
  id: root

  property var adapters: []
  property var worlds: []
  property bool initialized: false
  property string signalState: "live"
  property bool fixture: false
  property var cliEnvironment: ({})
  property string primeLabel: "PRIME"
  property bool adaptersLoading: false

  property bool raceMode: false
  property string mission: ""
  property string selectedAgent: ""
  property var raceAgents: []
  property string aliasText: ""
  property string raceName: ""
  property var failure: null
  property bool touchedAlias: false

  readonly property bool busy: launchCall.busy
  readonly property var availableAdapters: root.adapters.filter(function(a) { return a && a.state === "AVAILABLE" })
  readonly property string effectiveAlias: root.aliasText.trim() !== "" ? root.aliasText.trim() : root.suggestAlias()
  readonly property bool aliasTaken: Model.worldIndexByAlias(root.worlds, root.effectiveAlias) >= 0
  readonly property bool raceNameTaken: {
    var name = root.raceName.trim()
    var lanes = ["alpha", "beta", "gamma"]
    for (var i = 0; i < lanes.length; i++)
      if (Model.worldIndexByAlias(root.worlds, (name !== "" ? name + "-" : "") + lanes[i]) >= 0) return true
    return false
  }
  readonly property string blockedReason: root.fixture ? "fixture data — launching is disabled"
    : !root.initialized ? "no PRIME — register a root first"
    : root.signalState !== "live" ? "daemon signal is " + root.signalState
    : root.mission.trim() === "" ? "write a mission"
    : root.raceMode
      ? (root.raceAgents.length !== 3 ? "choose exactly three adapters (" + root.raceAgents.length + " chosen)" : root.raceNameTaken ? "those lane aliases already exist — set a race name" : "")
      : (root.selectedAgent === "" ? "choose an adapter" : root.aliasTaken ? "alias already exists" : root.effectiveAlias.indexOf("prime-") === 0 || root.effectiveAlias === "PRIME" ? "reserved alias" : "")
  readonly property bool canLaunch: root.blockedReason === "" && !root.busy
  readonly property bool editing: missionEditor.activeFocus || aliasField.activeFocus || raceNameField.activeFocus

  signal launched(var summary)
  signal back()
  signal requestFocus()
  signal refreshAdapters()

  function suggestAlias() {
    var base = root.selectedAgent !== "" ? root.selectedAgent : "world"
    var n = 1
    while (Model.worldIndexByAlias(root.worlds, base + "-" + n) >= 0) n++
    return base + "-" + n
  }

  function toggleAgent(name) {
    if (root.raceMode) {
      var list = root.raceAgents.slice()
      var index = list.indexOf(name)
      if (index >= 0) list.splice(index, 1)
      else if (list.length < 3) list.push(name)
      root.raceAgents = list
    } else {
      root.selectedAgent = root.selectedAgent === name ? "" : name
    }
  }

  function launch() {
    if (!root.canLaunch) return
    root.failure = null
    var argv
    if (root.raceMode) {
      argv = ["worldline", "race", "--detach", "--json", "--mission-text", root.mission]
      if (root.raceName.trim() !== "") argv.push("--name", root.raceName.trim())
      for (var i = 0; i < root.raceAgents.length; i++) argv.push("--agent", root.raceAgents[i])
    } else {
      argv = ["worldline", "fork", root.effectiveAlias, "--mission-text", root.mission, "--json", "--", root.selectedAgent]
    }
    launchCall.run(argv, function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        var parsed = null
        try { parsed = JSON.parse(stdout) } catch (error) { parsed = null }
        var aliases = []
        if (Array.isArray(parsed)) for (var j = 0; j < parsed.length; j++) aliases.push(String(parsed[j].alias || ""))
        else if (parsed && parsed.alias) aliases.push(String(parsed.alias))
        root.launched({ aliases: aliases, race: root.raceMode })
      } else {
        root.failure = Model.parseCliError(stderr, exitCode)
      }
      root.requestFocus()
    })
  }

  function focusMission() { missionEditor.forceActiveFocus() }

  function reset() {
    root.mission = ""
    root.selectedAgent = ""
    root.raceAgents = []
    root.aliasText = ""
    root.raceName = ""
    root.failure = null
  }

  // A selection only means something for adapters the current probe reports AVAILABLE; drop
  // anything else so a choice made against one daemon cannot be launched at another.
  onAdaptersChanged: {
    var available = {}
    for (var i = 0; i < root.adapters.length; i++) if (root.adapters[i].state === "AVAILABLE") available[String(root.adapters[i].name)] = true
    if (root.selectedAgent !== "" && !available[root.selectedAgent]) root.selectedAgent = ""
    var kept = root.raceAgents.filter(function(name) { return available[name] === true })
    if (kept.length !== root.raceAgents.length) root.raceAgents = kept
  }

  function handleKey(event) {
    if (root.editing) {
      if (event.key === Qt.Key_Escape) { root.forceActiveFocus(); return true }
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) { root.launch(); return true }
      return false
    }
    if (event.key === Qt.Key_Escape) { root.back(); return true }
    if (event.text === "m" || event.text === "M") { root.focusMission(); return true }
    if (event.text >= "1" && event.text <= "9" && event.text.length === 1) {
      var index = Number(event.text) - 1
      if (index < root.adapters.length && root.adapters[index].state === "AVAILABLE") root.toggleAgent(String(root.adapters[index].name))
      return true
    }
    if (event.text === "t" || event.text === "T") { root.raceMode = !root.raceMode; return true }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.launch(); return true }
    return false
  }

  WlCall { id: launchCall; environment: root.cliEnvironment }

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.spacing.md

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.md
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: root.initialized ? "NEW MISSION FROM " + root.primeLabel : "NO PRIME"
        color: root.initialized ? Color.foreground : Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
        font.letterSpacing: Style.spaceReal(0.6)
      }
      Button {
        text: "SINGLE FORK"
        bordered: true
        selected: !root.raceMode
        onClicked: root.raceMode = false
      }
      Button {
        text: "RACE ×3"
        bordered: true
        selected: root.raceMode
        onClicked: root.raceMode = true
      }
    }

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: !root.initialized
      text: "WORLDLINE owns nothing yet. Register the directory you want agents to work on (it is moved behind a symlink into the managed store, exact path preserved):\n\n    worldline init /path/to/project\n\nThe cockpit's REALITY card offers the same step with a dry-run preview."
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Style.spacing.lg

      // ------------------------------------------------ adapters
      Flickable {
        Layout.preferredWidth: Math.round(Math.min(Style.space(330), parent.width * 0.36))
        Layout.minimumWidth: Style.space(220)
        Layout.fillHeight: true
        contentHeight: adapterColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: adapterColumn
          width: parent.width
          spacing: Style.spacing.sm

          RowLayout {
            Layout.fillWidth: true
            WlSectionTitle { text: (root.raceMode ? "CHOOSE EXACTLY THREE ADAPTERS" : "CHOOSE ONE ADAPTER") + " (1–9)" }
            Item { Layout.fillWidth: true }
            Button {
              text: root.adaptersLoading ? "probing…" : "re-probe"
              fontSize: Style.font.caption
              enabled: !root.adaptersLoading
              onClicked: root.refreshAdapters()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.adapters.length === 0
            Layout.fillWidth: true
            text: root.adaptersLoading ? "Probing installed adapters (`worldline adapters`)…" : "No adapter probe result yet."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.adapters
            delegate: Rectangle {
              id: adapterRow
              required property var modelData
              required property int index
              readonly property bool available: modelData.state === "AVAILABLE"
              readonly property bool chosen: root.raceMode ? root.raceAgents.indexOf(String(modelData.name)) >= 0 : root.selectedAgent === String(modelData.name)
              readonly property int lane: root.raceMode ? root.raceAgents.indexOf(String(modelData.name)) : -1
              Layout.fillWidth: true
              implicitHeight: adapterInner.implicitHeight + Style.spacing.md * 2
              radius: Style.cornerRadius
              color: chosen ? Style.selectedAccentFill : (adapterMouse.containsMouse && available ? Style.hoverFill : Style.normalFill)
              border.color: chosen ? Color.accent : (available ? Style.normalBorderColor : Util.alpha(Color.muted, 0.3))
              border.width: 1
              opacity: available ? 1 : 0.65

              ColumnLayout {
                id: adapterInner
                anchors.fill: parent
                anchors.margins: Style.spacing.md
                spacing: Style.spacing.xxs
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.spacing.sm
                  Text {
                    textFormat: Text.PlainText
                    text: (adapterRow.index + 1) + " " + (adapterRow.chosen ? (root.raceMode ? ["α", "β", "γ"][adapterRow.lane] : "●") : "○")
                    color: adapterRow.chosen ? Color.accent : Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: String(modelData.name || "")
                    color: adapterRow.available ? Color.foreground : Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  WlChip {
                    label: String(modelData.state || "?")
                    glyph: adapterRow.available ? "✓" : "⊘"
                    tone: adapterRow.available ? "accent" : "muted"
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: adapterRow.available
                    ? String(modelData.executable || "") + (modelData.credentialMounts && modelData.credentialMounts.length ? "  ·  " + modelData.credentialMounts.length + " credential projection(s)" : "")
                    : String(modelData.reason || "unavailable")
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                  wrapMode: adapterRow.available ? Text.NoWrap : Text.WordWrap
                  maximumLineCount: 3
                }
              }
              MouseArea {
                id: adapterMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: adapterRow.available ? Qt.PointingHandCursor : Qt.ArrowCursor
                enabled: adapterRow.available
                onClicked: root.toggleAgent(String(adapterRow.modelData.name))
              }
            }
          }
        }
      }

      // ------------------------------------------------ mission
      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Style.spacing.sm

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          WlSectionTitle { text: root.raceMode ? "RACE NAME (optional lane prefix)" : "WORLD ALIAS" }
          TextField {
            id: aliasField
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.forceActiveFocus(); root.requestFocus(); event.accepted = true }
            }
            visible: !root.raceMode
            Layout.preferredWidth: Style.space(240)
            placeholderText: root.suggestAlias()
            text: root.aliasText
            onTextEdited: root.aliasText = text
          }
          TextField {
            id: raceNameField
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.forceActiveFocus(); root.requestFocus(); event.accepted = true }
            }
            visible: root.raceMode
            Layout.preferredWidth: Style.space(240)
            placeholderText: "lanes: alpha · beta · gamma"
            text: root.raceName
            onTextEdited: root.raceName = text
          }
          Text {
            textFormat: Text.PlainText
            visible: (!root.raceMode && root.aliasTaken) || (root.raceMode && root.raceNameTaken)
            text: root.raceMode ? "lane aliases exist; add a name" : "alias exists"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Item { Layout.fillWidth: true }
        }

        WlSectionTitle { text: "MISSION (M to edit · Ctrl+Enter launches)" }
        TextArea {
          id: missionEditor
          Layout.fillWidth: true
          Layout.fillHeight: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.forceActiveFocus(); root.requestFocus(); event.accepted = true }
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) { root.launch(); event.accepted = true }
          }
          enabled: root.initialized && !root.fixture
          placeholderText: root.raceMode
            ? "Describe one mission. Each chosen agent receives the same frozen reality and works in its own world."
            : "Describe the mission for this one agent. It works on a copy; nothing reaches PRIME without a reviewed collapse."
          text: root.mission
          onTextChanged: if (root.mission !== text) root.mission = text
          color: Color.foreground
          placeholderTextColor: Qt.darker(Color.foreground, 1.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.Wrap
          selectionColor: Style.selectionFill
          selectedTextColor: Color.foreground
          background: Rectangle {
            color: Style.controlFill(missionEditor.activeFocus, missionEditor.hovered, Color.foreground, Color.accent)
            border.color: Style.controlBorder(missionEditor.activeFocus, missionEditor.hovered, Color.foreground, Color.accent)
            border.width: Style.controlBorderWidth(missionEditor.activeFocus, missionEditor.hovered)
            radius: Style.cornerRadius
          }
        }

        // spend + launch
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: spendText.implicitHeight + Style.spacing.lg
          color: Util.alpha(Color.muted, 0.08)
          border.color: Util.alpha(Color.muted, 0.35)
          border.width: 1
          radius: Style.cornerRadius
          Text {
            id: spendText
            textFormat: Text.PlainText
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            wrapMode: Text.WordWrap
            text: root.raceMode
              ? "Race: three concurrent agent runs with your credentials — roughly three times the spend of one fork. Lanes " + (root.raceName.trim() !== "" ? root.raceName.trim() + "-" : "") + "alpha/beta/gamma fork from one frozen checkpoint of " + root.primeLabel + ". Files stay inside each world; the network is shared with the host."
              : "Single fork: one agent run with your credentials. The agent writes only to its own overlay; the only way back into " + root.primeLabel + " is a reviewed collapse. Its network reach is not contained."
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.failure !== null
          Layout.fillWidth: true
          text: root.failure ? String(root.failure.code) + ": " + String(root.failure.message) : ""
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.blockedReason !== "" ? root.blockedReason : (root.raceMode
              ? "ready: " + root.raceAgents.join(" · ")
              : "ready: " + root.selectedAgent + " → " + root.effectiveAlias)
            color: root.blockedReason !== "" ? Color.muted : Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Button { text: "Back"; bordered: true; onClicked: root.back() }
          Button {
            text: root.busy ? "launching…" : (root.raceMode ? "Launch race" : "Fork " + root.effectiveAlias)
            opacity: enabled ? 1 : 0.4
            bordered: true
            selected: root.canLaunch
            enabled: root.canLaunch
            tooltipText: root.blockedReason
            onClicked: root.launch()
          }
        }
      }
    }
  }
}
