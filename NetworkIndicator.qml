pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root


    layerNamespacePlugin: "network-indicator"

    // ── Settings ──
    property int updateInterval: pluginData.updateInterval || 2
    property string displayUnit: pluginData.displayUnit || "auto"
    // "separate" = show ↑ and ↓ individually, "combined" = single total speed
    property string displayMode: pluginData.displayMode || "separate"
    // Interfaces the user chose to track; empty = track all real interfaces
    property var trackedInterfaces: pluginData.trackedInterfaces || []
    // Ordered regex groups ({ name, pattern }); an interface counts toward the
    // first group whose pattern matches, else the implicit "Other" bucket
    property var interfaceGroups: pluginData.interfaceGroups || []
    // Whether the per-app (nethogs) monitor is enabled
    property bool perAppTraffic: pluginData.perAppTraffic || false

    // Normalized interface names from the setting (accepts both plain strings
    // and the { name: ... } objects ListSettingWithInput stores)
    readonly property var _trackedIfaceNames: {
        var names = [];
        var list = trackedInterfaces || [];
        for (var i = 0; i < list.length; i++) {
            var n = (typeof list[i] === "string") ? list[i] : ((list[i] && list[i].name) || "");
            n = String(n).trim();
            if (n && names.indexOf(n) === -1) names.push(n);
        }
        return names;
    }

    // Compiled group patterns; anchored full-match, invalid regex degrades to
    // literal name equality (re: null) so a typo can't take the widget down
    readonly property var _compiledGroups: {
        var groups = [];
        var list = interfaceGroups || [];
        for (var i = 0; i < list.length; i++) {
            var name = String((list[i] && list[i].name) || "").trim();
            var pattern = String((list[i] && list[i].pattern) || "").trim();
            if (!name || !pattern) continue;
            var re = null;
            try { re = new RegExp("^(?:" + pattern + ")$"); }
            catch (e) {
                console.warn("NetworkIndicator: invalid group pattern \"" + pattern + "\", matching it literally");
            }
            groups.push({ name: name, pattern: pattern, re: re });
        }
        return groups;
    }

    function groupForIface(iface) {
        for (var i = 0; i < _compiledGroups.length; i++) {
            var g = _compiledGroups[i];
            if (g.re ? g.re.test(iface) : g.pattern === iface) return g.name;
        }
        return "Other";
    }

    // React to settings edits while the widget is running (the dataLoaded
    // guard skips the spurious fire during component construction)
    onInterfaceGroupsChanged: {
        if (!dataLoaded) return;
        syncGroupsModel();
        if (historyExpanded) {
            refreshNetworksModel();
            refreshHistoryModel();
        }
        updatePopoutHeight();
    }
    onPerAppTrafficChanged: {
        if (!dataLoaded) return;
        updatePopoutHeight();
    }
    // Going offline swaps the popout base height and hides the group rows;
    // coming back does the reverse — both need a height recompute
    onInterfaceFoundChanged: {
        if (!dataLoaded) return;
        updatePopoutHeight();
    }

    // ── Internal state ──
    property real downloadSpeed: 0
    property real uploadSpeed: 0
    property real totalSpeed: downloadSpeed + uploadSpeed
    property var prevCounters: ({})      // iface → {rx, tx} raw counters from the previous poll
    property bool interfaceFound: true  // assume online until first poll completes
    property var _cycleCounters: ({})    // per-cycle raw counters (iface → {rx, tx})
    property var _upIfaces: ({})         // per-cycle operstate lookup (iface → bool)
    property var _ssidByIface: ({})      // per-cycle SSID lookup (iface → ssid)
    property bool _lastPollFailed: false // last poll script exit status (for log throttling)

    // ── Persistent data usage tracking ──
    property var usageData: ({})        // full parsed JSON object
    property real todayRx: 0            // today's accumulated download bytes
    property real todayTx: 0            // today's accumulated upload bytes
    property var todayNetworks: ({})    // today's usage per network (SSID or iface name)
    property var todayInterfaces: ({})  // today's usage per interface
    property string todayKey: ""        // "yyyy-MM-dd" for current day
    property bool dataLoaded: false     // whether initial JSON was loaded
    property double _lastPollMs: 0      // wall time of the last counter read (real elapsed for speed)
    property bool historyExpanded: false // whether 30-day history panel is shown
    property real _maxDailyUsage: 1      // cached max for bar proportions (avoid O(n²))
    property string selectedFilterType: "all"  // "all" | "group" | "network"
    property string selectedFilterName: "All"  // active history filter chip
    property real unsavedBytes: 0       // bytes accumulated since last disk write

    // ── Tuning constants ──
    readonly property int saveIntervalMs: 7 * 60 * 1000          // periodic flush cadence
    readonly property real flushThresholdBytes: 50 * 1024 * 1024 // save early once this much is unsaved
    readonly property int historyRetentionDays: 30               // days of usage history kept
    readonly property int collapsedPopoutHeight: 220             // popout height with history collapsed
    readonly property int offlinePopoutHeight: 250               // collapsed height incl. offline banner
    readonly property int maxPopoutHeight: 680                   // cap when history is expanded
    readonly property int groupRowHeight: 28                     // height of one per-group usage row
    property real _perAppSectionH: 0                             // reported by the popout's PerAppSection

    // ── Offline reason detection (uses DMS NetworkService) ──
    property bool _dmsNetworkAvailable: typeof DMSNetworkService !== "undefined" && DMSNetworkService.networkAvailable
    property string offlineReason: {
        if (root.interfaceFound) return "";
        if (_dmsNetworkAvailable && !DMSNetworkService.wifiEnabled) return "wifi_off";
        return "disconnected";
    }

    // ── Formatting helpers ──
    function formatSpeed(bytesPerSec) {
        if (displayUnit === "kbps") {
            return (bytesPerSec / 1024).toFixed(1) + " KB/s";
        } else if (displayUnit === "mbps") {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s";
        }
        // auto
        if (bytesPerSec < 1024) {
            return bytesPerSec.toFixed(0) + " B/s";
        } else if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(1) + " KB/s";
        } else {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s";
        }
    }

    function formatBytes(bytes) {
        if (bytes < 1024) return bytes.toFixed(0) + " B";
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(2) + " MB";
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB";
    }

    function formatDateLabel(dateStr) {
        // "yyyy-MM-dd" → "Mon DD" e.g. "May 16"
        var d = new Date(dateStr + "T00:00:00");
        var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
        return months[d.getMonth()] + " " + d.getDate();
    }

    function getCurrentDateKey() {
        return Qt.formatDate(new Date(), "yyyy-MM-dd");
    }

    // ── Persistence: load via DMS Plugin State API ──
    function loadUsageData() {
        if (!pluginService) {
            return;  // Don't load or set dataLoaded — wait for pluginService to be injected
        }

        try {
            var days = pluginService.loadPluginState(pluginId, "days", {});
            var lastCounters = pluginService.loadPluginState(pluginId, "lastCounters", {});
            // Legacy single-interface keys (pre-1.5) — only used to seed lastCounters
            var lastRx = pluginService.loadPluginState(pluginId, "lastRxBytes", -1);
            var lastTx = pluginService.loadPluginState(pluginId, "lastTxBytes", -1);
            var lastIface = pluginService.loadPluginState(pluginId, "lastInterface", "");

            var safeDays = {};
            try { safeDays = JSON.parse(JSON.stringify(days || {})); }
            catch (e) { safeDays = days || {}; }
            // A hand-edited (or future-version) state file may hold wrong types
            if (typeof safeDays !== "object" || Array.isArray(safeDays) || safeDays === null) {
                safeDays = {};
            }

            // Migrate legacy data and coerce numeric fields (bad types would
            // otherwise poison the accumulated totals with NaN)
            var keys = Object.keys(safeDays);
            for (var i = 0; i < keys.length; i++) {
                var day = safeDays[keys[i]];
                if (!day || typeof day !== "object" || Array.isArray(day)) {
                    delete safeDays[keys[i]];
                    continue;
                }
                day.rx = Number(day.rx) || 0;
                day.tx = Number(day.tx) || 0;
                if (!day.networks || typeof day.networks !== "object" || Array.isArray(day.networks)) {
                    day.networks = { "unknown": { rx: day.rx, tx: day.tx } };
                }
                var nKeys = Object.keys(day.networks);
                for (var j = 0; j < nKeys.length; j++) {
                    var net = day.networks[nKeys[j]];
                    if (!net || typeof net !== "object") {
                        day.networks[nKeys[j]] = { rx: 0, tx: 0 };
                        continue;
                    }
                    net.rx = Number(net.rx) || 0;
                    net.tx = Number(net.tx) || 0;
                }
                // Pre-1.5 days have no per-interface split; group-filtered
                // views simply skip them rather than guessing an attribution
                if (!day.interfaces || typeof day.interfaces !== "object" || Array.isArray(day.interfaces)) {
                    day.interfaces = {};
                }
                var iKeys = Object.keys(day.interfaces);
                for (var k = 0; k < iKeys.length; k++) {
                    var ifc = day.interfaces[iKeys[k]];
                    if (!ifc || typeof ifc !== "object") {
                        day.interfaces[iKeys[k]] = { rx: 0, tx: 0 };
                        continue;
                    }
                    ifc.rx = Number(ifc.rx) || 0;
                    ifc.tx = Number(ifc.tx) || 0;
                }
            }

            // Sanitize the per-interface counter baselines the same way
            var safeCounters = {};
            if (lastCounters && typeof lastCounters === "object" && !Array.isArray(lastCounters)) {
                var cKeys = Object.keys(lastCounters);
                for (var c = 0; c < cKeys.length; c++) {
                    var entry = lastCounters[cKeys[c]];
                    if (!entry || typeof entry !== "object") continue;
                    var cr = Number(entry.rx);
                    var ct = Number(entry.tx);
                    if (isFinite(cr) && isFinite(ct) && cr >= 0 && ct >= 0) {
                        safeCounters[cKeys[c]] = { rx: cr, tx: ct };
                    }
                }
            }
            // Migrate pre-1.5 state: seed the per-interface map from the old
            // single-interface counter keys so the offline gap is still recovered
            if (Object.keys(safeCounters).length === 0 &&
                Number(lastRx) >= 0 && Number(lastTx) >= 0 && lastIface) {
                safeCounters[lastIface] = { rx: Number(lastRx), tx: Number(lastTx) };
            }

            usageData = { lastCounters: safeCounters, days: safeDays };
        } catch (e) {
            console.warn("NetworkIndicator: failed to load usage data, starting fresh:", e);
            usageData = { lastCounters: {}, days: {} };
        }
        // Fall through even on failure: dataLoaded must become true or the
        // poll/save timers never start and the widget stays dead


        todayKey = getCurrentDateKey();
        if (usageData.days[todayKey]) {
            todayRx = usageData.days[todayKey].rx || 0;
            todayTx = usageData.days[todayKey].tx || 0;
            // deep copy to avoid modifying the read-only proxy in some Qt versions
            todayNetworks = JSON.parse(JSON.stringify(usageData.days[todayKey].networks || {}));
            todayInterfaces = JSON.parse(JSON.stringify(usageData.days[todayKey].interfaces || {}));
        } else {
            todayRx = 0;
            todayTx = 0;
            todayNetworks = {};
            todayInterfaces = {};
        }

        dataLoaded = true;
    }

    // ── Persistence: save via DMS Plugin State API (auto-debounced 150ms) ──
    function saveUsageData() {
        if (!dataLoaded || !pluginService) return;

        try {
            usageData.days[todayKey] = { rx: todayRx, tx: todayTx, networks: todayNetworks, interfaces: todayInterfaces };
            // Merge live baselines over the saved ones: interfaces not seen
            // since load keep their saved baseline so their offline gap can
            // still be recovered whenever they next appear
            var mergedCounters = {};
            var savedKeys = Object.keys(usageData.lastCounters || {});
            for (var s = 0; s < savedKeys.length; s++) {
                mergedCounters[savedKeys[s]] = usageData.lastCounters[savedKeys[s]];
            }
            var liveKeys = Object.keys(prevCounters);
            for (var l = 0; l < liveKeys.length; l++) {
                mergedCounters[liveKeys[l]] = { rx: prevCounters[liveKeys[l]].rx, tx: prevCounters[liveKeys[l]].tx };
            }
            usageData.lastCounters = mergedCounters;
            pruneOldDays();

            pluginService.savePluginState(pluginId, "days", usageData.days);
            pluginService.savePluginState(pluginId, "lastCounters", usageData.lastCounters);
            // Tombstone the pre-1.5 keys so a later load can never re-run the
            // legacy migration against stale counters
            pluginService.savePluginState(pluginId, "lastRxBytes", -1);
            pluginService.savePluginState(pluginId, "lastTxBytes", -1);
            pluginService.savePluginState(pluginId, "lastInterface", "");

            // Only clear once the state was handed to DMS — clearing earlier would
            // silently drop the accumulated bytes if anything above throws
            root.unsavedBytes = 0;
        } catch (e) {
            console.warn("NetworkIndicator: failed to save usage data:", e);
        }
    }

    // ── Prune entries older than 30 days ──
    function pruneOldDays() {
        var cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - historyRetentionDays);
        var cutoffStr = Qt.formatDate(cutoff, "yyyy-MM-dd");

        var keys = Object.keys(usageData.days);
        for (var i = 0; i < keys.length; i++) {
            if (keys[i] < cutoffStr) {
                delete usageData.days[keys[i]];
            }
        }
    }

    // ── Interface eligibility (poll-time selection) ──
    // Primary interfaces feed the bar total, todayRx/todayTx, and the network
    // buckets. Virtual and tunnel interfaces are excluded because their bytes
    // also traverse an underlay NIC — counting both would double-book traffic
    // (wg0 over eth0, veth → bridge → physical).
    function isPrimaryIface(name) {
        if (_upIfaces[name] === false) return false;
        // Explicit entries are honored even if virtual or loopback on purpose
        if (_trackedIfaceNames.length > 0) return _trackedIfaceNames.indexOf(name) !== -1;
        if (name === "lo") return false;
        if (name.startsWith("docker") || name.startsWith("br-") ||
            name.startsWith("veth") || name.startsWith("virbr")) return false;
        if (name.startsWith("wg") || name.startsWith("tun") || name.startsWith("tap")) return false;
        return true;
    }

    // Group-pattern matches additionally track non-primary interfaces (VPN
    // tunnels, docker bridges, …) for the per-group views only — never into
    // the overall totals. An explicit Tracked Interfaces allowlist wins:
    // groups then only organize what the allowlist already tracks.
    function isGroupExtraIface(name) {
        if (_upIfaces[name] === false) return false;
        if (_trackedIfaceNames.length > 0) return false;
        return _compiledGroups.length > 0 && groupForIface(name) !== "Other";
    }

    // ── Get all known networks (SSIDs / iface names) in history + today ──
    function getAvailableNetworks() {
        var nets = {};
        var days = (usageData && usageData.days) ? usageData.days : {};
        var keys = Object.keys(days);
        for (var i = 0; i < keys.length; i++) {
            var n = days[keys[i]].networks;
            if (!n) continue;
            var nKeys = Object.keys(n);
            for (var j = 0; j < nKeys.length; j++) {
                nets[nKeys[j]] = true;
            }
        }
        // Today's live buckets may hold a network not yet flushed to days
        var tKeys = Object.keys(todayNetworks || {});
        for (var k = 0; k < tKeys.length; k++) {
            nets[tKeys[k]] = true;
        }
        return Object.keys(nets);
    }

    // ── Per-filter rx/tx of one day entry ({rx, tx, networks, interfaces}) ──
    function filteredDayValues(day) {
        if (selectedFilterType === "network") {
            var n = day.networks && day.networks[selectedFilterName];
            return { rx: (n && n.rx) || 0, tx: (n && n.tx) || 0 };
        }
        if (selectedFilterType === "group") {
            var r = 0;
            var t = 0;
            var ifs = day.interfaces || {};
            var keys = Object.keys(ifs);
            for (var i = 0; i < keys.length; i++) {
                if (groupForIface(keys[i]) === selectedFilterName) {
                    r += ifs[keys[i]].rx || 0;
                    t += ifs[keys[i]].tx || 0;
                }
            }
            return { rx: r, tx: t };
        }
        return { rx: day.rx || 0, tx: day.tx || 0 };
    }

    // ── Get sorted history entries (newest first) ──
    function getHistoryEntries() {
        if (!usageData || !usageData.days) return [];
        var entries = [];
        var keys = Object.keys(usageData.days);
        // usageData.days[todayKey] only refreshes on save (every 7 min), so
        // overlay the live counters for today. Reading todayRx/todayTx here
        // also makes bindings through this function re-evaluate every poll.
        if (todayKey && keys.indexOf(todayKey) === -1) {
            keys.push(todayKey);
        }
        keys.sort().reverse();
        for (var i = 0; i < keys.length; i++) {
            var day = keys[i] === todayKey
                ? { rx: todayRx, tx: todayTx, networks: todayNetworks, interfaces: todayInterfaces }
                : usageData.days[keys[i]];
            var v = filteredDayValues(day);
            if (v.rx === 0 && v.tx === 0 && selectedFilterType !== "all") continue;

            entries.push({
                date: keys[i],
                label: formatDateLabel(keys[i]),
                total: v.rx + v.tx,
                rx: v.rx,
                tx: v.tx
            });
        }
        return entries;
    }

    // ── Get max daily usage (for bar proportions) ──
    function getMaxDailyUsage() {
        var entries = getHistoryEntries();
        var max = 0;
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].total > max) max = entries[i].total;
        }
        return max > 0 ? max : 1;
    }

    // ── Get overall usage across all stored days (up to 30) ──
    function getOverallUsage() {
        var entries = getHistoryEntries();
        var sum = 0;
        for (var i = 0; i < entries.length; i++) {
            sum += entries[i].total;
        }
        return { total: sum, dayCount: entries.length };
    }

    // ── Stable ListModel caches (avoid Repeater model rebuild on poll) ──
    ListModel { id: networksModel }
    ListModel { id: historyModel }
    ListModel { id: groupsModel }

    function refreshNetworksModel() {
        networksModel.clear();
        networksModel.append({ "name": "All", "type": "all" });
        var hasExplicitOther = false;
        for (var g = 0; g < root._compiledGroups.length; g++) {
            networksModel.append({ "name": root._compiledGroups[g].name, "type": "group" });
            if (root._compiledGroups[g].name === "Other") hasExplicitOther = true;
        }
        if (root._compiledGroups.length > 0 && !hasExplicitOther) {
            networksModel.append({ "name": "Other", "type": "group" });
        }
        var nets = root.getAvailableNetworks();
        for (var i = 0; i < nets.length; i++) {
            networksModel.append({ "name": nets[i], "type": "network" });
        }
    }

    // ── Today's bytes for one group (from the per-interface buckets) ──
    function groupBytesToday(groupName) {
        var sum = 0;
        var ifs = todayInterfaces || {};
        var keys = Object.keys(ifs);
        for (var i = 0; i < keys.length; i++) {
            if (groupForIface(keys[i]) === groupName) {
                sum += (ifs[keys[i]].rx || 0) + (ifs[keys[i]].tx || 0);
            }
        }
        return sum;
    }

    // Rebuild only when the row set changes; otherwise update values in place
    // so open-popout polls don't churn delegates
    function syncGroupsModel() {
        var desired = [];
        var hasExplicitOther = false;
        for (var g = 0; g < _compiledGroups.length; g++) {
            desired.push({ "name": _compiledGroups[g].name, "bytes": groupBytesToday(_compiledGroups[g].name) });
            if (_compiledGroups[g].name === "Other") hasExplicitOther = true;
        }
        if (_compiledGroups.length > 0 && !hasExplicitOther) {
            var otherBytes = groupBytesToday("Other");
            if (otherBytes > 0) desired.push({ "name": "Other", "bytes": otherBytes });
        }

        var sameShape = groupsModel.count === desired.length;
        if (sameShape) {
            for (var i = 0; i < desired.length; i++) {
                if (groupsModel.get(i).name !== desired[i].name) {
                    sameShape = false;
                    break;
                }
            }
        }
        if (sameShape) {
            for (var j = 0; j < desired.length; j++) {
                if (groupsModel.get(j).bytes !== desired[j].bytes) {
                    groupsModel.setProperty(j, "bytes", desired[j].bytes);
                }
            }
        } else {
            groupsModel.clear();
            for (var k = 0; k < desired.length; k++) {
                groupsModel.append(desired[k]);
            }
            root.updatePopoutHeight();
        }
    }

    function refreshHistoryModel() {
        var entries = root.getHistoryEntries();
        historyModel.clear();
        for (var i = 0; i < entries.length; i++) {
            historyModel.append(entries[i]);
        }
    }

    // ── Height contributed by the group rows + per-app sticky sections ──
    function stickyExtrasHeight() {
        var h = 0;
        if (root.interfaceFound && groupsModel.count > 0) {
            // rows + inner spacing + the stickyTop column spacing above the section
            h += groupsModel.count * root.groupRowHeight
                 + (groupsModel.count - 1) * Theme.spacingXS + Theme.spacingM;
        }
        if (root.perAppTraffic) {
            h += root._perAppSectionH + Theme.spacingM;
        }
        return h;
    }

    // ── Update Popout Height dynamically ──
    function updatePopoutHeight() {
        if (!root.historyExpanded) {
            root.popoutHeight = (root.interfaceFound ? root.collapsedPopoutHeight : root.offlinePopoutHeight)
                                + root.stickyExtrasHeight();
        } else {
            root._maxDailyUsage = root.getMaxDailyUsage();
            
            // We use fixed component heights here to avoid a QML layout race condition.
            // If we read 'historyLabel.height' in the same frame that the popout expands,
            // it evaluates to 0, causing the ListView's height to become negative and disappear.
            // nonListH = historyLabel(18) + spacingS(8) + filters(32) + spacingM(12) + spacingXS(4) + totalSection(44)
            var nonListH = 118;
                           
            var entriesCount = historyModel.count;
            var listContentH = entriesCount > 0 ? (entriesCount * 36 + (entriesCount - 1) * Theme.spacingXS) : 0;
            
            // The extra 8px of padding is added here via `+ Theme.spacingS`
            // (Theme.spacingS evaluates to exactly 8px in DankMaterialShell)
            var historyH = nonListH + listContentH + Theme.spacingS;
            
            // collapsedPopoutHeight + historySection.topMargin (12).
            // Without the 12px offset, historySection is 12px shorter than historyH,
            // causing the DankListView to clip its bottom entry and show a scrollbar!
            // The history list itself scrolls, so the cap only squeezes the list.
            root.popoutHeight = Math.min(
                root.collapsedPopoutHeight + root.stickyExtrasHeight() + 12 + historyH,
                root.maxPopoutHeight);
        }
    }

    // ── Timer to poll network stats ──
    Timer {
        id: pollTimer
        interval: root.updateInterval * 1000
        running: root.dataLoaded
        repeat: true
        onTriggered: {
            // Check for midnight rollover or time jumps (e.g. NTP sync after boot)
            var currentKey = root.getCurrentDateKey();
            if (currentKey !== root.todayKey) {
                // Save the old day, switch to the new day
                root.saveUsageData();
                root.todayKey = currentKey;
                
                // Restore existing data for the new day if it exists, instead of resetting to 0
                if (root.usageData.days[currentKey]) {
                    root.todayRx = root.usageData.days[currentKey].rx || 0;
                    root.todayTx = root.usageData.days[currentKey].tx || 0;
                    root.todayNetworks = JSON.parse(JSON.stringify(root.usageData.days[currentKey].networks || {}));
                    root.todayInterfaces = JSON.parse(JSON.stringify(root.usageData.days[currentKey].interfaces || {}));
                } else {
                    root.todayRx = 0;
                    root.todayTx = 0;
                    root.todayNetworks = {};
                    root.todayInterfaces = {};
                }
            }

            root._cycleCounters = {};
            root._upIfaces = {};
            root._ssidByIface = {};
            netProcess.running = true;
        }
    }

    // ── Timer to periodically save to disk (every 7 mins) ──
    Timer {
        id: saveTimer
        interval: root.saveIntervalMs
        running: root.dataLoaded
        repeat: true
        onTriggered: {
            if (root.unsavedBytes > 0) {
                root.saveUsageData();
            }
        }
    }

    // ── Process: reads /proc/net/dev + operstate ──
    Process {
        id: netProcess
        command: [
            "sh", "-c",
            // OPSTATE/SSID lines must be emitted BEFORE /proc/net/dev so the
            // parser can skip down interfaces when picking one (see stdout below)
            "for f in /sys/class/net/*/operstate; do " +
            "  iface=$(basename $(dirname $f)); " +
            "  echo \"OPSTATE:${iface}:$(cat $f 2>/dev/null)\"; " +
            "  if [ -d /sys/class/net/${iface}/wireless ]; then " +
            "    ssid=$(iwgetid -r ${iface} 2>/dev/null); " +
            "    if [ -z \"$ssid\" ] && command -v nmcli >/dev/null 2>&1; then " +
            "      ssid=$(nmcli -t -c no -f device,active,ssid dev wifi 2>/dev/null | grep \"^${iface}:yes:\" | cut -d: -f3-); " +
            "    fi; " +
            "    echo \"SSID:${iface}:${ssid}\"; " +
            "  fi; " +
            "done; " +
            "cat /proc/net/dev"
        ]
        stdout: SplitParser {
            onRead: line => {
                // SSID/OPSTATE lines arrive before the /proc/net/dev output;
                // collect them into per-cycle lookup maps used in onExited
                if (line.startsWith("SSID:")) {
                    var sparts = line.split(":");
                    // slice(2) handles SSIDs containing colons; keep "" so the
                    // display falls back to the interface name (see onExited)
                    root._ssidByIface[sparts[1]] = sparts.slice(2).join(":").trim();
                    return;
                }

                if (line.startsWith("OPSTATE:")) {
                    var oparts = line.split(":");
                    // Only "down" disqualifies — some drivers report "unknown"
                    // while passing traffic
                    root._upIfaces[oparts[1]] = (oparts[2] !== "down");
                    return;
                }

                // /proc/net/dev rows look like: "  eth0: 12345 ... 67890 ..."
                var trimmed = line.trim();
                var colon = trimmed.indexOf(":");
                if (colon <= 0) return;

                var ifaceName = trimmed.substring(0, colon).trim();
                var stats = trimmed.substring(colon + 1).trim().split(/\s+/);
                // columns: rx_bytes rx_packets ... (8 rx fields) tx_bytes tx_packets ...
                var rxBytes = parseFloat(stats[0]);
                var txBytes = parseFloat(stats[8]);
                if (!ifaceName || !isFinite(rxBytes) || !isFinite(txBytes)) return;

                // Just collect raw counters for every interface; eligibility,
                // deltas, and attribution happen in onExited once operstates
                // and SSIDs are all known
                root._cycleCounters[ifaceName] = { rx: rxBytes, tx: txBytes };
            }
        }
        stderr: SplitParser {
            onRead: line => console.warn("NetworkIndicator: poll stderr:", line)
        }
        onExited: exitCode => {
            // Warn once per failure streak — this fires every updateInterval
            if (exitCode !== 0 && !root._lastPollFailed) {
                console.warn("NetworkIndicator: poll script exited with code", exitCode);
            }
            root._lastPollFailed = (exitCode !== 0);

            var all = Object.keys(root._cycleCounters);

            // Speed must divide by the real time between counter reads: after
            // a failed/empty cycle the next delta spans 2+ intervals and would
            // otherwise display as a bogus spike
            var now = Date.now();
            var elapsedSec = root._lastPollMs > 0
                ? Math.max(0.5, (now - root._lastPollMs) / 1000)
                : root.updateInterval;
            if (all.length > 0) root._lastPollMs = now;

            var speedRx = 0;    // primary deltas only (drives the bar)
            var speedTx = 0;
            var bookedRx = 0;   // primary bytes booked to the overall totals
            var bookedTx = 0;
            var bookedUnsaved = 0; // all booked bytes incl. group extras (flush accounting)
            var bookedAny = false;
            var anyPrimary = false;
            // Deep copies: reassigning the dicts once per cycle is what makes
            // QML bindings on them re-evaluate
            var newNetworks = JSON.parse(JSON.stringify(root.todayNetworks));
            var newInterfaces = JSON.parse(JSON.stringify(root.todayInterfaces));

            // Baselines advance for EVERY interface seen — including currently
            // ineligible ones — so a later eligibility change (settings edit,
            // group added) books one interval's worth, not the whole interim
            for (var i = 0; i < all.length; i++) {
                var iface = all[i];
                var cur = root._cycleCounters[iface];
                var primary = root.isPrimaryIface(iface);
                var tracked = primary || root.isGroupExtraIface(iface);
                if (primary) anyPrimary = true;

                var deltaRx = 0;
                var deltaTx = 0;
                var isGap = false;
                var prev = root.prevCounters[iface];
                if (!prev) {
                    // First sighting since load: consume the saved baseline to
                    // recover bytes that accumulated while the plugin was off.
                    // A negative gap means the counters reset (reboot) — start
                    // fresh instead of booking garbage.
                    var saved = (root.usageData.lastCounters || {})[iface];
                    if (saved) {
                        delete root.usageData.lastCounters[iface];
                        if (tracked) {
                            var gapRx = cur.rx - saved.rx;
                            var gapTx = cur.tx - saved.tx;
                            if (gapRx >= 0 && gapTx >= 0) {
                                deltaRx = gapRx;
                                deltaTx = gapTx;
                                isGap = true; // usage, but not current speed
                            }
                        }
                    }
                } else if (tracked) {
                    var dRx = cur.rx - prev.rx;
                    var dTx = cur.tx - prev.tx;
                    // Negative delta = counter reset (e.g. USB NIC replug)
                    // → drop this interface's sample, keep the others
                    if (dRx >= 0 && dTx >= 0) {
                        deltaRx = dRx;
                        deltaTx = dTx;
                    }
                }
                root.prevCounters[iface] = { rx: cur.rx, tx: cur.tx };

                if (deltaRx > 0 || deltaTx > 0) {
                    bookedAny = true;
                    bookedUnsaved += deltaRx + deltaTx;
                    var ifc = newInterfaces[iface] || { rx: 0, tx: 0 };
                    ifc.rx += deltaRx;
                    ifc.tx += deltaTx;
                    newInterfaces[iface] = ifc;

                    if (primary) {
                        // Only primaries feed the totals; group-tracked extras
                        // (tunnels, bridges) would double-count the same bytes
                        bookedRx += deltaRx;
                        bookedTx += deltaTx;
                        if (!isGap) {
                            speedRx += deltaRx;
                            speedTx += deltaTx;
                        }
                        var netName = root._ssidByIface[iface] || iface;
                        var net = newNetworks[netName] || { rx: 0, tx: 0 };
                        net.rx += deltaRx;
                        net.tx += deltaTx;
                        newNetworks[netName] = net;
                    }
                }
            }

            // Update interfaceFound ONLY after the full read completes (no flicker)
            root.interfaceFound = anyPrimary;

            root.downloadSpeed = anyPrimary ? speedRx / elapsedSec : 0;
            root.uploadSpeed = anyPrimary ? speedTx / elapsedSec : 0;

            if (bookedAny) {
                root.todayRx += bookedRx;
                root.todayTx += bookedTx;
                root.todayNetworks = newNetworks;
                root.todayInterfaces = newInterfaces;

                // Keep the expanded history live: patch today's row in place,
                // or rebuild once when today newly qualifies under the active
                // filter (was zero / date rolled over at midnight)
                if (root.historyExpanded) {
                    var v = root.filteredDayValues({
                        rx: root.todayRx, tx: root.todayTx,
                        networks: root.todayNetworks, interfaces: root.todayInterfaces
                    });
                    if (historyModel.count > 0 && historyModel.get(0).date === root.todayKey) {
                        historyModel.setProperty(0, "rx", v.rx);
                        historyModel.setProperty(0, "tx", v.tx);
                        historyModel.setProperty(0, "total", v.rx + v.tx);
                    } else if (v.rx + v.tx > 0) {
                        root.refreshHistoryModel();
                        root.updatePopoutHeight();
                    }
                }

                root.unsavedBytes += bookedUnsaved;
            }

            root.syncGroupsModel();

            if (root.unsavedBytes >= root.flushThresholdBytes) {
                root.saveUsageData();
            }
        }
    }

    // ── Delayed init: gives DMS time to inject pluginService ──
    Timer {
        id: initTimer
        interval: 500
        repeat: true
        onTriggered: {
            if (root.pluginService && !root.dataLoaded) {
                root.loadUsageData();
                if (root.dataLoaded) {
                    netProcess.running = true;
                    initTimer.running = false;
                }
                return;
            }
        }
    }

    // ── Load persisted data and start polling ──
    Component.onCompleted: {
        if (pluginService) {
            loadUsageData();
            if (dataLoaded) {
                netProcess.running = true;
            }
        } else {
            // pluginService not injected yet — retry after a short delay
            initTimer.running = true;
        }
    }

    // ── Save on destruction ──
    Component.onDestruction: {
        saveUsageData();
    }

    // ── Horizontal Bar Pill (for horizontal DankBar) ──
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS
            visible: true

            // ── Offline state: differentiate wifi_off vs disconnected ──
            DankIcon {
                visible: !root.interfaceFound
                name: "speed"
                size: root.iconSize + 3
                weight: 700
                color: Theme.error
                anchors.verticalCenter: parent.verticalCenter
            }

            // Combined mode: single total speed
            Row {
                visible: root.interfaceFound && root.displayMode === "combined"
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "import_export"
                    size: root.iconSize
                    color: root.totalSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                StyledText {
                    text: root.formatSpeed(root.totalSpeed)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Separate mode: download ↓
            Row {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "arrow_downward"
                    size: root.iconSize
                    color: root.downloadSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.downloadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Separate mode: upload ↑
            Row {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "arrow_upward"
                    size: root.iconSize
                    color: root.uploadSpeed > 0 ? Theme.error : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.uploadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // ── Vertical Bar Pill (for vertical DankBar) ──
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingS
            visible: true

            // ── Offline state: differentiate wifi_off vs disconnected ──
            DankIcon {
                visible: !root.interfaceFound
                name: "speed"
                size: root.iconSize + 2
                color: Theme.error
                anchors.horizontalCenter: parent.horizontalCenter
                weight: 700
                filled: true

            }

            // Combined mode: single total speed
            Column {
                visible: root.interfaceFound && root.displayMode === "combined"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "import_export"
                    size: root.iconSize
                    color: root.totalSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700

                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                StyledText {
                    text: root.formatSpeed(root.totalSpeed)
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            // Separate mode: download ↓
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "arrow_downward"
                    size: root.iconSize
                    color: root.downloadSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.downloadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            // Separate mode: upload ↑
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "arrow_upward"
                    size: root.iconSize
                    color: root.uploadSpeed > 0 ? Theme.error : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.uploadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // ── Popout with detailed network stats ──
    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn
            showCloseButton: false
            onVisibleChanged: {
                if (visible) {
                    root.historyExpanded = false;
                    root.syncGroupsModel();
                    root.updatePopoutHeight();
                } else {
                    root.selectedFilterType = "all";
                    root.selectedFilterName = "All";
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - Theme.spacingXL

                // ── Sticky top section (does not scroll) ──
                Column {
                    id: stickyTop
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingM

                        // ── Custom Centered Header ──
                        Column {
                            width: parent.width
                            spacing: 2

                            StyledText {
                                text: "Network Monitor"
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                horizontalAlignment: Text.AlignHCenter
                                width: parent.width
                            }

                            StyledText {
                                visible: !root.interfaceFound
                                text: root.offlineReason === "wifi_off" ? "WiFi is turned off" : "Not connected to any network"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                horizontalAlignment: Text.AlignHCenter
                                width: parent.width
                            }
                        }

                        // ── Offline banner (clickable → opens DMS Network Settings) ──
                        StyledRect {
                            visible: !root.interfaceFound
                            width: parent.width
                            height: offlineBannerCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: offlineBannerMouse.containsMouse
                                ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.12)
                                : Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.06)

                            Behavior on color {
                                ColorAnimation { duration: 150; easing.type: Easing.OutCubic }
                            }

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: root.offlineReason === "wifi_off" ? "wifi_off" : "signal_wifi_off"
                                    size: 28
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    id: offlineBannerCol
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 28 - chevronIcon.width - Theme.spacingS * 2
                                    spacing: 2

                                    StyledText {
                                        text: root.offlineReason === "wifi_off"
                                            ? "WiFi is turned off"
                                            : "No network connection"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.surfaceText
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        text: root.offlineReason === "wifi_off"
                                            ? "Click to enable WiFi"
                                            : "Click to browse available networks"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }
                                }

                                DankIcon {
                                    id: chevronIcon
                                    name: "chevron_right"
                                    size: 20
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                hoverEnabled: true
                                id: offlineBannerMouse
                                onClicked: {
                                    root.closePopout();
                                    PopoutService.openSettingsWithTab("network");
                                }
                            }
                        }

                        // ── Download + Upload side by side ──
                        Row {
                            visible: root.interfaceFound
                            width: parent.width
                            spacing: Theme.spacingS

                            // Download card
                            StyledRect {
                                width: (parent.width - Theme.spacingS) / 2
                                height: 70
                                radius: Theme.cornerRadius
                                color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2)

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        name: "download"
                                        size: 24
                                        color: Theme.primary
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    StyledText {
                                        text: root.formatSpeed(root.downloadSpeed)
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.primary
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }

                            // Upload card
                            StyledRect {
                                width: (parent.width - Theme.spacingS) / 2
                                height: 70
                                radius: Theme.cornerRadius
                                color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.2)

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        name: "upload"
                                        size: 24
                                        color: Theme.error
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    StyledText {
                                        text: root.formatSpeed(root.uploadSpeed)
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.error
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }
                        }

                    // ── Data Used Today (clickable to expand history) ──
                    StyledRect {
                        id: dataUsedCard
                        width: parent.width
                        height: 70
                        radius: Theme.cornerRadius
                        color: Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                name: "data_usage"
                                size: 24
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                width: parent.width - 24 - Theme.spacingM - expandIcon.width - Theme.spacingM

                                StyledText {
                                    text: "Data Used Today"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                StyledText {
                                    text: root.formatBytes(root.todayRx + root.todayTx)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Bold
                                    color: Theme.surfaceVariantText
                                }
                            }

                            DankIcon {
                                id: expandIcon
                                name: "expand_more"
                                size: 20
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                                rotation: root.historyExpanded ? 180 : 0

                                Behavior on rotation {
                                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.historyExpanded = !root.historyExpanded;
                                root.selectedFilterType = "all";
                                root.selectedFilterName = "All";
                                if (root.historyExpanded) {
                                    root.refreshNetworksModel();
                                    root.refreshHistoryModel();
                                    filtersFlickable.contentX = 0;
                                    historyListView.positionViewAtBeginning();
                                }
                                root.updatePopoutHeight();
                            }
                        }
                    }

                    // ── Per-group usage today (only when groups are defined) ──
                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: root.interfaceFound && groupsModel.count > 0

                        Repeater {
                            model: groupsModel

                            StyledRect {
                                id: groupRow
                                required property string name
                                required property real bytes

                                width: parent.width
                                height: root.groupRowHeight
                                radius: Theme.cornerRadius / 2
                                color: Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.1)

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.rightMargin: Theme.spacingS
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: groupRow.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        width: parent.width - groupBytesLabel.width - Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        id: groupBytesLabel
                                        text: root.formatBytes(groupRow.bytes)
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Bold
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                            }
                        }
                    }

                    // ── Live per-app traffic (optional, needs nethogs) ──
                    PerAppSection {
                        width: parent.width
                        visible: root.perAppTraffic
                        active: popoutColumn.visible && root.perAppTraffic
                        formatSpeedFn: root.formatSpeed
                        onSectionHeightChanged: {
                            root._perAppSectionH = sectionHeight;
                            root.updatePopoutHeight();
                        }
                        Component.onCompleted: root._perAppSectionH = sectionHeight
                    }
                } // end stickyTop Column

                // ── 30-Day History Section (anchored below sticky top) ──
                Item {
                    id: historySection
                    anchors.top: stickyTop.bottom
                    anchors.topMargin: root.historyExpanded ? Theme.spacingM : 0
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: 0
                    visible: root.historyExpanded
                    opacity: root.historyExpanded ? 1.0 : 0.0
                    clip: true

                    Behavior on opacity {
                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                    }

                    // "Last 30 Days" header (sticky at top)
                    StyledText {
                        id: historyLabel
                        anchors.top: parent.top
                        width: parent.width - Theme.spacingM
                        text: "Last 30 Days"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceVariantText
                        bottomPadding: Theme.spacingXS
                    }

                    // ── Network Filter Chips ──
                    Flickable {
                        id: filtersFlickable
                        anchors.top: historyLabel.bottom
                        anchors.topMargin: Theme.spacingS
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 32
                        contentWidth: filtersRow.implicitWidth
                        boundsBehavior: Flickable.StopAtBounds
                        clip: true

                        Row {
                            id: filtersRow
                            spacing: Theme.spacingS

                            Repeater {
                                model: networksModel

                                StyledRect {
                                    id: filterChip
                                    required property string name
                                    required property string type
                                    // Group and SSID chips may share a label; the
                                    // type keeps the selection unambiguous
                                    readonly property bool selected: root.selectedFilterType === filterChip.type
                                                                     && root.selectedFilterName === filterChip.name
                                    height: 32
                                    width: filterText.implicitWidth + Theme.spacingM * 2
                                    radius: 16
                                    color: filterChip.selected
                                        ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2)
                                        : Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.1)
                                    border.width: filterChip.selected ? 1 : 0
                                    border.color: Theme.primary

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    StyledText {
                                        id: filterText
                                        anchors.centerIn: parent
                                        text: filterChip.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: filterChip.selected ? Font.Bold : Font.Normal
                                        color: filterChip.selected ? Theme.primary : Theme.surfaceVariantText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.selectedFilterType = filterChip.type;
                                            root.selectedFilterName = filterChip.name;
                                            root.refreshHistoryModel();
                                            root.updatePopoutHeight();
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Scrollable daily entries (using DankListView for smooth scrolling)
                    DankListView {
                        id: historyListView
                        anchors.top: filtersFlickable.bottom
                        anchors.topMargin: Theme.spacingM
                        anchors.bottom: totalSection.top
                        anchors.bottomMargin: Theme.spacingXS
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.rightMargin: 2
                        clip: true
                        spacing: Theme.spacingXS
                        
                        model: historyModel
                        
                        ScrollBar.vertical: ScrollBar {
                            id: historyScrollBar
                            policy: ScrollBar.AsNeeded
                            implicitWidth: 10
                            background: Item {}
                            contentItem: Rectangle {
                                implicitWidth: 8
                                radius: 25
                                color: Qt.rgba(
                                    Theme.surfaceVariantText.r,
                                    Theme.surfaceVariantText.g,
                                    Theme.surfaceVariantText.b,
                                    historyScrollBar.active ? 0.5 : 0.3
                                )

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }

                        delegate: StyledRect {
                            id: historyRow
                            required property string date
                            required property string label
                            required property real total
                            required property real rx
                            required property real tx
                            required property int index
                            
                            width: historyListView.width - 13
                            height: 36
                            radius: Theme.cornerRadius / 2
                            color: historyRow.date === root.todayKey
                                ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.08)
                                : Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.1)

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS
                                spacing: Theme.spacingS

                                // Date label
                                StyledText {
                                    id: dateLabel
                                    text: historyRow.date === root.todayKey ? "Today" : historyRow.label
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: historyRow.date === root.todayKey ? Font.Bold : Font.Normal
                                    color: historyRow.date === root.todayKey ? Theme.primary : Theme.surfaceVariantText
                                    width: Math.max(50, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                // Usage bar
                                Item {
                                    width: Math.max(0, parent.width - dateLabel.width - totalLabel.width - Theme.spacingS * 3)
                                    height: 8
                                    clip: true
                                    anchors.verticalCenter: parent.verticalCenter

                                    StyledRect {
                                        width: parent.width
                                        height: parent.height
                                        radius: 4
                                        color: Qt.rgba(Theme.surfaceVariantText.r,
                                                       Theme.surfaceVariantText.g,
                                                       Theme.surfaceVariantText.b, 0.1)
                                    }

                                    StyledRect {
                                        width: Math.max(2, parent.width * (historyRow.total / root._maxDailyUsage))
                                        height: parent.height
                                        radius: 4
                                        color: historyRow.date === root.todayKey ? Theme.primary : Theme.surfaceVariantText

                                        Behavior on width {
                                            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                        }
                                    }
                                }

                                // Total data label
                                StyledText {
                                    id: totalLabel
                                    text: root.formatBytes(historyRow.total)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: historyRow.date === root.todayKey ? Theme.primary : Theme.surfaceText
                                    horizontalAlignment: Text.AlignRight
                                    width: Math.max(65, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    // ── Sticky Total row (pinned at bottom) ──
                    Item {
                        id: totalSection
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: totalRow.height + Theme.spacingS
                        opacity: 0
                        transform: Translate { id: totalRowTranslate; y: 8 }

                        Component.onCompleted: {
                            totalRowEntranceAnim.start();
                        }

                        SequentialAnimation {
                            id: totalRowEntranceAnim
                            PauseAnimation { duration: root.getHistoryEntries().length * 25 }
                            ParallelAnimation {
                                NumberAnimation {
                                    target: totalSection
                                    property: "opacity"
                                    from: 0; to: 1
                                    duration: 120
                                    easing.type: Easing.OutCubic
                                }
                                NumberAnimation {
                                    target: totalRowTranslate
                                    property: "y"
                                    from: 8; to: 0
                                    duration: 120
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }

                        StyledRect {
                            id: totalRow
                            y: Theme.spacingS
                            width: parent.width
                            height: 36
                            radius: Theme.cornerRadius / 2
                            color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.08)

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS

                                StyledText {
                                    text: "Total"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    width: Math.max(50, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Item {
                                    width: parent.width - 50 - Math.max(65, overallLabel.implicitWidth) - Theme.spacingS
                                    height: 1
                                }

                                StyledText {
                                    id: overallLabel
                                    text: root.formatBytes(root.getOverallUsage().total)
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    horizontalAlignment: Text.AlignRight
                                    width: Math.max(65, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                } // end historySection
            }
        }
    }

    popoutWidth: 325
    popoutHeight: collapsedPopoutHeight

    Behavior on popoutHeight {
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
}