import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "networkIndicator"

    StyledText {
        width: parent.width
        text: "Network Indicator"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Monitor your network upload and download speeds in real time."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "updateInterval"
        label: "Update Interval"
        description: "How often to poll network statistics"
        defaultValue: 2
        minimum: 1
        maximum: 10
        unit: "s"
    }

    SelectionSetting {
        settingKey: "displayUnit"
        label: "Display Unit"
        description: "Unit for speed display"
        options: [
            { label: "Auto (B/s → KB/s → MB/s)", value: "auto" },
            { label: "KB/s", value: "kbps" },
            { label: "MB/s", value: "mbps" }
        ]
        defaultValue: "auto"
    }

    SelectionSetting {
        settingKey: "displayMode"
        label: "Display Mode"
        description: "Show upload and download separately, or as a single combined speed"
        options: [
            { label: "Separate (↓ + ↑)", value: "separate" },
            { label: "Combined (total speed)", value: "combined" }
        ]
        defaultValue: "separate"
    }

    ListSettingWithInput {
        settingKey: "trackedInterfaces"
        label: "Tracked Interfaces"
        description: "Only track these interfaces (their traffic is summed). Leave empty to track all real interfaces automatically. Use names exactly as they appear in /sys/class/net, e.g. \"wlan0\" or \"enp3s0\"."
        fields: [
            { id: "name", placeholder: "e.g. wlan0", required: true, width: 200 }
        ]
        defaultValue: []
    }

    ListSettingWithInput {
        settingKey: "interfaceGroups"
        label: "Interface Groups"
        description: "Group interfaces by name pattern and view each group's traffic in the popout and history. Patterns are regular expressions matched against the whole interface name (a plain name like \"wlan0\" also works). Groups are ordered: an interface counts toward the first matching group; unmatched interfaces land in \"Other\". Virtual/tunnel interfaces matched by a group are shown in that group only — the bar total always counts physical interfaces once."
        fields: [
            { id: "name", placeholder: "e.g. VPN", required: true, width: 120 },
            { id: "pattern", placeholder: "e.g. (wg|tun).*", required: true, width: 170 }
        ]
        defaultValue: []
    }

    ToggleSetting {
        settingKey: "perAppTraffic"
        label: "Per-App Traffic"
        description: "Show live per-application traffic in the popout while it is open. Requires nethogs with packet-capture capabilities: sudo setcap 'cap_net_admin,cap_net_raw+ep' $(command -v nethogs)"
        defaultValue: false
    }
}
