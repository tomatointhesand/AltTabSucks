; assert.ahk - minimal assertion helpers for AHK v2 tests.
;
; Results go to a file rather than stdout: AutoHotkey64.exe is a GUI-subsystem binary, so stdout
; is unreliable on real Windows and under Wine alike. Path comes from the first command-line
; argument (dev-scripts/run-ahk-tests.sh passes one), else test-results.txt next to the test.
; A test script ends with AssertDone(), which exits 0 if everything passed and 1 otherwise, so a
; runner can rely on the exit code alone.

global _assertPassed := 0
global _assertFailed := 0
global _assertOut := A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\test-results.txt"

try FileDelete(_assertOut)

; An uncaught runtime error would normally pop AutoHotkey's error dialog and block until someone
; clicks it — under Wine that dialog lands on the real desktop (learned the hard way from the
; AutoHotkey installer's own error dialog). Log it and exit 2 instead, so the runner reports it
; and nothing waits on a human. Load-time syntax errors are covered separately by the runner's
; /ErrorStdOut switch.
OnError(_AssertOnError)
_AssertOnError(err, mode) {
    _AssertLog("ERROR " Type(err) ": " err.Message "`n        at " err.File ":" err.Line)
    ExitApp(2)
}

_AssertLog(line) {
    FileAppend(line "`n", _assertOut, "UTF-8-RAW")  ; -RAW: no BOM in front of the first line
}

AssertEq(actual, expected, name) {
    global _assertPassed, _assertFailed
    if actual == expected {
        _assertPassed += 1
        _AssertLog("PASS  " name)
    } else {
        _assertFailed += 1
        _AssertLog("FAIL  " name "`n        expected: " String(expected) "`n        actual:   " String(actual))
    }
}

AssertDone() {
    _AssertLog("`n" _assertPassed " passed, " _assertFailed " failed")
    ExitApp(_assertFailed > 0 ? 1 : 0)
}
