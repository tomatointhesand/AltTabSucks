#!/usr/bin/env python3
"""
hotkeys.js (the file installer.sh concatenates onto main.js — see main.js's own header comment for
why that concatenation happens at install time rather than a runtime #include) is the web UI's
(shared/hotkeys-ui.html) single source of truth. parse_hotkeys_js turns every registerShortcut(...)
statement it recognizes into the binding dicts the UI edits; rewrite_hotkeys_js puts the UI's edits
back by regenerating just those statements, leaving everything else in the file (comments, helper
functions, hand-written statements it doesn't recognize) as it was. Windows counterpart:
Server/AppHotkeys.ps1, same shape and rules.

Recognized: registerShortcut(title, text, key, function () { CALL; }) (or an arrow function), where
CALL is one of the actions below with plain string / array-of-strings arguments. A statement whose
every line starts with "// [disabled] " is a disabled binding. A recognized statement that fails
validation is reported as invalid (shown by the UI) and removed by the next save; a posted binding
that fails validation, or reuses an enabled binding's title or key, is left out and reported as
dropped. Self-healing either way: nothing invalid is ever written, and nothing invalid survives a
save.

Binding "type" maps to one main.js function each:
  windowCycle / windowToggle -> manageAppWindows(resourceClass, mode, launchArgv)
  profileCycle                -> cycleChromiumProfile(resourceClass, profileName, launchProfileName)
                                  — profileName may be ALL_PROFILES ("__all__"), meaning cycle
                                  every open window of this browser regardless of profile instead
                                  of one specific profile's own windows (main.js's
                                  cycleAnyChromiumProfile). launchProfileName is always a real,
                                  specific profile — what to launch fresh if nothing's open at
                                  all, since ALL_PROFILES alone doesn't say which one to start;
                                  defaults to profileName itself when profileName isn't
                                  ALL_PROFILES (see generate_binding_js below), so this stayed
                                  fully backward compatible for every binding saved before this
                                  parameter existed.
  tabFocus                    -> focusTab(resourceClass, profileName, urlPatterns, openUrl)
  runCommand                  -> runCommandWithToast(title, argv) — waits for argv[0] to finish
                                  (no shell) and shows a toast with its exit status and any
                                  output, rather than LaunchCommand's fire-and-forget spawn
                                  (right for the GUI apps manageAppWindows launches, wrong here:
                                  a runCommand binding's whole point is knowing whether a short
                                  CLI-style command actually worked). Generic "run this command on
                                  this key" binding, not tied to any window/tab/profile — this is
                                  what a "Reload Hotkeys" binding is made of (argv pointing at this
                                  clone's installer.sh), rather than that being a special case
                                  hardcoded into main.js/dbus_bridge.py.
  tabSearch                   -> showTabSearch(resourceClass) — the tab search popup (open tabs,
                                  then recently closed, then bookmarks; see tab_search.py).
  splitTab                    -> splitFocusedTab(resourceClass, profileName) — detaches the
                                  active tab of the focused window into its own new window, then
                                  places the two side by side. Port of lib/chromium.ahk's
                                  SplitFocusedTab; unlike AHK, profile isn't auto-detected from
                                  the active window's title, it's an explicit field here, same as
                                  every other browser-related binding type.
  mergeTabs                   -> mergeFocusedWindow(resourceClass, profileName) — moves every tab
                                  from the focused window into the profile's other window. Port
                                  of lib/chromium.ahk's MergeFocusedWindow, same profileName note
                                  as splitTab above.

resourceClass means two different things depending on "type", deliberately not treated the same
way. windowCycle/windowToggle target an arbitrary app (Kate, Discord, a game, ...) that genuinely
varies per binding, so it stays a field on the binding dict itself, exactly like every other field.
profileCycle/tabFocus/splitTab/mergeTabs are all inherently *about* the single browser this whole
install manages — every one of them also takes a profileName, a browser-profile concept no other
kind of app has — so their resourceClass comes from generate_hotkeys_js's/generate_binding_js's own
`browser_resource_class` parameter instead, sourced from config.py's CHROMIUM_RESOURCE_CLASS (set
once via `./installer.sh configure`). This used to be a per-binding field
for these four types too, meaning the same literal string ("brave-browser") had to be retyped or
reselected into every single browser-scoped binding, with no relationship between them enforced —
switching browsers meant hand-editing every one individually, and nothing caught two bindings
quietly disagreeing about which browser they meant. Moving it up to one value fixes both.
"""

