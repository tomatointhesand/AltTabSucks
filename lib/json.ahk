; json.ahk - a small JSON reader/writer for the startup manager's files (startup.json, shared with
; Server/StartupItems.ps1, and startup-history.jsonl).
;
; Objects parse to Maps (keys case-sensitive; written back out in sorted order, as Maps enumerate),
; arrays to Arrays, true/false to 1/0 and null to "". AutoHotkey has no booleans, so they come back out as 1/0, which PowerShell's
; ConvertFrom-Json and the startup manager both treat as true/false.

Json_Parse(text) {
    pos := 1
    value := _JsonValue(text, &pos)
    _JsonSkipSpace(text, &pos)
    if pos <= StrLen(text)
        throw ValueError("JSON: unexpected text at character " pos)
    return value
}

; indent: "" for one line (history rows), or e.g. "  " for a readable file.
Json_Stringify(value, indent := "", _prefix := "") {
    inner := _prefix indent
    nl := indent = "" ? "" : "`n"
    sep := indent = "" ? ":" : ": "
    if value is Map {
        if !value.Count
            return "{}"
        out := ""
        for k, v in value
            out .= (out = "" ? "" : ",") nl inner _JsonQuote(String(k)) sep Json_Stringify(v, indent, inner)
        return "{" out nl _prefix "}"
    }
    if value is Array {
        if !value.Length
            return "[]"
        out := ""
        for v in value
            out .= (out = "" ? "" : ",") nl inner Json_Stringify(IsSet(v) ? v : "", indent, inner)
        return "[" out nl _prefix "]"
    }
    if value is Integer || value is Float
        return String(value)
    if IsObject(value) {  ; a plain {} object: its own properties
        m := Map()
        for k, v in value.OwnProps()
            m[k] := v
        return Json_Stringify(m, indent, _prefix)
    }
    return _JsonQuote(String(value))
}

_JsonQuote(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    while RegExMatch(s, "[\x00-\x1F]", &m)
        s := StrReplace(s, m[0], Format("\u{:04x}", Ord(m[0])))
    return '"' s '"'
}

_JsonSkipSpace(text, &pos) {
    if RegExMatch(text, "\G\s+", &m, pos)
        pos += m.Len
}

_JsonValue(text, &pos) {
    _JsonSkipSpace(text, &pos)
    c := SubStr(text, pos, 1)
    if c = "{" {
        result := Map()
        pos++
        _JsonSkipSpace(text, &pos)
        if SubStr(text, pos, 1) = "}" {
            pos++
            return result
        }
        loop {
            _JsonSkipSpace(text, &pos)
            if SubStr(text, pos, 1) != '"'
                throw ValueError("JSON: expected a key at character " pos)
            key := _JsonString(text, &pos)
            _JsonSkipSpace(text, &pos)
            if SubStr(text, pos, 1) != ":"
                throw ValueError("JSON: expected ':' at character " pos)
            pos++
            result[key] := _JsonValue(text, &pos)
            _JsonSkipSpace(text, &pos)
            c := SubStr(text, pos++, 1)
            if c = "}"
                return result
            if c != ","
                throw ValueError("JSON: expected ',' or '}' at character " (pos - 1))
        }
    }
    if c = "[" {
        result := []
        pos++
        _JsonSkipSpace(text, &pos)
        if SubStr(text, pos, 1) = "]" {
            pos++
            return result
        }
        loop {
            result.Push(_JsonValue(text, &pos))
            _JsonSkipSpace(text, &pos)
            c := SubStr(text, pos++, 1)
            if c = "]"
                return result
            if c != ","
                throw ValueError("JSON: expected ',' or ']' at character " (pos - 1))
        }
    }
    if c = '"'
        return _JsonString(text, &pos)
    if RegExMatch(text, "\G-?\d+(\.\d+)?([eE][-+]?\d+)?", &m, pos) {
        pos += m.Len
        return m[1] = "" && m[2] = "" ? Integer(m[0]) : Float(m[0])
    }
    for word, value in Map("true", 1, "false", 0, "null", "") {
        if SubStr(text, pos, StrLen(word)) == word {
            pos += StrLen(word)
            return value
        }
    }
    throw ValueError("JSON: unexpected " (c = "" ? "end of text" : "'" c "'") " at character " pos)
}

_JsonString(text, &pos) {
    if !RegExMatch(text, '\G"((?:[^"\\]|\\.)*)"', &m, pos)
        throw ValueError("JSON: unterminated string at character " pos)
    pos += m.Len
    s := m[1]
    if !InStr(s, "\")
        return s
    out := ""
    i := 1
    while (j := InStr(s, "\", true, i)) {
        out .= SubStr(s, i, j - i)
        e := SubStr(s, j + 1, 1)
        switch e, true {
            case "n": out .= "`n"
            case "r": out .= "`r"
            case "t": out .= "`t"
            case "b": out .= "`b"
            case "f": out .= "`f"
            case "u":
                out .= Chr(Integer("0x" SubStr(s, j + 2, 4)))
                j += 4
            default: out .= e  ; \" \\ \/
        }
        i := j + 2
    }
    return out SubStr(s, i)
}
