import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
// Omarchy 4.5 exports its own Commons.Translations, which an unqualified
// "Translations" would resolve to; this directory's loader must win.
import "." as Local

Item {
  id: root

  Local.Translations { id: strings }

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  // Only the selected PAM conversation owns the input. PINs never reach the
  // password service; timeout/error never selects another method.
  property string authMethod: "password"
  readonly property bool keyResponseRequired: authMethod === "key" && fido2Pam.active && fido2Pam.responseRequired
  readonly property string inputPrompt: authMethod === "key" ? (keyResponseRequired ? fido2Pam.message : strings.t("Touch your security key")) : (authMethod === "fingerprint" ? strings.t("Touch the fingerprint reader") : strings.t("Enter password"))
  property bool fido2Authenticating: false
  property bool fido2Configured: false
  property bool fido2StatusKnown: false
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false
  property var mediaPausedByLock: []

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure

  // Read the current lock state for each decision. A stale property binding
  // can report an unlocked session as locked and skip a lock before suspend.
  function currentlyLocked() {
    return lockRequested || sessionLock.locked || sessionLock.secure
  }
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating || fido2Authenticating

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early may be an orphan behind Hyprland's failsafe. It
  // may also be another shell's live lock, which Hyprland would let this one
  // take over and then strand on exit, so the helper answers undetermined while
  // another locker runs. Outputs are often still absent here, so ask until the
  // answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock acquired by this shell does not require orphan recovery.
    if (currentlyLocked()) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || currentlyLocked() || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function refreshFido2Status() {
    if (!fido2CheckProc.running) fido2CheckProc.running = true
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintRetryTimer.stop()
    fido2Authenticating = false
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
    if (fido2Pam.active) fido2Pam.abort()
  }

  function mediaPlayerKey(player) {
    return String(player && (player.dbusName || player.desktopEntry || player.identity) || "")
  }

  function pauseMediaForLock() {
    var paused = []
    var players = Mpris.players ? Mpris.players.values : []

    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      var key = mediaPlayerKey(player)
      if (!player || !key || !player.isPlaying) continue

      if (player.canPause) {
        paused.push(key)
        player.pause()
      } else if (player.canTogglePlaying) {
        paused.push(key)
        player.togglePlaying()
      }
    }

    mediaPausedByLock = paused
    logEvent("media-paused=" + paused.length)
  }

  function resumeMediaAfterUnlock() {
    var keys = mediaPausedByLock
    mediaPausedByLock = []
    if (!keys.length) return

    var players = Mpris.players ? Mpris.players.values : []
    var resumed = 0
    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      if (!player || player.isPlaying || keys.indexOf(mediaPlayerKey(player)) === -1) continue

      if (player.canPlay) {
        player.play()
        resumed += 1
      } else if (player.canTogglePlaying) {
        player.togglePlaying()
        resumed += 1
      }
    }

    logEvent("media-resumed=" + resumed)
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    authMethod = fido2Configured || !fido2StatusKnown ? "key" : "password"
    lockRequested = true
    pauseMediaForLock()
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFido2Status()
    })

    return true
  }

  function finishUnlock() {
    if (!root.currentlyLocked()) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    resumeMediaAfterUnlock()
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) armBlankTimer()
  }

  function runBlank() {
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    if (authMethod === "key") {
      if (keyResponseRequired) {
        enteredPassword = ""
        failureMessage = ""
        fido2Pam.respond(password)
      }
      return
    }
    if (authMethod !== "password") return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (authMethod !== "password" || !authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired || !pendingPassword) return
    passwordPam.respond(pendingPassword)
    pendingPassword = ""
  }

  function chooseMethod(method) {
    if (!lockRequested || ["key", "password", "fingerprint"].indexOf(method) === -1) return
    if (method === "key" && !fido2Configured) return
    if (method === "fingerprint" && !fingerprintConfigured) return
    // Change the selection before aborting: a queued success from the old
    // conversation must not unlock after the user has switched methods.
    authMethod = method
    resetAuthenticationState()
    runWake()
    if (method === "key") Qt.callLater(startFido2)
    if (method === "fingerprint") Qt.callLater(startFingerprint)
  }

  function handlePasswordFailure() {
    if (!lockRequested || authMethod !== "password") return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (%1)"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || authMethod !== "fingerprint" || !sessionLock.secure || !fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false

    if (!lockRequested || authMethod !== "fingerprint") return
    if (result === PamResult.Success) {
      finishUnlock()
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart()
    }
  }

  function startFido2() {
    if (!lockRequested || authMethod !== "key" || !sessionLock.secure || !fido2Configured) return
    if (fido2Pam.active || fido2Authenticating) return

    fido2Authenticating = true
    if (!fido2Pam.start()) {
      fido2Authenticating = false
      failureMessage = "Security key unavailable — retry or use password"
    }
  }

  function handleFido2Finished(result) {
    fido2Authenticating = false

    enteredPassword = ""
    if (!lockRequested || authMethod !== "key") return
    if (result === PamResult.Success) {
      logEvent("unlock: fido2")
      finishUnlock()
    } else {
      failureMessage = "Security key authentication failed — retry or use password"
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
        root.startFido2()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Commons.Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        fido2Configured: root.fido2Configured
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        passwordText: root.enteredPassword
        authMethod: root.authMethod
        inputPrompt: root.inputPrompt
        keyResponseRequired: root.keyResponseRequired
        onChooseMethod: function(method) { root.chooseMethod(method) }
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
      fido2Configured: root.fido2Configured
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      passwordText: ""
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested || root.authMethod !== "password") return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.fingerprintAuthenticating = false
      if (root.lockRequested && root.authMethod === "fingerprint" && root.fingerprintConfigured) fingerprintRetryTimer.restart()
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  PamContext {
    id: fido2Pam
    config: "omarchy-lock-fido2"
    user: root.userName

    onResponseRequiredChanged: root.enteredPassword = ""
    onPamMessage: root.enteredPassword = ""

    onCompleted: function(result) {
      root.handleFido2Finished(result)
    }

    onError: function(error) {
      root.handleFido2Finished(PamResult.Error)
    }
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
      }
    }
  }

  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1 && fprintd-list \"$USER\" 2>/dev/null | grep -qi finger; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: {
      root.fingerprintConfigured = String(fingerprintCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fingerprintConfigured) root.startFingerprint()
      else if (!root.fingerprintConfigured && fingerprintPam.active) fingerprintPam.abort()
    }
  }

  Process {
    id: fido2CheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fido2 && -s /etc/fido2/fido2 ]] && grep -q \"^$USER:\" /etc/fido2/fido2; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fido2CheckStdout; waitForEnd: true }
    onExited: {
      root.fido2StatusKnown = true
      root.fido2Configured = String(fido2CheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fido2Configured) root.startFido2()
      else if (!root.fido2Configured) {
        if (fido2Pam.active) fido2Pam.abort()
        // Only choose an initial password route once discovery proves there
        // is no configured key route; key failures never change the method.
        if (root.lockRequested && root.authMethod === "key" && !root.fido2Authenticating)
          root.chooseMethod("password")
      }
    }
  }

  Process {
    id: strandedLockCheckProc
    // $PPID is this shell: a crash re-execs in place, so its pid is the one to skip.
    command: ["bash", "-c", "omarchy-hyprland-session-lock-stranded \"$PPID\""]
    onExited: function(exitCode) {
      // Lock state cannot be queried until an output is available.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.currentlyLocked()
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    // Keep the lock screen visible long enough to confirm the lock and read
    // its status before powering the displays down.
    interval: 60000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // Wait for PAM validation before locking. Refresh the lock state afterward,
  // since the compositor failsafe may have been cleared from a TTY meanwhile.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprintStatus()
    refreshFido2Status()
    checkStrandedLock()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.currentlyLocked() && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.currentlyLocked() ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.currentlyLocked(),
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        fido2: root.fido2Configured,
        fido2Authenticating: root.fido2Authenticating,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFido2Status()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