import json
import re

HEADER = (
    "// AltTabSucks hotkeys. Edit them here or in the Hotkeys UI (Ctrl+Alt+/, served at\n"
    "// http://localhost:9876/hotkeys-ui): the UI shows the registerShortcut(...) statements below\n"
    "// that it recognizes and rewrites just those on Save; anything else here is left as written.\n"
)
# What every hotkeys.js started with while hotkeys.json was the source of truth; replaced by HEADER.
LEGACY_HEADER = (
    "// Generated by the AltTabSucks hotkeys UI (shared/hotkeys-ui.html) from hotkeys.json.\n"
    "// Hand edits here will be overwritten the next time you save in the UI — edit\n"
    "// hotkeys.json (or just use the UI) instead, unless you never use the UI at all.\n"
)
DISABLED_MARKER = "// [disabled] "

# A profileCycle binding's profileName sentinel meaning "cycle every open window of this browser,
# regardless of profile" — see the module docstring above. Must exactly match main.js's own
# ALL_PROFILES constant and shared/hotkeys-ui.html's own copy; the three aren't auto-synced (no
# shared module across Python/JS), so keep them in lockstep by hand if this ever changes.
ALL_PROFILES = "__all__"


def _js_string(value) -> str:
    """A JS string literal for value. json.dumps's escaping happens to be a valid JS string
    literal too (both escape quotes/backslashes/control chars the same way) — reused rather than
    hand-rolled to avoid getting that subtly wrong."""
    return json.dumps(str(value))


def _js_array_of_strings(values) -> str:
    return "[" + ", ".join(_js_string(v) for v in values) + "]"


# Raised for profileCycle/tabFocus/splitTab/mergeTabs when browser_resource_class is empty — these
# four no longer have a resourceClass field of their own to blame (see this module's own docstring
# for why), so the error has to point at the actual fix instead of a binding that can't have one.
_NO_BROWSER_CONFIGURED = "no browser configured — run ./installer.sh configure to set one"


