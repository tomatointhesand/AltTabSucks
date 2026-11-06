// kwin-window-watch.js - loaded by the startup manager (startup_manager.py) into KWin for as long
// as it runs, as the KWin script "alttabsucks-startup-watch". A Wayland client can't see other
// apps' windows; KWin can. This reports every normal window that exists or appears (pid, class)
// back to the manager over D-Bus, which is how it tells an app's first window appeared.
//
// For a startup run (PLACE_SELF true), it also does what lib/startup-manager.ahk's _SmPlace does
// on Windows: puts the manager's own window in the bottom-right corner, above other windows, and
// again a little later (at logon the panel appears after this window does), unless it was moved.
// The manager replaces PLACE_SELF when it writes this file out.

var PLACE_SELF = false;
var SELF_CLASS = "org.alttabsucks.startup";
var SERVICE = "org.alttabsucks.Startup";
var PATH = "/org/alttabsucks/Startup/Watch";
var IFACE = "org.alttabsucks.StartupWatch";

function isSelf(w) {
    return String(w.resourceClass || "").toLowerCase() === SELF_CLASS;
}

function report(w) {
    if (!w || !w.normalWindow || isSelf(w))
        return;
    callDBus(SERVICE, PATH, IFACE, "Window", w.pid || 0, String(w.resourceClass || ""), String(w.resourceName || ""));
}

function afterDelay(ms, fn) {
    var t = new QTimer();
    t.interval = ms;
    t.singleShot = true;
    t.timeout.connect(fn);
    t.start();
}

function place(w) {
    if (w.alttabsucksMoved)
        return;
    var area = workspace.clientArea(KWin.PlacementArea, w);
    var g = w.frameGeometry;
    var x = Math.max(area.x, area.x + area.width - g.width - 12);
    var y = Math.max(area.y, area.y + area.height - g.height - 12);
    w.frameGeometry = { x: x, y: y, width: Math.min(g.width, area.width), height: Math.min(g.height, area.height) };
}

function placeSelf(w) {
    if (!PLACE_SELF || !isSelf(w))
        return;
    w.keepAbove = true;
    w.interactiveMoveResizeFinished.connect(function () { w.alttabsucksMoved = true; });
    place(w);
    [700, 2000, 5000].forEach(function (ms) { afterDelay(ms, function () { place(w); }); });
}

var all = workspace.windowList();
for (var i = 0; i < all.length; i++) {
    report(all[i]);
    placeSelf(all[i]);
}
workspace.windowAdded.connect(function (w) {
    report(w);
    placeSelf(w);
});
