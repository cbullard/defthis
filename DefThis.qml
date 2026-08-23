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
  property var cacheEntries: ({})
  property var activeRequest: null

  readonly property string cacheRoot: Quickshell.env("XDG_CACHE_HOME")
    || (Quickshell.env("HOME") + "/.cache")
  readonly property string cachePath: cacheRoot + "/omarchy-defthis.json"
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)

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
    requestTimeout.stop()
    if (root.activeRequest) {
      var request = root.activeRequest
      root.activeRequest = null
      request.abort()
    }
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

  function selectionReceived(text) {
    if (!root.opened)
      return
    var term = DefThis.normalizedTerm(text)
    if (term.length === 0) {
      root.loading = false
      root.errorText = "Select a single word, then try the shortcut again."
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
    var cacheKey = term.toLocaleLowerCase()
    var cached = root.cacheEntries[cacheKey]
    if (cached instanceof Array && cached.length > 0) {
      root.sourceUrl = "https://en.wiktionary.org/wiki/" + encodeURIComponent(term)
      root.applyDefinitions(cached, true)
      return
    }

    root.loading = true
    root.fromCache = false
    root.errorText = ""
    definitionsModel.clear()

    if (root.activeRequest)
      root.activeRequest.abort()
    root.requestDefinitions(term, cacheKey, DefThis.lowercaseFallback(term))
  }

  function requestDefinitions(term, cacheKey, fallbackTerm) {
    root.sourceUrl = "https://en.wiktionary.org/wiki/" + encodeURIComponent(term)

    var request = new XMLHttpRequest()
    root.activeRequest = request
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE || root.activeRequest !== request)
        return

      requestTimeout.stop()
      root.activeRequest = null
      if (request.status === 200) {
        var definitions = DefThis.definitionsFromResponse(request.responseText)
        if (definitions.length > 0) {
          root.cacheEntries[cacheKey] = definitions
          cacheFile.setText(JSON.stringify({ version: 1, entries: root.cacheEntries }, null, 2) + "\n")
          root.applyDefinitions(definitions, false)
          return
        }
        if (fallbackTerm.length > 0) {
          root.retryDefinitions(fallbackTerm, cacheKey)
          return
        }
        root.loading = false
        root.errorText = "No definition found."
        return
      }

      if (request.status === 404 && fallbackTerm.length > 0) {
        root.retryDefinitions(fallbackTerm, cacheKey)
        return
      }

      root.loading = false
      root.errorText = request.status === 404
        ? "No definition found."
        : "Could not reach Wiktionary, and this word is not cached for offline use."
    }
    request.open("GET", "https://en.wiktionary.org/api/rest_v1/page/definition/"
                 + encodeURIComponent(term))
    request.setRequestHeader("Accept", "application/json")
    request.setRequestHeader("Api-User-Agent",
                             "DefThis/1.0 (https://github.com/cbullard/defthis)")
    request.send()
    requestTimeout.restart()
  }

  function retryDefinitions(term, cacheKey) {
    Qt.callLater(function() {
      if (root.opened)
        root.requestDefinitions(term, cacheKey, "")
    })
  }

  function openSource() {
    if (root.sourceUrl.length === 0)
      return
    var url = root.sourceUrl
    root.dismiss()
    Quickshell.execDetached(["xdg-open", url])
  }

  ListModel { id: definitionsModel }

  FileView {
    id: cacheFile
    path: root.cachePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.cacheEntries = parsed && parsed.version === 1 && parsed.entries
          ? parsed.entries
          : ({})
      } catch (error) {
        root.cacheEntries = ({})
      }
    }
    onLoadFailed: root.cacheEntries = ({})
  }

  Process {
    id: ensureCacheDirectory
    command: ["mkdir", "-p", root.cacheRoot]
  }

  Process {
    id: selectionProcess
    command: ["wl-paste", "--primary", "--type", "text", "--no-newline"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.selectionReceived(text)
    }
  }

  Timer {
    id: requestTimeout
    interval: 4000
    onTriggered: {
      if (root.activeRequest) {
        root.activeRequest.abort()
        root.activeRequest = null
      }
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
        anchors.fill: parent
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

  Component.onCompleted: {
    ensureCacheDirectory.running = true
    Qt.callLater(function() { cacheFile.reload() })
  }
}
