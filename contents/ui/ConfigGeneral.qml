import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

// Fan tab settings. Ported from plasma-thinkpad-fan
// (MIT, (c) AiSee <aiseeq@gmail.com>); i18n() calls replaced with plain
// strings to match the rest of this applet.
Kirigami.FormLayout {
    id: page

    property alias cfg_fanSensorId: fanSensor.text
    property alias cfg_tempSensorId: tempSensor.text
    property alias cfg_showFrequency: showFrequency.checked
    property alias cfg_showThrottling: showThrottling.checked

    QQC2.TextField {
        id: fanSensor
        Kirigami.FormData.label: "Fan sensor:"
        Layout.fillWidth: true
    }

    QQC2.TextField {
        id: tempSensor
        Kirigami.FormData.label: "Temperature sensor:"
        Layout.fillWidth: true
    }

    QQC2.Label {
        Layout.fillWidth: true
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        text: "Sensor ids differ between models. List the available ones with:\nbusctl --user call org.kde.ksystemstats1 /org/kde/ksystemstats1 org.kde.ksystemstats1 allSensors"
    }

    Item { Kirigami.FormData.isSection: true }

    QQC2.CheckBox {
        id: showFrequency
        Kirigami.FormData.label: "Show in popup:"
        text: "CPU frequency"
    }

    QQC2.CheckBox {
        id: showThrottling
        text: "Thermal throttling"
    }
}