def generate_binding_js(binding: dict, browser_resource_class: str = "") -> str:
    """Returns one registerShortcut(...) statement for a single binding dict. `browser_resource_class`
    is the single configured browser's resourceClass (config.py's CHROMIUM_RESOURCE_CLASS, read by
    the caller — see alttabsucks_server.py) — used for every type except windowCycle/windowToggle,
    which still take their own resourceClass from the binding dict since they target an arbitrary
    app, not necessarily the browser. Raises ValueError on a missing/invalid field — callers should
    validate before this is reached in a save flow (see alttabsucks_server.py's POST
    /hotkeys-config), but this stays strict rather than silently emitting broken JS."""
    kind = binding.get("type")
    title = (binding.get("title") or "").strip()
    key = (binding.get("key") or "").strip()
    # See this module's own docstring for why these two are treated differently.
    window_manage = kind in ("windowCycle", "windowToggle")
    resource_class = (binding.get("resourceClass") or "").strip() if window_manage \
        else (browser_resource_class or "").strip()

    if not title:
        raise ValueError(f"binding missing title: {binding!r}")
    if not key:
        raise ValueError(f"binding {title!r} missing key")

    header = (
        f"registerShortcut({_js_string(title)}, {_js_string('AltTabSucks: ' + title)},\n"
        f"    {_js_string(key)}, function () {{ "
    )

    if kind in ("windowCycle", "windowToggle"):
        if not resource_class:
            raise ValueError(f"binding {title!r} missing resourceClass")
        mode = "cycle" if kind == "windowCycle" else "toggle"
        launch_argv = binding.get("launchArgv") or []
        call = f"manageAppWindows({_js_string(resource_class)}, {_js_string(mode)}"
        if launch_argv:
            call += f", {_js_array_of_strings(launch_argv)}"
        call += ");"
    elif kind == "profileCycle":
        if not resource_class:
            raise ValueError(_NO_BROWSER_CONFIGURED)
        profile = (binding.get("profileName") or "").strip()
        if not profile:
            raise ValueError(f"binding {title!r} missing profileName")
        launch_profile = (binding.get("launchProfileName") or "").strip()
        if profile == ALL_PROFILES:
            # ALL_PROFILES alone doesn't say which profile to launch if nothing's open at all —
            # unlike the branch below, there's no sensible default to fall back to here.
            if not launch_profile:
                raise ValueError(
                    f"binding {title!r} cycles all profiles but has no launch profile set "
                    "(which one to open if nothing's running)"
                )
        elif not launch_profile:
            # Backward compatible default for every binding saved before launchProfileName
            # existed at all (or the UI simply never diverged it) — launching the same profile
            # you're cycling is the only sensible choice when there's a real, single profile.
            launch_profile = profile
        call = (
            f"cycleChromiumProfile({_js_string(resource_class)}, {_js_string(profile)}, "
            f"{_js_string(launch_profile)});"
        )
    elif kind == "tabFocus":
        if not resource_class:
            raise ValueError(_NO_BROWSER_CONFIGURED)
        profile = (binding.get("profileName") or "").strip()
        url_patterns = binding.get("urlPatterns") or []
        open_url = (binding.get("openUrl") or "").strip()
        if not profile:
            raise ValueError(f"binding {title!r} missing profileName")
        if not url_patterns:
            raise ValueError(f"binding {title!r} missing urlPatterns")
        if not open_url:
            raise ValueError(f"binding {title!r} missing openUrl")
        call = (
            f"focusTab({_js_string(resource_class)}, {_js_string(profile)}, "
            f"{_js_array_of_strings(url_patterns)}, {_js_string(open_url)});"
        )
    elif kind == "runCommand":
        argv = binding.get("argv") or []
        if not argv:
            raise ValueError(f"binding {title!r} missing argv")
        call = f'runCommandWithToast({_js_string(title)}, {_js_array_of_strings(argv)});'
    elif kind in ("splitTab", "mergeTabs"):
        if not resource_class:
            raise ValueError(_NO_BROWSER_CONFIGURED)
        profile = (binding.get("profileName") or "").strip()
        if not profile:
            raise ValueError(f"binding {title!r} missing profileName")
        fn = "splitFocusedTab" if kind == "splitTab" else "mergeFocusedWindow"
        call = f"{fn}({_js_string(resource_class)}, {_js_string(profile)});"
    elif kind == "tabSearch":
        if not resource_class:
            raise ValueError(_NO_BROWSER_CONFIGURED)
        call = f"showTabSearch({_js_string(resource_class)});"
    else:
        raise ValueError(f"binding {title!r} has unknown type: {kind!r}")

    return header + call + " });"


def _group(kind) -> str:
    """The UI section a type belongs to — reordering within a section is what rewrite honors."""
    return "app" if kind in ("windowCycle", "windowToggle") else str(kind)


def _key_identity(key: str) -> str:
    """"Ctrl+Shift+Alt+I" and "Ctrl+Alt+Shift+I" are the same shortcut to kglobalaccel."""
    parts = [p for p in re.split(r"\+(?=.)", key.strip()) if p]
    if not parts:
        return ""
    return "+".join(sorted(p.lower() for p in parts[:-1]) + [parts[-1].lower()])


# ---- parsing --------------------------------------------------------------------------------------

_TOKEN = re.compile(r"""
    (?P<ws>\s+|//[^\n]*|/\*.*?\*/)
  | (?P<str>"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')
  | (?P<arrow>=>)
  | (?P<punct>[()\[\]{},;])
  | (?P<ident>[A-Za-z_$][\w$]*)
  | (?P<other>.)
""", re.X | re.S)


