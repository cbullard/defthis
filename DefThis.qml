import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "DefThis.js" as DefThis

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool loading: false
  property bool fromCache: false
  property string word: ""
  property string errorText: ""
  property string sourceUrl: ""

  readonly property string backendPath: resolvedLocalPath("DefThisBackend.py")
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)

  function resolvedLocalPath(relativePath) {
    var value = String(Qt.resolvedUrl(relativePath))
    return value.indexOf("file://") === 0
      ? decodeURIComponent(value.slice(7)) : value
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (error) {}

    root.opened = true
    root.loading = true
    root.fromCache = false
    root.word = ""
    root.errorText = ""
    root.sourceUrl = ""
    definitionsModel.clear()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })

    var explicitTerm = DefThis.normalizedTerm(payload.term || "")
    if (explicitTerm.length > 0) {
      root.lookUp(explicitTerm)
      return
    }

    if (selectionProcess.running)
      selectionProcess.running = false
    selectionProcess.running = true
  }

  function close() {
    root.opened = false
    if (selectionProcess.running)
      selectionProcess.running = false
    if (lookupProcess.running)
      lookupProcess.running = false
    requestTimeout.stop()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.cbullard.defthis")
  }

  function toggle(payloadJson) {
    if (root.opened) root.dismiss()
    else root.open(payloadJson || "{}")
  }

  function selectionReceived(rawResult) {
    if (!root.opened)
      return
    var result
    try {
      result = JSON.parse(String(rawResult || ""))
    } catch (error) {
      result = ({ status: "error", selection: "" })
    }
    var term = result.status === "ok"
      ? DefThis.normalizedTerm(result.selection || "") : ""
    if (term.length === 0) {
      root.loading = false
      root.errorText = result.status === "oversized"
        ? "The selected text is too large. Select a single word and try again."
        : "Select a single word, then try the shortcut again."
      return
    }
    root.lookUp(term)
  }

  function applyDefinitions(definitions, cached) {
    definitionsModel.clear()
    for (var index = 0; index < definitions.length; index++) {
      definitionsModel.append({
        partOfSpeech: definitions[index].partOfSpeech || "",
        definition: definitions[index].definition || ""
      })
    }
    root.loading = false
    root.fromCache = cached
    root.errorText = definitionsModel.count > 0 ? "" : "No definition found."
  }

  function lookUp(rawTerm) {
    var term = DefThis.normalizedTerm(rawTerm)
    if (term.length === 0) {
      root.loading = false
      root.errorText = "Select a single word, then try the shortcut again."
      return
    }

    root.word = term
    root.sourceUrl = "https://en.wiktionary.org/wiki/" + encodeURIComponent(term)
    root.loading = true
    root.fromCache = false
    root.errorText = ""
    definitionsModel.clear()

    if (lookupProcess.running)
      lookupProcess.running = false
    lookupProcess.command = [root.backendPath, "lookup", term]
    lookupProcess.running = true
    requestTimeout.restart()
  }

  function lookupReceived(rawResult) {
    if (!root.opened)
      return
    requestTimeout.stop()
    var result
    try {
      result = JSON.parse(String(rawResult || ""))
    } catch (error) {
      result = ({ status: "error", definitions: [] })
    }
    if (result.status === "ok" && result.definitions instanceof Array
        && result.definitions.length > 0) {
      root.applyDefinitions(result.definitions, Boolean(result.cached))
      return
    }
    root.loading = false
    if (result.status === "not-found")
      root.errorText = "No definition found."
    else if (result.status === "oversized")
      root.errorText = "Wiktionary response exceeded the 1 MiB safety limit."
    else if (result.status === "invalid")
      root.errorText = "Select a single word, then try the shortcut again."
    else
      root.errorText = "Could not reach Wiktionary, and this word is not cached for offline use."
  }

  function openSource() {
    if (root.sourceUrl.length === 0)
      return
    var url = root.sourceUrl
    root.dismiss()
    Quickshell.execDetached(["xdg-open", url])
  }

  ListModel { id: definitionsModel }

  Process {
    id: lookupProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lookupReceived(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.opened && root.loading) {
        requestTimeout.stop()
        root.loading = false
        root.errorText = "DefThis could not start its bounded lookup helper."
      }
    }
  }

  Process {
    id: selectionProcess
    command: [root.backendPath, "selection"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.selectionReceived(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.opened && root.loading) {
        root.loading = false
        root.errorText = "DefThis could not read the selected word."
      }
    }
  }

  Timer {
    id: requestTimeout
    interval: 6000
    onTriggered: {
      if (lookupProcess.running)
        lookupProcess.running = false
      root.loading = false
      root.errorText = "Wiktionary did not respond, and this word is not cached for offline use."
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-defthis"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border,
                                     Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors {
          left: parent.left
          right: parent.right
          top: parent.top
          bottom: parent.bottom
          leftMargin: card.contentLeftInset
          rightMargin: card.contentRightInset
          topMargin: card.contentTopInset
          bottomMargin: card.contentBottomInset
        }
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_O && root.sourceUrl.length > 0) {
            root.openSource()
            event.accepted = true
          }
        }

        Column {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.spacing.xs

          Text {
            width: parent.width
            text: root.word || "DefThis"
            color: Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: root.loading ? (root.word ? "Looking up definition…" : "Reading selection…") : ""
            visible: text.length > 0
            color: Color.menu.text
            opacity: 0.62
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(28)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - closeButton.width - Style.spacing.md
            text: root.fromCache ? "Wiktionary · offline copy" : "Wiktionary · CC BY-SA 4.0"
            visible: root.word.length > 0
            color: Color.menu.text
            opacity: sourceMouse.containsMouse ? 0.9 : 0.58
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            font.underline: sourceMouse.containsMouse
            elide: Text.ElideRight

            MouseArea {
              id: sourceMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openSource()
            }
          }

          Rectangle {
            id: closeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: closeLabel.implicitWidth + Style.spacing.lg
            height: Style.space(28)
            radius: Style.cornerRadius
            color: closeMouse.pressed ? Color.accent : Util.alpha(Color.accent, closeMouse.containsMouse ? 0.9 : 0.78)

            Text {
              id: closeLabel
              anchors.centerIn: parent
              text: "Close"
              color: Color.menu.selectedText
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              id: closeMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.dismiss()
            }
          }
        }

        Item {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.bottom: footer.top
          anchors.topMargin: Style.spacing.lg
          anchors.bottomMargin: Style.spacing.md

          BusyIndicator {
            anchors.centerIn: parent
            running: root.loading
            visible: root.loading
          }

          Text {
            anchors.centerIn: parent
            width: parent.width
            visible: root.errorText.length > 0
            text: root.errorText
            color: Color.menu.text
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          ListView {
            id: definitionsList
            anchors.fill: parent
            visible: definitionsModel.count > 0
            clip: true
            spacing: Style.spacing.lg
            model: definitionsModel
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Item {
              required property string partOfSpeech
              required property string definition
              width: definitionsList.width - (definitionsList.contentHeight > definitionsList.height
                                                ? Style.space(14) : 0)
              height: partText.implicitHeight + definitionText.implicitHeight + Style.spacing.xs

              Text {
                id: partText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: parent.partOfSpeech
                visible: text.length > 0
                color: Color.menu.text
                opacity: 0.58
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                font.italic: true
              }

              Text {
                id: definitionText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: partText.visible ? partText.bottom : parent.top
                anchors.topMargin: partText.visible ? Style.spacing.xs : 0
                text: parent.definition
                textFormat: Text.PlainText
                color: Color.menu.text
                wrapMode: Text.WordWrap
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                lineHeight: 1.3
              }
            }
          }
        }
      }
    }
  }

}
