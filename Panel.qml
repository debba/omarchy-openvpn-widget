import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "community.openvpn"
  ipcTarget: "community.openvpn"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helperPath: String(Qt.resolvedUrl("scripts/openvpn-widget")).replace(/^file:\/\//, "")
  readonly property string configDirectory: String(setting("configDirectory", "~/.config/openvpn"))
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 10)) || 10)
  readonly property bool anyActive: activeProfileName !== ""
  readonly property bool anyConnecting: connectingProfileName !== ""

  property var profiles: []
  property string activeProfileName: ""
  property string connectingProfileName: ""
  property string editPath: ""
  property string editName: ""
  property string renamePath: ""
  property string renameText: ""
  property string usernameText: ""
  property string passwordText: ""
  property string message: ""
  property string errorMessage: ""
  property string actionKind: ""
  property string actionPath: ""
  property string actionInput: ""
  property bool connectAfterSave: false
  property bool askPasswordChoice: false
  property string promptPath: ""
  property string promptName: ""
  property string promptText: ""

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function parseResult(raw) {
    try {
      return JSON.parse(String(raw || "{}"))
    } catch (error) {
      return { ok: false, error: "The OpenVPN backend returned invalid data" }
    }
  }

  function refresh() {
    if (listProcess.running) return
    listProcess.command = [helperPath, "list", "--config-dir", configDirectory]
    listProcess.running = true
  }

  function openCredentials(profile, thenConnect) {
    closeRename()
    editPath = profile.path
    editName = profile.name
    closePasswordPrompt()
    usernameText = ""
    passwordText = ""
    askPasswordChoice = profile.askPassword === true
    connectAfterSave = thenConnect === true
    Qt.callLater(function() { usernameField.forceActiveFocus() })
  }

  function closeCredentials() {
    editPath = ""
    editName = ""
    usernameText = ""
    passwordText = ""
    askPasswordChoice = false
    connectAfterSave = false
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Asks for the password of a profile in "ask on every connection" mode,
  // typically a one-time password that must never be stored or replayed.
  function openPasswordPrompt(path, name) {
    closeRename()
    closeCredentials()
    promptPath = path
    promptName = name
    promptText = ""
    Qt.callLater(function() { promptField.forceActiveFocus() })
  }

  function closePasswordPrompt() {
    promptPath = ""
    promptName = ""
    promptText = ""
    if (opened && editPath === "" && renamePath === "") Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submitPasswordPrompt() {
    if (promptText === "") {
      errorMessage = "Password is required"
      return
    }
    var path = promptPath
    var payload = JSON.stringify({ password: promptText }) + "\n"
    closePasswordPrompt()
    runAction("connect", path, payload, ["--password-stdin"])
  }

  function connectProfile(profile) {
    if (profile.askPassword) openPasswordPrompt(profile.path, profile.name)
    else runAction("connect", profile.path)
  }

  function openRename(profile) {
    closeCredentials()
    renamePath = profile.path
    renameText = profile.name
    Qt.callLater(function() {
      profileNameField.forceActiveFocus()
      profileNameField.selectAll()
    })
  }

  function closeRename() {
    renamePath = ""
    renameText = ""
    if (opened && editPath === "") Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveRename() {
    var name = renameText.trim()
    if (name === "") {
      errorMessage = "Profile name is required"
      return
    }
    runAction("rename", renamePath, JSON.stringify({ name: name }) + "\n")
  }

  function runAction(kind, path, input, extraArgs) {
    if (actionProcess.running) return
    actionKind = kind
    actionPath = path
    actionInput = input || ""
    message = ""
    errorMessage = ""
    actionProcess.command = [helperPath, kind, "--config", path].concat(extraArgs || [])
    actionProcess.running = true
  }

  // Disconnecting runs in its own process so it also works while a "connect"
  // action is still blocked waiting for NetworkManager.
  function disconnect(path) {
    if (disconnectProcess.running) return
    message = ""
    errorMessage = ""
    disconnectProcess.command = [helperPath, "disconnect", "--config", path]
    disconnectProcess.running = true
  }

  function activate(profile) {
    if (!profile) return
    if (profile.active || profile.connecting) {
      disconnect(profile.path)
      return
    }
    if (actionProcess.running) return
    if (profile.hasCredentials) connectProfile(profile)
    else openCredentials(profile, true)
  }

  function saveCredentials() {
    var username = usernameText.trim()
    var password = passwordText
    if (username === "" || (password === "" && !askPasswordChoice)) {
      errorMessage = askPasswordChoice ? "Username is required" : "Username and password are required"
      return
    }
    var payload = JSON.stringify({
      username: username,
      password: askPasswordChoice ? "" : password,
      askPassword: askPasswordChoice
    }) + "\n"
    usernameText = ""
    passwordText = ""
    runAction("save-credentials", editPath, payload)
  }

  onOpenedChanged: if (opened) refresh()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  Process {
    id: listProcess
    running: false
    command: []
    stdout: StdioCollector { id: listOutput; waitForEnd: true }
    stderr: StdioCollector { id: listError; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.parseResult(listOutput.text)
      if (exitCode === 0 && result.ok) {
        root.profiles = result.profiles || []
        root.activeProfileName = ""
        root.connectingProfileName = ""
        for (var index = 0; index < root.profiles.length; index++) {
          var profile = root.profiles[index]
          if (profile.active && root.activeProfileName === "") root.activeProfileName = profile.name
          if (profile.connecting && root.connectingProfileName === "") root.connectingProfileName = profile.name
        }
        if (!result.directoryExists)
          root.errorMessage = "Configuration directory not found: " + result.directory
        else if (root.errorMessage.indexOf("Configuration directory not found:") === 0)
          root.errorMessage = ""
      } else {
        root.errorMessage = result.error || String(listError.text || "Could not load OpenVPN profiles").trim()
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    stderr: StdioCollector { id: actionError; waitForEnd: true }
    onStarted: {
      if (root.actionInput !== "") {
        write(root.actionInput)
        root.actionInput = ""
      }
    }
    onExited: function(exitCode) {
      var completedKind = root.actionKind
      var completedPath = root.actionPath
      var shouldConnect = completedKind === "save-credentials" && root.connectAfterSave
      var result = root.parseResult(actionOutput.text)
      root.actionKind = ""
      root.actionPath = ""
      if (exitCode === 0 && result.ok) {
        root.message = result.message || "Done"
        root.errorMessage = ""
        if (completedKind === "save-credentials") root.closeCredentials()
        if (completedKind === "rename") root.closeRename()
        if (shouldConnect && result.askPassword) {
          var profileName = completedPath
          for (var index = 0; index < root.profiles.length; index++)
            if (root.profiles[index].path === completedPath) profileName = root.profiles[index].name
          root.openPasswordPrompt(completedPath, profileName)
        }
        else if (shouldConnect) Qt.callLater(function() { root.runAction("connect", completedPath) })
        else root.refresh()
      } else {
        root.errorMessage = result.error || String(actionError.text || "OpenVPN action failed").trim()
        root.connectAfterSave = false
        root.refresh()
      }
    }
  }

  Process {
    id: disconnectProcess
    running: false
    command: []
    stdout: StdioCollector { id: disconnectOutput; waitForEnd: true }
    stderr: StdioCollector { id: disconnectError; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.parseResult(disconnectOutput.text)
      if (exitCode === 0 && result.ok) root.message = result.message || "Disconnected"
      else root.errorMessage = result.error || String(disconnectError.text || "Could not disconnect").trim()
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: root.anyActive ? "󰖂" : "󰦝"
    active: root.anyActive
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(400))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editPath !== "" || root.renamePath !== "" || root.promptPath !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { if (text === "r" || text === "R") root.refresh() }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.anyActive ? root.activeProfileName : (root.anyConnecting ? root.connectingProfileName : "OpenVPN")
            meta: root.anyActive ? "CONNECTED" : (root.anyConnecting ? "CONNECTING" : "DISCONNECTED")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.anyActive ? "󰖂" : "󰦝"
                color: root.anyActive ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            width: parent.width
            text: root.configDirectory
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Text {
            visible: root.message !== "" || root.errorMessage !== ""
            width: parent.width
            text: root.errorMessage !== "" ? root.errorMessage : root.message
            color: root.errorMessage !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            text: "PROFILES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.profiles.length === 0 && root.errorMessage === ""
            width: parent.width
            text: "No .ovpn or .conf files found. Choose a directory in the widget settings."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.profiles

              CursorSurface {
                required property var modelData
                width: parent.width
                implicitHeight: profileRow.implicitHeight + Style.space(12)
                current: modelData.active
                foreground: root.foreground

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activate(modelData)
                }

                RowLayout {
                  id: profileRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Text {
                    text: modelData.active ? "󰖂" : "󰦝"
                    color: modelData.active ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                    Layout.alignment: Qt.AlignVCenter
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      text: modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: modelData.active
                      elide: Text.ElideRight
                    }
                    Text {
                      Layout.fillWidth: true
                      text: modelData.active ? "Connected"
                          : modelData.connecting ? "Connecting…"
                          : !modelData.hasCredentials ? "Credentials required"
                          : modelData.askPassword ? "Password asked on each connection"
                          : "Credentials saved"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  PanelActionButton {
                    visible: !modelData.active && !modelData.connecting
                    iconText: "󰍂"
                    tooltipText: "Connect"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.activate(modelData)
                  }

                  PanelActionButton {
                    visible: !modelData.active && !modelData.connecting
                    iconText: "󰏫"
                    tooltipText: "Rename profile"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.openRename(modelData)
                  }

                  PanelActionButton {
                    visible: !modelData.active && !modelData.connecting
                    iconText: "󰌆"
                    tooltipText: "Edit keyring credentials"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.openCredentials(modelData, false)
                  }

                  PanelActionButton {
                    visible: !modelData.active && !modelData.connecting && (modelData.imported || modelData.hasCredentials)
                    iconText: "󰆴"
                    tooltipText: "Forget profile and credentials"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.runAction("forget", modelData.path)
                  }

                  PanelActionButton {
                    visible: modelData.active === true || modelData.connecting === true
                    iconText: "󰍃"
                    tooltipText: modelData.connecting ? "Cancel connection" : "Disconnect"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.disconnect(modelData.path)
                  }
                }
              }
            }
          }

          Column {
            visible: root.renamePath !== ""
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader {
              text: "PROFILE NAME"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: profileNameField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Profile name"
              text: root.renameText
              onTextChanged: root.renameText = text
              onAccepted: root.saveRename()
              Keys.onEscapePressed: root.closeRename()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Save name"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !actionProcess.running
                onClicked: root.saveRename()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeRename()
              }
            }
          }

          Column {
            visible: root.promptPath !== ""
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader {
              text: "PASSWORD · " + root.promptName.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: promptField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Password or one-time code"
              password: true
              text: root.promptText
              onTextChanged: root.promptText = text
              onAccepted: root.submitPasswordPrompt()
              Keys.onEscapePressed: root.closePasswordPrompt()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Connect"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !actionProcess.running
                onClicked: root.submitPasswordPrompt()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closePasswordPrompt()
              }
            }
          }

          Column {
            visible: root.editPath !== ""
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.foreground }
            PanelSectionHeader {
              text: "CREDENTIALS · " + root.editName.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: usernameField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Username"
              text: root.usernameText
              onTextChanged: root.usernameText = text
              onAccepted: root.askPasswordChoice ? root.saveCredentials() : passwordField.forceActiveFocus()
              Keys.onEscapePressed: root.closeCredentials()
            }

            Toggle {
              width: parent.width
              label: "Ask for the password on every connection"
              description: "For one-time passwords (OTP/MFA). Only the username is stored."
              foreground: root.foreground
              fontFamily: root.fontFamily
              checked: root.askPasswordChoice
              onClicked: root.askPasswordChoice = !root.askPasswordChoice
            }

            TextField {
              id: passwordField
              visible: !root.askPasswordChoice
              width: parent.width
              foreground: root.foreground
              placeholderText: "Password"
              password: true
              text: root.passwordText
              onTextChanged: root.passwordText = text
              onAccepted: root.saveCredentials()
              Keys.onEscapePressed: root.closeCredentials()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: root.connectAfterSave ? "Save and connect" : "Save to keyring"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !actionProcess.running
                onClicked: root.saveCredentials()
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeCredentials()
              }
            }
          }
        }
      }
    }
  }
}