def _tokens(src: str):
    out = []
    for m in _TOKEN.finditer(src):
        kind = m.lastgroup
        if kind == "ws":
            continue
        out.append((kind, m.group()))
    return out


def _js_string_value(literal: str) -> str:
    if literal.startswith("'"):
        body = literal[1:-1].replace('\\\'', "'").replace('"', '\\"')
        literal = '"' + body + '"'
    return json.loads(literal)


class _Unrecognized(Exception):
    pass


class _Parser:
    def __init__(self, toks):
        self.toks, self.i = toks, 0

    def peek(self, value=None):
        if self.i >= len(self.toks):
            return None if value is None else False
        tok = self.toks[self.i]
        return tok if value is None else tok[1] == value

    def take(self, value=None, kind=None):
        tok = self.peek()
        if tok is None or (value is not None and tok[1] != value) or (kind is not None and tok[0] != kind):
            raise _Unrecognized()
        self.i += 1
        return tok[1]

    def string(self):
        return _js_string_value(self.take(kind="str"))

    def literal(self):
        if self.peek("["):
            self.take("[")
            items = []
            while not self.peek("]"):
                items.append(self.string())
                if not self.peek("]"):
                    self.take(",")
            self.take("]")
            return items
        return self.string()

    def call(self):
        name = self.take(kind="ident")
        self.take("(")
        args = []
        while not self.peek(")"):
            args.append(self.literal())
            if not self.peek(")"):
                self.take(",")
        self.take(")")
        return name, args

    def body(self):
        """function () { CALL; } | () => CALL | () => { CALL; }"""
        if self.peek("function"):
            self.take("function")
            self.take("(")
            self.take(")")
            braced = True
        else:
            self.take("(")
            self.take(")")
            self.take("=>")
            braced = self.peek("{")
        if braced:
            self.take("{")
        call = self.call()
        if braced:
            if self.peek(";"):
                self.take(";")
            self.take("}")
        return call

    def statement(self):
        self.take("registerShortcut")
        self.take("(")
        title = self.string()
        self.take(",")
        self.string()  # the description, always "AltTabSucks: " + title when generated
        self.take(",")
        key = self.string()
        self.take(",")
        call = self.body()
        self.take(")")
        if self.peek(";"):
            self.take(";")
        if self.peek() is not None:
            raise _Unrecognized()
        return title, key, call


_ACTIONS = {
    # name: (min args, max args)
    "manageAppWindows": (2, 3), "cycleChromiumProfile": (2, 3), "focusTab": (4, 4),
    "runCommandWithToast": (2, 2), "splitFocusedTab": (2, 2), "mergeFocusedWindow": (2, 2),
    "showTabSearch": (1, 1),
}


def _binding_from_call(title, key, name, args):
    """The binding dict for a recognized action call, or None for any other function (left alone).
    Raises ValueError when it is one of ours but the arguments don't fit."""
    if name not in _ACTIONS:
        return None
    lo, hi = _ACTIONS[name]
    if not lo <= len(args) <= hi:
        raise ValueError(f"{name} takes {lo if lo == hi else f'{lo}-{hi}'} arguments, got {len(args)}")
    def s(i):
        v = args[i] if i < len(args) else ""
        if not isinstance(v, str):
            raise ValueError(f"{name} argument {i + 1} should be a string")
        return v
    def lst(i):
        v = args[i] if i < len(args) else []
        if not isinstance(v, list):
            raise ValueError(f"{name} argument {i + 1} should be a list")
        return v
    b = {"title": title, "key": key}
    if name == "manageAppWindows":
        mode = s(1)
        if mode not in ("cycle", "toggle"):
            raise ValueError(f"unknown manageAppWindows mode {mode!r}")
        b.update(type="windowCycle" if mode == "cycle" else "windowToggle", resourceClass=s(0), launchArgv=lst(2))
    elif name == "cycleChromiumProfile":
        b.update(type="profileCycle", resourceClass=s(0), profileName=s(1), launchProfileName=s(2))
    elif name == "focusTab":
        b.update(type="tabFocus", resourceClass=s(0), profileName=s(1), urlPatterns=lst(2), openUrl=s(3))
    elif name == "showTabSearch":
        b.update(type="tabSearch", resourceClass=s(0))
    elif name == "runCommandWithToast":
        b.update(type="runCommand", argv=lst(1))
    else:
        b.update(type="splitTab" if name == "splitFocusedTab" else "mergeTabs", resourceClass=s(0), profileName=s(1))
    return b


