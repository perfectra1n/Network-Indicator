import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets

// Live per-application traffic via `nethogs -t` (trace mode). The helper
// process only runs while `active` is true (popout open + setting enabled),
// so there is zero idle cost. Rates are display-only — nothing is persisted.
Column {
    id: section

    // Wired up by the parent popout
    property bool active: false
    property var formatSpeedFn: null

    // "starting" | "ok" | "missing" | "noperm"
    property string status: "starting"

    readonly property int rowHeight: 24
    readonly property int maxRows: 6

    // Reported to the popout so it can budget popoutHeight from constants
    // instead of live item sizes (see the layout-race note in
    // NetworkIndicator.qml's updatePopoutHeight). The rows area is reserved
    // at maxRows so the popout doesn't animate every time the app list churns.
    readonly property real sectionHeight: {
        var h = 18 + Theme.spacingXS; // header
        if (status === "missing" || status === "noperm") return h + 48;
        return h + maxRows * (rowHeight + Theme.spacingXS);
    }

    spacing: Theme.spacingXS

    ListModel { id: appsModel }
    // program name → {sent, recv} accumulating the batch currently streaming in
    property var _staging: ({})
    // The first "Refreshing:" marker precedes any data rows — publishing there
    // would show a bogus empty "No active traffic" batch
    property bool _sawFirstMarker: false
    property int _restarts: 0

    onActiveChanged: {
        // Always stop first; the delayed start below sidesteps the race where
        // running = true is a no-op because the old process is still dying
        hogsProcess.running = false;
        if (active) {
            status = "starting";
            _staging = {};
            _sawFirstMarker = false;
            _restarts = 0;
            appsModel.clear();
            startTimer.restart();
        } else {
            startTimer.stop();
        }
    }

    Timer {
        id: startTimer
        interval: 300
        onTriggered: {
            if (section.active) hogsProcess.running = true;
        }
    }

    // "path/pid/uid" (or pseudo-entries like "unknown TCP/0/0") → display name
    function displayName(prog) {
        var parts = prog.split("/");
        if (parts.length >= 3) parts = parts.slice(0, parts.length - 2); // drop pid/uid
        var path = parts.join("/");
        var slash = path.lastIndexOf("/");
        var name = (slash >= 0 ? path.substring(slash + 1) : path).trim();
        return name || "unknown";
    }

    // A "Refreshing:" line marks the start of the next batch, so the staged
    // batch is complete — publish it (top talkers first)
    function publishStaging() {
        section.status = "ok";
        var progs = Object.keys(_staging);
        var list = [];
        for (var i = 0; i < progs.length; i++) {
            var s = _staging[progs[i]];
            if (s.sent + s.recv <= 0) continue; // hide idle rows
            list.push({ "name": progs[i], "sent": s.sent, "recv": s.recv });
        }
        list.sort(function(a, b) { return (b.sent + b.recv) - (a.sent + a.recv); });
        list = list.slice(0, maxRows);

        // Update in place when the row set is stable to avoid delegate churn
        var sameShape = appsModel.count === list.length;
        if (sameShape) {
            for (var j = 0; j < list.length; j++) {
                if (appsModel.get(j).name !== list[j].name) {
                    sameShape = false;
                    break;
                }
            }
        }
        if (sameShape) {
            for (var k = 0; k < list.length; k++) {
                appsModel.setProperty(k, "sent", list[k].sent);
                appsModel.setProperty(k, "recv", list[k].recv);
            }
        } else {
            appsModel.clear();
            for (var m = 0; m < list.length; m++) {
                appsModel.append(list[m]);
            }
        }
        _staging = {};
    }

    Process {
        id: hogsProcess
        // exec so stopping the Process signals nethogs itself, not the shell;
        // exit 127 cleanly distinguishes "not installed" from "no permission"
        command: ["sh", "-c", "command -v nethogs >/dev/null 2>&1 || exit 127; exec nethogs -t -d 2"]
        stdout: SplitParser {
            onRead: line => {
                if (line.startsWith("Refreshing:")) {
                    if (!section._sawFirstMarker) {
                        section._sawFirstMarker = true; // batch 1 starts now
                        return;
                    }
                    section.publishStaging();
                    return;
                }
                // Data rows: "program/pid/uid\tsent\treceived" in KB/s.
                // Anything else (banner, blank lines) fails the parse and is skipped.
                var parts = line.split("\t");
                if (parts.length < 3) return;
                var sent = parseFloat(parts[parts.length - 2]);
                var recv = parseFloat(parts[parts.length - 1]);
                if (!isFinite(sent) || !isFinite(recv)) return;
                var prog = section.displayName(parts.slice(0, parts.length - 2).join("\t"));
                var cur = section._staging[prog] || { sent: 0, recv: 0 };
                cur.sent += sent * 1024; // nethogs reports KB/s
                cur.recv += recv * 1024;
                section._staging[prog] = cur; // plain dict, no notify needed
            }
        }
        stderr: SplitParser {
            onRead: line => console.warn("NetworkIndicator: nethogs:", line)
        }
        onExited: exitCode => {
            if (!section.active) return;        // we stopped it ourselves
            if (startTimer.running) return;     // stale exit from a superseded process
            if (exitCode === 127) {
                section.status = "missing";
            } else if (section._sawFirstMarker && section._restarts < 3) {
                // It was working and died (crash, transient) — restart quietly.
                // A process that never produced output failed to start: that
                // is the capabilities case, so don't loop on it.
                section._restarts++;
                section._sawFirstMarker = false;
                section._staging = {};
                startTimer.restart();
            } else {
                section.status = "noperm";
            }
        }
    }

    StyledText {
        text: "By Application"
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Bold
        color: Theme.surfaceVariantText
    }

    StyledText {
        visible: section.status === "missing" || section.status === "noperm"
        width: parent.width
        text: section.status === "missing"
            ? "nethogs is not installed — install it to see per-app traffic."
            : "nethogs needs capture permissions:\nsudo setcap 'cap_net_admin,cap_net_raw+ep' $(command -v nethogs)"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WrapAnywhere
    }

    StyledText {
        visible: (section.status === "starting" || section.status === "ok") && appsModel.count === 0
        height: section.rowHeight
        text: section.status === "ok" ? "No active traffic" : "Measuring…"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        verticalAlignment: Text.AlignVCenter
    }

    Repeater {
        model: appsModel

        Row {
            id: appRow
            required property string name
            required property real sent
            required property real recv

            width: parent.width
            height: section.rowHeight
            spacing: Theme.spacingS

            StyledText {
                text: appRow.name
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                elide: Text.ElideRight
                width: parent.width - dlGroup.width - ulGroup.width - Theme.spacingS * 2
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                id: dlGroup
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "arrow_downward"
                    size: 12
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: section.formatSpeedFn ? section.formatSpeedFn(appRow.recv) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Row {
                id: ulGroup
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "arrow_upward"
                    size: 12
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: section.formatSpeedFn ? section.formatSpeedFn(appRow.sent) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
