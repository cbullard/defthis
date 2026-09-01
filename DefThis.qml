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
  property bool capturing: false
  property string captureStage: ""
  property bool loading: false
  property bool fromCache: false
  property string word: ""
  property string errorText: ""
  property string sourceUrl: ""
  property var cacheEntries: ({})
  property var cacheAliases: ({})
  property var recentTerms: []
  property var activeRequest: null
  property var pluralFallbackDefinitions: []
  property string pluralFallbackTerm: ""
  property string pluralFallbackCacheKey: ""
  property bool pluralFallbackCached: false
  property string singularLookupTerm: ""
  property bool showingHistory: false
  property bool clearConfirmOpen: false
  property bool inputOpen: false
  property string inputText: ""
  property string inputError: ""
  property int selectedHistoryIndex: -1

  readonly property string backendPath: resolvedLocalPath("DefThisBackend.py")
  readonly property string commandSourcePath: resolvedLocalPath("scripts/omarchy-defthis")
  readonly property string commandInstallPath: Quickshell.env("HOME") + "/.local/bin/omarchy-defthis"
  readonly property string cacheRoot: Quickshell.env("XDG_CACHE_HOME")
    || (Quickshell.env("HOME") + "/.cache")
  readonly property string cachePath: cacheRoot + "/omarchy-defthis.json"
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  readonly property int historyLimit: 50

  function resolvedLocalPath(relativePath) {
    var value = String(Qt.resolvedUrl(relativePath))
    return value.indexOf("file://") === 0
      ? decodeURIComponent(value.slice(7)) : value
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (error) {}

    root.close()
    root.loading = true
    root.fromCache = false
    root.word = ""
    root.errorText = ""
    root.sourceUrl = ""
    root.showingHistory = false
    root.clearConfirmOpen = false
    root.inputOpen = false
    root.inputText = ""
    root.inputError = ""
    definitionsModel.clear()
    var explicitTerm = DefThis.normalizedTerm(payload.term || "")
    if (explicitTerm.length > 0) {
      root.showOverlay()
      root.lookUp(explicitTerm)
      return
    }

    root.capturing = true
    if (payload.selectionOnly === true) {
      root.readPrimarySelection()
    } else {
      root.captureStage = "context"
      contextProcess.running = true
      captureTimeout.restart()
    }
  }

  function showOverlay() {
    root.capturing = false
    root.captureStage = ""
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function readPrimarySelection() {
    if (!root.capturing || root.captureStage === "selection")
      return
    root.captureStage = "selection"
    captureTimeout.stop()
    if (selectionProcess.running)
      selectionProcess.running = false
    selectionProcess.running = true
  }

  function close() {
    root.opened = false
    root.capturing = false
    root.captureStage = ""
    root.clearConfirmOpen = false
    root.inputOpen = false
    if (contextProcess.running)
      contextProcess.running = false
    if (selectionProcess.running)
      selectionProcess.running = false
    root.clearPluralFallback()
    if (singularLookupProcess.running)
      singularLookupProcess.running = false
    captureTimeout.stop()
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
    if (root.opened || root.capturing) root.dismiss()
    else root.open(payloadJson || "{}")
  }

  function contextReceived(rawResult) {
    if (!root.capturing || root.captureStage !== "context")
      return
    captureTimeout.stop()
    var result
    try {
      result = JSON.parse(String(rawResult || ""))
    } catch (error) {
      result = ({ status: "unavailable", term: "", source: "" })
    }
    var term = result.status === "ok"
      ? DefThis.normalizedTerm(result.term || "") : ""
    if (term.length > 0) {
      root.showOverlay()
      root.lookUp(term)
      return
    }
    if (result.status === "ok") {
      root.showOverlay()
      root.loading = false
      root.errorText = result.source === "selection"
        ? "Select a single word, then try the shortcut again."
        : "Place the text cursor inside a word, then try the shortcut again."
      return
    }
    root.readPrimarySelection()
  }

  function selectionReceived(rawResult) {
    if (!root.capturing || root.captureStage !== "selection")
      return
    root.showOverlay()
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

  function saveCache() {
    cacheFile.setText(JSON.stringify({
      version: 3,
      entries: root.cacheEntries,
      aliases: root.cacheAliases,
      recentTerms: root.recentTerms
    }, null, 2) + "\n")
  }

  function refreshHistoryModel() {
    root.recentTerms = DefThis.normalizeRecentTerms(
      root.recentTerms, root.cacheEntries, root.historyLimit)
    historyModel.clear()
    for (var index = 0; index < root.recentTerms.length; index++) {
      var term = root.recentTerms[index]
      var definitions = root.cacheEntries[term.toLocaleLowerCase()]
      var first = definitions && definitions.length > 0 ? definitions[0] : ({})
      historyModel.append({
        term: term,
        partOfSpeech: String(first.partOfSpeech || ""),
        summary: String(first.definition || "")
      })
    }
  }

  function recordSuccessfulLookup(term) {
    root.recentTerms = DefThis.recordRecentTerm(
      root.recentTerms, term, root.cacheEntries, root.historyLimit)
    root.refreshHistoryModel()
    root.saveCache()
  }

  function toggleHistory() {
    if (root.inputOpen)
      return
    root.showingHistory = !root.showingHistory
    if (root.showingHistory) {
      root.refreshHistoryModel()
      root.selectedHistoryIndex = historyModel.count > 0 ? 0 : -1
      if (root.selectedHistoryIndex >= 0)
        historyList.positionViewAtIndex(root.selectedHistoryIndex, ListView.Beginning)
    }
  }

  function selectHistory(delta) {
    if (historyModel.count === 0) {
      root.selectedHistoryIndex = -1
      return
    }
    var next = root.selectedHistoryIndex < 0 ? 0 : root.selectedHistoryIndex + delta
    root.selectedHistoryIndex = Math.max(0, Math.min(historyModel.count - 1, next))
    historyList.positionViewAtIndex(root.selectedHistoryIndex, ListView.Contain)
  }

  function activateHistoryIndex(index) {
    if (index < 0 || index >= historyModel.count)
      return
    var term = historyModel.get(index).term
    root.showingHistory = false
    root.lookUp(term)
  }

  function removeHistoryIndex(index) {
    if (index < 0 || index >= historyModel.count)
      return
    var term = historyModel.get(index).term
    var target = term.toLocaleLowerCase()
    for (var aliasKey in root.cacheAliases) {
      if (String(root.cacheAliases[aliasKey] || "").toLocaleLowerCase() === target)
        root.cacheEntries = DefThis.cacheEntriesWithoutTerm(
          root.cacheEntries, aliasKey)
    }
    root.cacheEntries = DefThis.cacheEntriesWithoutTerm(root.cacheEntries, term)
    root.cacheAliases = DefThis.cacheAliasesWithoutTerm(root.cacheAliases, term)
    root.recentTerms = DefThis.removeRecentTerm(
      root.recentTerms, term, root.cacheEntries, root.historyLimit)
    root.refreshHistoryModel()
    root.selectedHistoryIndex = historyModel.count > 0
      ? Math.min(index, historyModel.count - 1)
      : -1
    root.saveCache()
  }

  function requestClearHistory() {
    if (historyModel.count > 0)
      root.clearConfirmOpen = true
  }

  function confirmClearHistory() {
    root.cacheEntries = ({})
    root.cacheAliases = ({})
    root.recentTerms = []
    root.selectedHistoryIndex = -1
    root.clearConfirmOpen = false
    root.refreshHistoryModel()
    root.saveCache()
  }

  function requestTypedLookup() {
    root.inputText = ""
    root.inputError = ""
    root.inputOpen = true
    Qt.callLater(function() { typedWordField.forceActiveFocus() })
  }

  function cancelTypedLookup() {
    root.inputOpen = false
    root.inputText = ""
    root.inputError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submitTypedLookup() {
    var term = DefThis.normalizedTerm(root.inputText)
    if (term.length === 0) {
      root.inputError = "Enter one word without spaces."
      return
    }
    root.inputOpen = false
    root.showingHistory = false
    root.inputError = ""
    root.lookUp(term)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
      var cachedAlias = DefThis.normalizedTerm(root.cacheAliases[cacheKey] || "")
      var cachedSingular = cachedAlias.length > 0
        ? "" : DefThis.singularLemma(cached)
      if (cachedSingular.length > 0
          && cachedSingular.toLocaleLowerCase() !== cacheKey) {
        root.loading = true
        root.fromCache = false
        root.sourceUrl = "https://en.wiktionary.org/wiki/" + encodeURIComponent(term)
        definitionsModel.clear()
        root.clearPluralFallback()
        root.requestSingularDefinitions(
          cachedSingular, term, cacheKey, cached, true)
        return
      }
      var resolvedTerm = cachedAlias.length > 0 ? cachedAlias : term
      if (resolvedTerm.length === 0)
        resolvedTerm = term
      root.word = resolvedTerm
      root.sourceUrl = "https://en.wiktionary.org/wiki/"
        + encodeURIComponent(resolvedTerm)
      root.applyDefinitions(cached, true)
      root.recordSuccessfulLookup(resolvedTerm)
      return
    }

    root.loading = true
    root.fromCache = false
    root.errorText = ""
    definitionsModel.clear()

    if (root.activeRequest)
      root.activeRequest.abort()
    root.clearPluralFallback()
    if (singularLookupProcess.running)
      singularLookupProcess.running = false
    root.requestDefinitions(term, cacheKey, DefThis.lowercaseFallback(term))
  }

  function clearPluralFallback() {
    root.pluralFallbackDefinitions = []
    root.pluralFallbackTerm = ""
    root.pluralFallbackCacheKey = ""
    root.pluralFallbackCached = false
    root.singularLookupTerm = ""
  }

  function finishSuccessfulLookup(term, cacheKey, definitions, resolvedTerm, cached) {
    var resolved = DefThis.normalizedTerm(resolvedTerm) || term
    var resolvedKey = resolved.toLocaleLowerCase()
    root.cacheEntries[cacheKey] = definitions
    root.cacheEntries[resolvedKey] = definitions
    if (resolvedKey === cacheKey)
      delete root.cacheAliases[cacheKey]
    else
      root.cacheAliases[cacheKey] = resolved
    root.word = resolved
    root.sourceUrl = "https://en.wiktionary.org/wiki/" + encodeURIComponent(resolved)
    root.clearPluralFallback()
    root.applyDefinitions(definitions, cached)
    root.recordSuccessfulLookup(resolved)
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
          var singularTerm = DefThis.singularLemma(definitions)
          if (singularTerm.length > 0
              && singularTerm.toLocaleLowerCase() !== term.toLocaleLowerCase()) {
            root.requestSingularDefinitions(
              singularTerm, term, cacheKey, definitions)
            return
          }
          root.finishSuccessfulLookup(
            term, cacheKey, definitions, term, false)
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
                             "DefThis/1.2.0 (https://github.com/cbullard/defthis)")
    request.send()
    requestTimeout.restart()
  }

  function requestSingularDefinitions(
    singularTerm, pluralTerm, pluralCacheKey, pluralDefinitions, pluralCached) {
    if (singularLookupProcess.running) {
      root.clearPluralFallback()
      singularLookupProcess.running = false
    }
    root.pluralFallbackDefinitions = pluralDefinitions
    root.pluralFallbackTerm = pluralTerm
    root.pluralFallbackCacheKey = pluralCacheKey
    root.pluralFallbackCached = Boolean(pluralCached)
    root.singularLookupTerm = singularTerm

    var singularKey = singularTerm.toLocaleLowerCase()
    var cached = root.cacheEntries[singularKey]
    if (cached instanceof Array && cached.length > 0) {
      root.finishSuccessfulLookup(
        pluralTerm, pluralCacheKey, cached, singularTerm, Boolean(pluralCached))
      return
    }

    singularLookupProcess.command = [root.backendPath, "lookup", singularTerm]
    singularLookupProcess.running = true
    requestTimeout.restart()
  }

  function finishPluralFallback() {
    var definitions = root.pluralFallbackDefinitions
    var term = root.pluralFallbackTerm
    var cacheKey = root.pluralFallbackCacheKey
    var cached = root.pluralFallbackCached
    if (!(definitions instanceof Array) || definitions.length === 0) {
      root.clearPluralFallback()
      return
    }
    root.finishSuccessfulLookup(
      term, cacheKey, definitions, term, cached)
  }

  function singularLookupReceived(rawResult) {
    if (!(root.pluralFallbackDefinitions instanceof Array)
        || root.pluralFallbackDefinitions.length === 0)
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
      var resolvedTerm = DefThis.normalizedTerm(
        result.term || root.singularLookupTerm)
      root.finishSuccessfulLookup(
        root.pluralFallbackTerm, root.pluralFallbackCacheKey,
        result.definitions, resolvedTerm, Boolean(result.cached))
      return
    }
    root.finishPluralFallback()
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
  ListModel { id: historyModel }

  FileView {
    id: cacheFile
    path: root.cachePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.cacheEntries = parsed
          && (parsed.version === 1 || parsed.version === 2 || parsed.version === 3)
          && parsed.entries
          ? parsed.entries
          : ({})
        root.cacheAliases = parsed && parsed.version === 3 && parsed.aliases
          ? parsed.aliases
          : ({})
        root.recentTerms = parsed && (parsed.version === 2 || parsed.version === 3)
          && parsed.recentTerms instanceof Array
          ? parsed.recentTerms
          : DefThis.recentTermsFromEntries(root.cacheEntries, root.historyLimit)
        root.refreshHistoryModel()
      } catch (error) {
        root.cacheEntries = ({})
        root.cacheAliases = ({})
        root.recentTerms = []
        root.refreshHistoryModel()
      }
    }
    onLoadFailed: {
      root.cacheEntries = ({})
      root.cacheAliases = ({})
      root.recentTerms = []
      root.refreshHistoryModel()
    }
  }

  Process {
    id: ensureCacheDirectory
    command: ["mkdir", "-p", root.cacheRoot]
  }

  Process {
    id: installCommandProcess
    command: ["install", "-Dm755", root.commandSourcePath, root.commandInstallPath]
  }

  Process {
    id: singularLookupProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.singularLookupReceived(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0
          && root.pluralFallbackDefinitions instanceof Array
          && root.pluralFallbackDefinitions.length > 0) {
        requestTimeout.stop()
        root.finishPluralFallback()
      }
    }
  }

  Process {
    id: contextProcess
    command: [root.backendPath, "focused-term"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.contextReceived(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.capturing && root.captureStage === "context")
        root.readPrimarySelection()
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
      if (exitCode !== 0 && root.capturing && root.captureStage === "selection") {
        root.showOverlay()
        root.loading = false
        root.errorText = "DefThis could not read the selected word."
      }
    }
  }

  Timer {
    id: captureTimeout
    interval: 1500
    onTriggered: {
      if (root.captureStage === "context" && contextProcess.running)
        contextProcess.running = false
      if (root.captureStage === "context")
        root.readPrimarySelection()
    }
  }

  Timer {
    id: requestTimeout
    interval: 10000
    onTriggered: {
      if (singularLookupProcess.running)
        singularLookupProcess.running = false
      if (root.activeRequest) {
        root.activeRequest.abort()
        root.activeRequest = null
      }
      if (root.pluralFallbackDefinitions instanceof Array
          && root.pluralFallbackDefinitions.length > 0) {
        root.finishPluralFallback()
        return
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
        z: root.clearConfirmOpen ? 20 : 0
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.inputOpen)
            return

          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_H
                     && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            root.toggleHistory()
            event.accepted = true
          } else if (event.key === Qt.Key_Space
                     && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            root.requestTypedLookup()
            event.accepted = true
          } else if (root.showingHistory && event.key === Qt.Key_Up) {
            root.selectHistory(-1)
            event.accepted = true
          } else if (root.showingHistory && event.key === Qt.Key_Down) {
            root.selectHistory(1)
            event.accepted = true
          } else if (root.showingHistory && event.key === Qt.Key_PageUp) {
            root.selectHistory(-6)
            event.accepted = true
          } else if (root.showingHistory && event.key === Qt.Key_PageDown) {
            root.selectHistory(6)
            event.accepted = true
          } else if (root.showingHistory && event.key === Qt.Key_Home) {
            root.selectedHistoryIndex = historyModel.count > 0 ? 0 : -1
            if (root.selectedHistoryIndex >= 0)
              historyList.positionViewAtIndex(root.selectedHistoryIndex, ListView.Beginning)
            event.accepted = true
          } else if (root.showingHistory && event.key === Qt.Key_End) {
            root.selectedHistoryIndex = historyModel.count - 1
            if (root.selectedHistoryIndex >= 0)
              historyList.positionViewAtIndex(root.selectedHistoryIndex, ListView.End)
            event.accepted = true
          } else if (root.showingHistory && event.key === Qt.Key_Delete) {
            root.removeHistoryIndex(root.selectedHistoryIndex)
            event.accepted = true
          } else if (root.showingHistory
                     && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            root.activateHistoryIndex(root.selectedHistoryIndex)
            event.accepted = true
          } else if (!root.showingHistory && event.key === Qt.Key_O && root.sourceUrl.length > 0) {
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

          Item {
            width: parent.width
            height: Math.max(wordTitle.implicitHeight, headerActions.height)

            Text {
              id: wordTitle
              anchors.left: parent.left
              anchors.right: headerActions.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              text: root.inputOpen
                ? "Type a word"
                : (root.showingHistory ? "Recent words" : (root.word || "Definition"))
              textFormat: Text.PlainText
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "DefThis"
                color: Color.menu.text
                opacity: 0.58
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Rectangle {
                id: historyButton
                visible: !root.inputOpen
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.cornerRadius
                color: root.showingHistory
                  ? Util.alpha(Color.accent, 0.32)
                  : Util.alpha(Color.menu.text, historyMouse.containsMouse ? 0.14 : 0.08)

                Text {
                  anchors.centerIn: parent
                  text: "󰋚"
                  color: Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  id: historyMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleHistory()
                }

                ToolTip.visible: historyMouse.containsMouse
                ToolTip.text: root.showingHistory ? "Back to definition (H)" : "Recent words (H)"
              }
            }
          }

          Text {
            width: parent.width
            text: root.inputOpen
              ? "Look up a word without selecting it first"
              : (root.showingHistory
              ? (historyModel.count === 1 ? "1 saved definition" : historyModel.count + " saved definitions")
              : (root.loading ? (root.word ? "Looking up definition…" : "Reading selection…") : ""))
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
            width: parent.width - footerActions.width - Style.spacing.md
            text: root.inputOpen
              ? "Enter look up · Escape cancel"
              : (root.showingHistory
              ? "Enter open · Delete remove · H back"
              : (root.fromCache ? "Wiktionary · offline copy" : "Wiktionary · CC BY-SA 4.0")
                + " · H recent · Space type")
            visible: root.inputOpen || root.showingHistory || root.word.length > 0
            color: Color.menu.text
            opacity: !root.inputOpen && !root.showingHistory && sourceMouse.containsMouse ? 0.9 : 0.58
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            font.underline: !root.inputOpen && !root.showingHistory && sourceMouse.containsMouse
            elide: Text.ElideRight

            MouseArea {
              id: sourceMouse
              anchors.fill: parent
              enabled: !root.inputOpen && !root.showingHistory
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openSource()
            }
          }

          Row {
            id: footerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Rectangle {
              id: clearButton
              visible: !root.inputOpen && root.showingHistory && historyModel.count > 0
              width: visible ? clearLabel.implicitWidth + Style.spacing.lg : 0
              height: Style.space(28)
              radius: Style.cornerRadius
              color: Util.alpha(Color.menu.text, clearMouse.containsMouse ? 0.14 : 0.08)

              Text {
                id: clearLabel
                anchors.centerIn: parent
                text: "Clear"
                color: Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: clearMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.requestClearHistory()
              }
            }

            Rectangle {
              id: cancelInputButton
              visible: root.inputOpen
              width: visible ? cancelInputLabel.implicitWidth + Style.spacing.lg : 0
              height: Style.space(28)
              radius: Style.cornerRadius
              color: Util.alpha(Color.menu.text, cancelInputMouse.containsMouse ? 0.14 : 0.08)

              Text {
                id: cancelInputLabel
                anchors.centerIn: parent
                text: "Cancel"
                color: Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: cancelInputMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cancelTypedLookup()
              }
            }

            Rectangle {
              id: closeButton
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
            visible: !root.inputOpen && !root.showingHistory && root.loading
          }

          Text {
            anchors.centerIn: parent
            width: parent.width
            visible: !root.inputOpen && !root.showingHistory && root.errorText.length > 0
            text: root.errorText
            textFormat: Text.PlainText
            color: Color.menu.text
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          ListView {
            id: definitionsList
            anchors.fill: parent
            visible: !root.inputOpen && !root.showingHistory && definitionsModel.count > 0
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
                textFormat: Text.PlainText
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

          Text {
            anchors.centerIn: parent
            width: parent.width
            visible: !root.inputOpen && root.showingHistory && historyModel.count === 0
            text: "No recent words yet."
            color: Color.menu.text
            opacity: 0.7
            horizontalAlignment: Text.AlignHCenter
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
          }

          ListView {
            id: historyList
            anchors.fill: parent
            visible: !root.inputOpen && root.showingHistory && historyModel.count > 0
            clip: true
            spacing: Style.spacing.md
            model: historyModel
            currentIndex: root.selectedHistoryIndex
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
              required property int index
              required property string term
              required property string partOfSpeech
              required property string summary

              width: historyList.width - (historyList.contentHeight > historyList.height
                                           ? Style.space(14) : 0)
              height: historyText.implicitHeight + historySummary.implicitHeight
                      + Style.spacing.xs + Style.spacing.lg * 2
              radius: Style.cornerRadius
              color: index === root.selectedHistoryIndex
                ? Util.alpha(Color.accent, 0.26)
                : Util.alpha(Color.menu.text, historyRowMouse.containsMouse ? 0.08 : 0)

              Text {
                id: historyText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Style.spacing.lg
                anchors.rightMargin: Style.spacing.lg
                anchors.topMargin: Style.spacing.lg
                text: parent.term
                textFormat: Text.PlainText
                color: Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                id: historySummary
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: historyText.bottom
                anchors.leftMargin: Style.spacing.lg
                anchors.rightMargin: Style.spacing.lg
                anchors.topMargin: Style.spacing.xs
                text: parent.partOfSpeech.length > 0
                  ? parent.partOfSpeech + " · " + parent.summary
                  : parent.summary
                textFormat: Text.PlainText
                color: Color.menu.text
                opacity: 0.62
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              MouseArea {
                id: historyRowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedHistoryIndex = parent.index
                onClicked: root.activateHistoryIndex(parent.index)
              }
            }
          }

          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width, Style.space(420))
            visible: root.inputOpen
            spacing: Style.spacing.md

            TextField {
              id: typedWordField
              width: parent.width
              height: Style.space(44)
              text: root.inputText
              placeholderText: "Word"
              maximumLength: 80
              selectByMouse: true
              color: Color.menu.text
              placeholderTextColor: Util.alpha(Color.menu.text, 0.48)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              leftPadding: Style.spacing.xl
              rightPadding: Style.spacing.xl
              onTextChanged: {
                root.inputText = text
                root.inputError = ""
              }
              onAccepted: root.submitTypedLookup()
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelTypedLookup()
                  event.accepted = true
                }
              }

              background: Rectangle {
                radius: Style.cornerRadius
                color: Util.alpha(Color.menu.text, 0.07)
                border.width: typedWordField.activeFocus
                  ? Math.max(1, Style.normalBorderWidth)
                  : 0
                border.color: Color.accent
              }
            }

            Text {
              width: parent.width
              visible: root.inputError.length > 0
              text: root.inputError
              textFormat: Text.PlainText
              color: Color.menu.text
              opacity: 0.72
              horizontalAlignment: Text.AlignHCenter
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        ConfirmDialog {
          id: clearConfirm
          anchors.fill: parent
          opened: root.clearConfirmOpen
          z: 10
          message: "Delete all saved words and definitions?"
          confirmText: "Delete all"
          background: Color.menu.background
          foreground: Color.menu.text
          scrim: Color.menu.scrim
          selectedBackground: Color.accent
          selectedText: Color.menu.selectedText
          fontFamily: Style.font.menuFamily
          cornerRadius: Style.cornerRadius
          onCanceled: root.clearConfirmOpen = false
          onConfirmed: root.confirmClearHistory()
        }
      }
    }
  }

  Component.onCompleted: {
    ensureCacheDirectory.running = true
    installCommandProcess.running = true
    Qt.callLater(function() { cacheFile.reload() })
  }
}