def _statement_extent(lines, start, strip):
    """End line (exclusive) of a registerShortcut statement beginning at lines[start], found by
    bracket depth (string-aware) — or None if it doesn't close within a few lines."""
    depth, seen = 0, False
    for end in range(start, min(start + 12, len(lines))):
        line = strip(lines[end])
        if line is None:
            return None
        for kind, tok in _tokens(line):
            if tok in "([{":
                depth, seen = depth + 1, True
            elif tok in ")]}":
                depth -= 1
        if seen and depth <= 0:
            return end + 1
    return None


def _strip_disabled(line):
    t = line.lstrip()
    return t[len(DISABLED_MARKER):] if t.startswith(DISABLED_MARKER) else None


def _file_model(text: str) -> dict:
    """Splits hotkeys.js into lines plus every registerShortcut statement in it: recognized
    bindings (with "slot", the statement's index), invalid ones, and the titles/keys of the rest
    (hand-written statements), for the duplicate checks."""
    lines = text.split("\n")
    stmts, custom = [], []  # stmts: {start, end, binding} or {start, end, invalid}
    i = 0
    while i < len(lines):
        t = lines[i].lstrip()
        disabled = t.startswith(DISABLED_MARKER + "registerShortcut(")
        if not (disabled or t.startswith("registerShortcut(")):
            i += 1
            continue
        strip = _strip_disabled if disabled else (lambda l: l)
        end = _statement_extent(lines, i, strip)
        if end is None:
            i += 1
            continue
        src = "\n".join(strip(l) for l in lines[i:end])
        try:
            title, key, (name, args) = _Parser(_tokens(src)).statement()
        except (_Unrecognized, ValueError):
            i = end
            continue
        entry = {"start": i, "end": end}
        try:
            b = _binding_from_call(title, key, name, args)
            if b is not None:
                b["enabled"] = not disabled
                generate_binding_js(b, b.get("resourceClass", ""))  # validate
        except ValueError as e:
            entry["invalid"] = {"line": i + 1, "text": lines[i].strip(), "title": title, "key": key, "reason": str(e)}
            b = None
        if b is not None:
            b["slot"] = len(stmts)
            entry["binding"] = b
        if b is not None or "invalid" in entry:
            stmts.append(entry)
        elif not disabled:
            custom.append({"title": title, "key": key})
        i = end
    return {"lines": lines, "stmts": stmts, "custom": custom}


def parse_hotkeys_js(text: str) -> dict:
    """{"bindings": [...], "invalid": [...]} — what GET /hotkeys-config returns. Each binding
    carries "slot" (its position among the file's recognized statements), which the UI posts back
    untouched so a save knows which statement it came from."""
    m = _file_model(text)
    return {
        "bindings": [s["binding"] for s in m["stmts"] if "binding" in s],
        "invalid": [s["invalid"] for s in m["stmts"] if "invalid" in s],
    }


# ---- rewriting ------------------------------------------------------------------------------------

def _statement_js(b: dict, browser_resource_class: str) -> str:
    # The browser the file already names is the fallback when none is configured (yet).
    js = generate_binding_js(b, browser_resource_class or b.get("resourceClass", ""))
    if b.get("enabled") is False:
        js = "\n".join(DISABLED_MARKER + l for l in js.split("\n"))
    return js


