import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5
import org.kde.ksysguard.sensors as Sensors

PlasmoidItem {
    id: root

    // --- Keep-awake timer state ---
    property bool active: false
    property double expires: 0
    property string mode: "full"
    property int selectedMinutes: 60
    property string errorMessage: ""
    property double nowSeconds: Date.now() / 1000
    property int remaining: expires > 0 ? Math.max(0, Math.ceil(expires - nowSeconds)) : 0

    // --- Fan state ---
    // Configuration is not populated yet on the first binding pass, so every read
    // needs a fallback — otherwise the sensors bind to undefined and stay empty.
    readonly property string fanStatusHelper: "/usr/local/bin/thinkpad-fan-status"
    readonly property string fanSetHelper: "/usr/local/bin/thinkpad-fan-set"
    readonly property string fanSensorId: Plasmoid.configuration.fanSensorId
                                          || "lmsensors/thinkpad-isa-0000/fan1"
    readonly property string tempSensorId: Plasmoid.configuration.tempSensorId
                                           || "cpu/all/maximumTemperature"
    property bool showFrequency: Plasmoid.configuration.showFrequency !== false
    property bool showThrottling: Plasmoid.configuration.showThrottling !== false

    property string fanLevel: ""
    property bool thinkfanRunning: false
    property int freqMhz: 0
    property bool fanHelperMissing: false
    property string fanError: ""
    property string currentTab: "timer"

    // --- Touchpad state ---
    // "" = not polled yet; "enabled" / "disabled" / "unavailable" (no touchpad).
    readonly property string touchpadHelper: "/usr/local/bin/toolbox-touchpad"
    property string touchpadState: ""
    property string touchpadName: ""
    property bool touchpadHelperMissing: false
    property string touchpadError: ""

    // Throttling is derived from the growth of the kernel event counter between
    // polls: package_throttle_total_time_ms stays 0 on several Intel generations,
    // while the counter is reliable. Note this reflects *thermal* throttling only —
    // a power (RAPL) limit does not raise it, but does hold the frequency down.
    property int throttleCount: -1
    property bool throttling: false

    // fanLevel "n/a" means the status helper ran but there is no ThinkPad fan
    // interface; "" means we have not polled yet.
    readonly property bool fanDetected: fanLevel !== "" && fanLevel !== "n/a"
    // Three distinct states: thinkfan drives its curve, the level is handed to the
    // firmware, or a level is pinned manually.
    readonly property bool autoMode: thinkfanRunning || fanLevel === "auto"
    readonly property string modeText: thinkfanRunning ? "Mode: automatic (thinkfan)"
                                     : fanLevel === "auto" ? "Mode: automatic (firmware)"
                                     : fanDetected ? "Mode: manual, level " + fanLevel
                                     : fanLevel === "" ? "Checking for fan…"
                                     : "Fan control unavailable"

    readonly property int rpm: fanSensor.value !== undefined ? Math.round(fanSensor.value) : 0
    readonly property int temp: tempSensor.value !== undefined ? Math.round(tempSensor.value) : 0

    preferredRepresentation: compactRepresentation
    toolTipMainText: "System Toolbox"
    toolTipSubText: (active ? (expires === 0 ? "Active indefinitely" : formatTime(remaining) + " remaining") : "Power saving enabled")
                    + (fanDetected ? "\n" + temp + "°C, " + rpm + " RPM" : "")
                    + (touchpadState === "disabled" ? "\nTouchpad: OFF" : "")

    function formatTime(sec) {
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60
        return (h > 0 ? String(h).padStart(2, '0') + ':' : '') + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0')
    }
    function run(args) { executor.connectSource("caffeine-timer-helper " + args) }
    function refresh() { run("status") }
    function start() { run("start " + selectedMinutes + " " + mode) }
    function stop() { run("stop") }
    Component.onCompleted: { refresh(); fanExec.poll(); touchExec.poll() }
    Timer { interval: 1000; running: root.active; repeat: true; onTriggered: { root.nowSeconds = Date.now() / 1000; if (root.expires > 0 && root.remaining === 0) root.refresh() } }
    Timer { interval: 5000; running: true; repeat: true; onTriggered: { root.refresh(); touchExec.poll() } }
    P5.DataSource {
        id: executor
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)

            try {
                const result = JSON.parse(data.stdout)
                if (result.error) { root.errorMessage = result.error; return }
                root.active = result.active
                root.expires = result.until || 0
                if (result.mode) root.mode = result.mode
                // Re-anchor "now" to the reply: the 1s countdown timer only ticks
                // while active, so without this the first display lags ~1s behind.
                root.nowSeconds = Date.now() / 1000
                root.errorMessage = ""
            } catch(e) { root.errorMessage = String(e) }
        }
    }

    Sensors.Sensor {
        id: fanSensor
        sensorId: root.fanSensorId
        updateRateLimit: 2000
        enabled: true
    }

    Sensors.Sensor {
        id: tempSensor
        sensorId: root.tempSensorId
        updateRateLimit: 2000
        enabled: true
    }

    // Reading state and switching levels go through helper scripts, which keeps
    // shell quoting out of QML and confines privileged work to one audited place.
    P5.DataSource {
        id: fanExec
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            fanExec.disconnectSource(source)
            if (source === root.fanStatusHelper) {
                root.fanHelperMissing = (data["exit code"] !== 0)

                var parts = (data.stdout || "").trim().split("|")
                if (parts.length >= 2) {
                    root.fanLevel = parts[0]
                    root.thinkfanRunning = (parts[1] === "active")
                }
                if (parts.length >= 4) {
                    root.freqMhz = parseInt(parts[2]) || 0

                    var c = parseInt(parts[3]) || 0
                    // First sample is only remembered: nothing to compare against yet.
                    root.throttling = (root.throttleCount >= 0 && c > root.throttleCount)
                    root.throttleCount = c
                }
            } else {
                // Result of `pkexec thinkpad-fan-set <level>`: surface failures
                // instead of silently leaving the old level behind.
                if (data["exit code"] !== 0) {
                    root.fanError = ((data.stderr || "Failed to set fan level").trim())
                } else {
                    root.fanError = ""
                }
                fanRefresh.restart()
            }
        }

        function poll() {
            fanExec.connectSource(root.fanStatusHelper)
        }

        function setLevel(value) {
            root.fanError = ""
            // pkexec + a polkit rule with allow_active=yes: no password prompt for
            // the local session, and no sudoers editing by the user.
            // `value` only ever comes from the fixed buttons below, never from input.
            fanExec.connectSource("pkexec " + root.fanSetHelper + " " + value)
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: fanExec.poll()
    }

    // Quick re-read after a level change completes, so the UI does not lag behind.
    Timer {
        id: fanRefresh
        interval: 700
        repeat: false
        onTriggered: fanExec.poll()
    }

    // Touchpad state lives in KWin; the widget only shells out to qdbus6 via
    // the helper, which discovers the touchpad node on every call (eventN
    // varies per machine and boot). Toggle is NoReply, so re-poll after it.
    P5.DataSource {
        id: touchExec
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            touchExec.disconnectSource(source)
            if (data["exit code"] !== 0) {
                var err = ((data.stderr || "").trim())
                if (err === "") {
                    root.touchpadHelperMissing = true
                } else {
                    root.touchpadError = err
                }
                return
            }
            root.touchpadHelperMissing = false
            var out = ((data.stdout || "").trim())
            if (out === "unavailable" || out === "") {
                root.touchpadState = "unavailable"
            } else {
                var parts = out.split("|")
                root.touchpadState = parts[0]
                root.touchpadName = parts.length > 1 ? parts[1] : ""
            }
            root.touchpadError = ""
            if (source !== root.touchpadHelper + " status") {
                touchRefresh.restart()
            }
        }

        function poll() {
            touchExec.connectSource(root.touchpadHelper + " status")
        }

        function toggle() {
            root.touchpadError = ""
            touchExec.connectSource(root.touchpadHelper + " toggle")
        }
    }

    Timer {
        id: touchRefresh
        interval: 700
        repeat: false
        onTriggered: touchExec.poll()
    }

    compactRepresentation: MouseArea {
        implicitWidth: Kirigami.Units.iconSizes.medium
        implicitHeight: Kirigami.Units.iconSizes.medium
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height)
            height: width
            source: root.active ? "chronometer" : "applications-system"
        }
    }

    fullRepresentation: ColumnLayout {
        implicitWidth: Kirigami.Units.gridUnit * 22
        spacing: Kirigami.Units.smallSpacing * 2

        RowLayout {
            Layout.fillWidth: true
            PC3.Button {
                Layout.fillWidth: true
                text: "Timer"
                highlighted: root.currentTab === "timer"
                onClicked: root.currentTab = "timer"
            }
            PC3.Button {
                Layout.fillWidth: true
                text: "Fan"
                highlighted: root.currentTab === "fan"
                onClicked: root.currentTab = "fan"
            }
            PC3.Button {
                Layout.fillWidth: true
                text: "Touchpad"
                highlighted: root.currentTab === "touchpad"
                onClicked: root.currentTab = "touchpad"
            }
        }

        // ---- Timer page ----
        ColumnLayout {
            visible: root.currentTab === "timer"
            spacing: Kirigami.Units.smallSpacing * 2
            RowLayout {
                Layout.fillWidth: true
                PC3.Label { text: "☕"; font.pixelSize: 26 }
                ColumnLayout {
                    PC3.Label { text: "Caffeine Timer"; font.bold: true }
                    PC3.Label { text: root.active ? "Keeping your system awake" : "Ready to start"; opacity: 0.7 }
                }
                PC3.Label { text: root.active ? "● ON" : "OFF"; color: root.active ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor }
            }
            PC3.Label {
                Layout.alignment: Qt.AlignHCenter
                text: root.active ? (root.expires === 0 ? "∞" : root.formatTime(root.remaining)) : "--:--"
                font.pixelSize: 36
                font.bold: true
            }
            PC3.Label { Layout.alignment: Qt.AlignHCenter; text: root.active ? "Remaining time" : "Choose a duration"; opacity: 0.65 }
            Flow {
                Layout.fillWidth: true
                spacing: 5
                Repeater {
                    model: [{m:15,t:"15m"},{m:30,t:"30m"},{m:60,t:"1h"},{m:120,t:"2h"},{m:240,t:"4h"},{m:0,t:"∞"}]
                    delegate: PC3.Button {
                        required property var modelData
                        text: modelData.t
                        checkable: true
                        checked: root.selectedMinutes === modelData.m
                        onClicked: root.selectedMinutes = modelData.m
                    }
                }
            }
            PC3.CheckBox {
                text: "Keep display awake too"
                checked: root.mode === "full"
                onToggled: root.mode = checked ? "full" : "sleep"
            }
            RowLayout {
                Layout.fillWidth: true
                PC3.Button { text: "Stop"; enabled: root.active; onClicked: root.stop() }
                PC3.Button { Layout.fillWidth: true; text: root.active ? "Restart timer" : "Start"; highlighted: true; onClicked: root.start() }
            }
            PC3.Label {
                Layout.fillWidth: true
                visible: root.errorMessage.length > 0
                text: root.errorMessage
                wrapMode: Text.Wrap
                color: Kirigami.Theme.negativeTextColor
            }
        }

        // ---- Fan page ----
        ColumnLayout {
            visible: root.currentTab === "fan"
            spacing: Kirigami.Units.smallSpacing

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.fanHelperMissing
                type: Kirigami.MessageType.Error
                text: "Helper scripts are missing. Run install.sh from the project."
            }
            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: !root.fanHelperMissing && !root.fanDetected
                type: Kirigami.MessageType.Warning
                text: root.fanLevel === ""
                      ? "Checking for ThinkPad fan interface…"
                      : "No ThinkPad fan interface (/proc/acpi/ibm/fan). The timer still works."
            }

            Kirigami.Heading {
                Layout.fillWidth: true
                level: 2
                text: root.rpm + " RPM"
            }

            PC3.Label {
                Layout.fillWidth: true
                text: "Temperature: " + root.temp + " °C"
            }

            PC3.Label {
                Layout.fillWidth: true
                visible: root.showFrequency
                text: "Frequency: " + root.freqMhz + " MHz"
            }

            PC3.Label {
                Layout.fillWidth: true
                visible: root.showThrottling
                text: root.throttling ? "Throttling: YES (" + root.throttleCount + " events)"
                                      : "Throttling: no"
                color: root.throttling ? Kirigami.Theme.negativeTextColor
                                       : Kirigami.Theme.positiveTextColor
            }

            PC3.Label {
                Layout.fillWidth: true
                text: root.modeText
            }

            Kirigami.Separator { Layout.fillWidth: true }

            PC3.Button {
                Layout.fillWidth: true
                text: "Automatic"
                icon.name: "system-run"
                enabled: root.fanDetected
                highlighted: root.autoMode
                onClicked: fanExec.setLevel("auto")
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 4
                rowSpacing: Kirigami.Units.smallSpacing
                columnSpacing: Kirigami.Units.smallSpacing

                Repeater {
                    model: ["0", "1", "2", "3", "4", "5", "6", "7"]

                    PC3.Button {
                        required property string modelData
                        Layout.fillWidth: true
                        text: modelData
                        enabled: root.fanDetected
                        highlighted: !root.autoMode && root.fanLevel === modelData
                        onClicked: fanExec.setLevel(modelData)
                    }
                }
            }

            PC3.Button {
                Layout.fillWidth: true
                text: "Full speed"
                enabled: root.fanDetected
                highlighted: !root.autoMode && root.fanLevel === "disengaged"
                onClicked: fanExec.setLevel("full")
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.fanError.length > 0
                type: Kirigami.MessageType.Error
                text: root.fanError
            }

            Item { Layout.fillHeight: true }
        }

        // ---- Touchpad page ----
        ColumnLayout {
            visible: root.currentTab === "touchpad"
            spacing: Kirigami.Units.smallSpacing

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.touchpadHelperMissing
                type: Kirigami.MessageType.Error
                text: "Helper script is missing. Run install.sh from the project."
            }
            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: !root.touchpadHelperMissing && root.touchpadState === "unavailable"
                type: Kirigami.MessageType.Warning
                text: "No touchpad found on this machine."
            }

            PC3.Label {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                text: root.touchpadState === "enabled" ? "Touchpad: ON"
                      : root.touchpadState === "disabled" ? "Touchpad: OFF" : "…"
                font.pixelSize: 28
                font.bold: true
                color: root.touchpadState === "disabled" ? Kirigami.Theme.negativeTextColor
                      : root.touchpadState === "enabled" ? Kirigami.Theme.positiveTextColor
                      : Kirigami.Theme.disabledTextColor
            }

            PC3.Label {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                visible: root.touchpadName !== "" && root.touchpadState !== "unavailable"
                text: root.touchpadName
                opacity: 0.65
                elide: Text.ElideMiddle
            }

            PC3.Button {
                Layout.fillWidth: true
                text: root.touchpadState === "disabled" ? "Enable touchpad" : "Disable touchpad"
                enabled: root.touchpadState === "enabled" || root.touchpadState === "disabled"
                highlighted: true
                onClicked: touchExec.toggle()
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.touchpadError.length > 0
                type: Kirigami.MessageType.Error
                text: root.touchpadError
            }

            Item { Layout.fillHeight: true }
        }
    }
}