def rewrite_hotkeys_js(text: str, posted: list, browser_resource_class: str = "") -> dict:
    """Puts the UI's bindings back into hotkeys.js: a binding with a "slot" replaces the statement
    it was parsed from (bindings reordered within a section swap statements), a new one goes after
    the last statement of its section (or at the end), and statements no longer posted are
    removed. Invalid or clashing bindings are left out. Returns {"text", "saved", "dropped"}."""
    m = _file_model(text)
    lines, stmts = m["lines"], m["stmts"]
    dropped = []
    titles = {c["title"] for c in m["custom"]}
    keys = {_key_identity(c["key"]) for c in m["custom"]}

    kept = []  # (binding, js)
    for b in posted:
        if not isinstance(b, dict):
            continue
        title = (b.get("title") or "").strip()
        key = (b.get("key") or "").strip()
        try:
            js = _statement_js(b, browser_resource_class)
            if b.get("enabled") is not False:
                # registerShortcut's title is the kglobalaccel action ID: two statements sharing one
                # silently collide in KWin (only one action is registered, keyed by whichever ran
                # first). Same for two actions on one shortcut. Disabled ones register nothing.
                if title in titles:
                    raise ValueError(f"another hotkey already has the title {title!r}")
                if _key_identity(key) in keys:
                    raise ValueError(f"another hotkey already uses {key}")
                titles.add(title)
                keys.add(_key_identity(key))
        except ValueError as e:
            dropped.append({"title": title, "key": key, "reason": str(e)})
            continue
        kept.append((b, js))
    for s in stmts:
        if "invalid" in s:
            inv = s["invalid"]
            dropped.append({"title": inv["title"], "key": inv["key"], "reason": inv["reason"]})

    # Which statement each kept binding takes. The first binding naming a slot claims it (a
    # duplicated row arrives with its original's slot too); within a section the claimed slots are
    # handed out in the posted order, which is how a drag-reorder moves statements.
    claimed, placed, group_slots = set(), [], {}
    for b, js in kept:
        slot = b.get("slot")
        if isinstance(slot, int) and 0 <= slot < len(stmts) and "binding" in stmts[slot] and slot not in claimed:
            claimed.add(slot)
            group_slots.setdefault(_group(b.get("type")), []).append(slot)
        else:
            slot = None
        placed.append((b, js, slot))
    free = {g: iter(sorted(slots)) for g, slots in group_slots.items()}
    at_slot, after_slot, at_end = {}, {}, []
    for b, js, slot in placed:
        group = _group(b.get("type"))
        if slot is not None:
            at_slot[next(free[group])] = js
        elif group in group_slots:
            after_slot.setdefault(max(group_slots[group]), []).append(js)
        else:
            at_end.append(js)

    out, i, skip_blank = [], 0, False
    starts = {s["start"]: (n, s) for n, s in enumerate(stmts)}
    while i < len(lines):
        if i in starts:
            n, s = starts[i]
            chunk = ([at_slot[n]] if n in at_slot else []) + after_slot.get(n, [])
            if chunk:
                out.append("\n\n".join(chunk))
            else:
                skip_blank = True  # removed: take one blank separator line with it
            i = s["end"]
            continue
        if skip_blank and lines[i].strip() == "":
            skip_blank = False
            i += 1
            continue
        skip_blank = False
        out.append(lines[i])
        i += 1
    result = "\n".join(out)
    if result.startswith(LEGACY_HEADER):
        result = HEADER + result[len(LEGACY_HEADER):]
    elif not result.strip():
        result = HEADER
    if at_end:
        result = result.rstrip("\n") + "\n\n" + "\n\n".join(at_end) + "\n"
    return {"text": result, "saved": len(kept), "dropped": dropped}


def fold_legacy_hotkeys_json(text: str, json_bindings: list, browser_resource_class: str = "") -> dict:
    """One-time switch from the earlier hotkeys.json-based UI, where hotkeys.js was regenerated
    from hotkeys.json on every save: hotkeys.json's bindings (disabled ones included — those were
    never written to hotkeys.js at all) replace the recognized statements in hotkeys.js."""
    posted = [{k: v for k, v in b.items() if k != "slot"} for b in json_bindings if isinstance(b, dict)]
    return rewrite_hotkeys_js(text, posted, browser_resource_class)
