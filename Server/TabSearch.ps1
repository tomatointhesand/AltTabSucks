# TabSearch.ps1 - the Windows side of the tab search popup (Ctrl+Alt+Shift+A; lib/tab-search.ahk).
# Windows counterpart of linux/server/tab_search.py + tab_search_state.py + favicon_store.py, in C#
# (Add-Type) so ranking thousands of bookmarks per keystroke takes milliseconds, not the hundreds a
# PowerShell loop does. Same rules as Linux, modeled on the Quick Tabs extension:
#
# - Open tabs and recently closed tabs always show together, each its own section; bookmarks join
#   as a third section when those two have fewer than 5 results, or when the query starts or ends
#   with a space. Two spaces search bookmarks only. An empty query lists open and recently closed.
# - Every query word must appear in the title or URL (any order, case-insensitive); more words in
#   the title rank first, then most recently used / closed. The tab you're on is left out.
# - Open tabs only of live profiles: a profile is live while its extension keeps polling
#   GET /switchtab, since the server keeps a closed browser's last tab list.
# - Bookmarks come from the snapshot the extension uploads on every change (no live search: this
#   server handles one request at a time, so it couldn't take the browser's answer mid-request).
# - Recently closed tabs, bookmarks and favicons are saved under %LOCALAPPDATA%\AltTabSucks, so
#   they're still offered while the browser is closed, and survive restarts.
#
# Tests: tests/ps/test-tab-search.ps1.

if (-not ('AltTabSucks.TabSearchStore' -as [type])) {
    Add-Type -TypeDefinition @'
#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AltTabSucks;

public sealed class SearchItem
{
    public string Kind = "", Profile = "", Title = "", Url = "", Id = "", SessionId = "";
    public long WindowId, TabId;
    public double Recency;      // tabs: lastUsed (or lastAccessed); recently closed: closedAt
    public bool Active, Focused;
    internal string TitleLower = "", UrlLower = "";

    internal SearchItem Init() { TitleLower = Title.ToLowerInvariant(); UrlLower = Url.ToLowerInvariant(); return this; }
}

public sealed class SearchSection
{
    public string Category = "";
    public List<SearchItem> Items = new();
}

public sealed class SearchResult
{
    public List<SearchSection> Sections = new();
    public bool ShowProfile;
    public HashSet<string> Live = new();
}

public sealed class TabSearchStore
{
    public const int DefaultLimit = 50;
    public const int BookmarksBelow = 5;
    public static readonly TimeSpan LiveFor = TimeSpan.FromSeconds(2);

    readonly string dataPath, faviconDir;
    readonly Dictionary<string, List<SearchItem>> tabs = new(), recent = new(), bookmarks = new();
    readonly Dictionary<string, long> lastPoll = new();       // profile -> Stopwatch ticks
    readonly Dictionary<string, List<long>> closes = new();
    HashSet<string>? knownIcons;

    public TabSearchStore(string dataDir)
    {
        dataPath = Path.Combine(dataDir, "browser-data.json");
        faviconDir = Path.Combine(dataDir, "favicons");
    }

    // ---- data from the extension ----------------------------------------------------------------

    static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    static double Num(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;
    static bool Bool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    /// <summary>POST /tabs body: {"profile", "windows": [{id, focused, tabs: [...]}]}.</summary>
    public void SetTabs(string body)
    {
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;
        var profile = Str(root, "profile");
        var list = new List<SearchItem>();
        if (root.TryGetProperty("windows", out var windows) && windows.ValueKind == JsonValueKind.Array)
            foreach (var w in windows.EnumerateArray())
            {
                if (!w.TryGetProperty("tabs", out var ts) || ts.ValueKind != JsonValueKind.Array) continue;
                foreach (var t in ts.EnumerateArray())
                {
                    var used = Num(t, "lastUsed");
                    list.Add(new SearchItem
                    {
                        Kind = "tab", Profile = profile, WindowId = (long)Num(w, "id"), TabId = (long)Num(t, "id"),
                        Title = Str(t, "title"), Url = Str(t, "fullUrl") is { Length: > 0 } f ? f : Str(t, "url"),
                        Recency = used > 0 ? used : Num(t, "lastAccessed"),
                        Active = Bool(t, "active"), Focused = Bool(w, "focused"),
                    }.Init());
                }
            }
        tabs[profile] = list;
    }

    public void RemoveTabs(string profile) => tabs.Remove(profile);

    static List<SearchItem> ParseItems(JsonElement items, string kind, string profile)
    {
        var list = new List<SearchItem>();
        if (items.ValueKind != JsonValueKind.Array) return list;
        foreach (var i in items.EnumerateArray())
        {
            var url = Str(i, "url");
            if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) continue;
            list.Add(new SearchItem
            {
                Kind = kind, Profile = profile, Url = url, Title = Str(i, "title") is { Length: > 0 } t ? t : url,
                Id = Str(i, "id"), SessionId = Str(i, "sessionId"), Recency = Num(i, "closedAt"),
            }.Init());
        }
        return list;
    }

    /// <summary>POST /recently-closed body: {"profile", "items": [{sessionId, title, url, closedAt}]}.</summary>
    public void SetRecent(string body) => SetList(recent, body, "recent");

    /// <summary>POST /bookmarks body: {"profile", "items": [{id, title, url}]}.</summary>
    public void SetBookmarks(string body) => SetList(bookmarks, body, "bookmark");

    void SetList(Dictionary<string, List<SearchItem>> target, string body, string kind)
    {
        using var doc = JsonDocument.Parse(body);
        var profile = Str(doc.RootElement, "profile");
        if (profile.Length == 0) throw new ArgumentException("missing profile");
        target[profile] = doc.RootElement.TryGetProperty("items", out var items) ? ParseItems(items, kind, profile) : new();
        Save();
    }

    // ---- saved to disk ----------------------------------------------------------------------------

    public void Load()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(dataPath));
            foreach (var (name, target, kind) in new[] { ("recent", recent, "recent"), ("bookmarks", bookmarks, "bookmark") })
                if (doc.RootElement.TryGetProperty(name, out var byProfile) && byProfile.ValueKind == JsonValueKind.Object)
                    foreach (var p in byProfile.EnumerateObject())
                        target[p.Name] = ParseItems(p.Value, kind, p.Name);
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    }

    void Save()
    {
        static JsonObject Dump(Dictionary<string, List<SearchItem>> d) => new(d.Select(kv =>
            KeyValuePair.Create<string, JsonNode?>(kv.Key, new JsonArray(kv.Value.Select(i => (JsonNode)new JsonObject
            {
                ["id"] = i.Id, ["sessionId"] = i.SessionId, ["title"] = i.Title, ["url"] = i.Url, ["closedAt"] = i.Recency,
            }).ToArray()))));
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(dataPath)!);
            var json = new JsonObject { ["recent"] = Dump(recent), ["bookmarks"] = Dump(bookmarks) }.ToJsonString();
            File.WriteAllText(dataPath + ".tmp", json);
            File.Move(dataPath + ".tmp", dataPath, true);
        }
        catch (IOException) { }  // best-effort: in memory it's still current
    }

    // ---- which browsers are running ---------------------------------------------------------------

    public void MarkPoll(string profile) => lastPoll[profile] = Stopwatch.GetTimestamp();

    public HashSet<string> LiveProfiles()
    {
        var now = Stopwatch.GetTimestamp();
        return lastPoll.Where(kv => Stopwatch.GetElapsedTime(kv.Value, now) < LiveFor).Select(kv => kv.Key).ToHashSet();
    }

    // ---- closing tabs (Ctrl+W) --------------------------------------------------------------------
    // Kept apart from the one-command switch queue, where a second close or a following Enter
    // would overwrite it before the extension's next 50ms poll.

    public void AddClose(string profile, long tabId)
    {
        if (!closes.TryGetValue(profile, out var l)) closes[profile] = l = new();
        l.Add(tabId);
    }

    public long[] TakeCloses(string profile) =>
        closes.Remove(profile, out var l) ? l.ToArray() : Array.Empty<long>();

    /// <summary>Title of the active tab in a window: KWin-style matching of a browser window by caption.</summary>
    public string ActiveTitle(string profile, long windowId) =>
        tabs.TryGetValue(profile, out var l) ? l.FirstOrDefault(t => t.WindowId == windowId && t.Active)?.Title ?? "" : "";

    // ---- search -----------------------------------------------------------------------------------

    public static string[] Words(string query) =>
        (query ?? "").ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Matches, best first: more words in the title, then higher recency (if useRecency),
    /// then original order. Every word must be in the title or URL.</summary>
    public static List<SearchItem> Rank(IEnumerable<SearchItem> items, string[] words, bool useRecency, int limit)
    {
        var scored = new List<(int hits, double recency, int index, SearchItem item)>();
        int index = 0;
        foreach (var item in items)
        {
            int hits = 0;
            bool ok = true;
            foreach (var w in words)
            {
                if (item.TitleLower.Contains(w, StringComparison.Ordinal)) hits++;
                else if (!item.UrlLower.Contains(w, StringComparison.Ordinal)) { ok = false; break; }
            }
            if (ok) scored.Add((hits, useRecency ? item.Recency : 0, index, item));
            index++;
        }
        return scored.OrderByDescending(s => s.hits).ThenByDescending(s => s.recency).ThenBy(s => s.index)
                     .Take(limit).Select(s => s.item).ToList();
    }

    /// <summary>Open tabs of live profiles, most recently used first, without the tab you're on:
    /// with currentCaption (the title of the window in front, "" if it isn't a browser) an active
    /// tab whose title is in it; without (null), the active tab of a focused window.</summary>
    public List<SearchItem> OpenTabs(HashSet<string> live) => OpenTabs(live, null);

    // Overloads rather than a nullable parameter: PowerShell passes $null to a string parameter as "".
    public List<SearchItem> OpenTabs(HashSet<string> live, string? currentCaption)
    {
        var list = new List<SearchItem>();
        foreach (var (profile, items) in tabs)
        {
            if (!live.Contains(profile)) continue;
            foreach (var t in items)
            {
                bool current = t.Active && (currentCaption is null
                    ? t.Focused
                    : t.Title.Length > 0 && currentCaption.Contains(t.Title, StringComparison.Ordinal));
                if (!current) list.Add(t);
            }
        }
        return list.OrderByDescending(t => t.Recency).ToList();
    }

    public SearchResult Search(string query) => Search(query, null, DefaultLimit);

    public SearchResult Search(string query, string? currentCaption, int limit = DefaultLimit)
    {
        query ??= "";
        var words = Words(query);
        var live = LiveProfiles();
        var open = OpenTabs(live, currentCaption);
        var result = new SearchResult { Live = live, ShowProfile = open.Select(t => t.Profile).Distinct().Count() > 1 };

        List<SearchItem> foundTabs = new(), foundRecent = new(), foundBookmarks = new();
        bool wantBookmarks;
        if (words.Length > 0 && (query.StartsWith("  ") || query.EndsWith("  ")))
            wantBookmarks = true;  // two spaces: bookmarks only
        else
        {
            foundTabs = Rank(open, words, false, limit);  // already most recently used first
            foundRecent = Rank(recent.Values.SelectMany(l => l), words, true, limit);
            wantBookmarks = words.Length > 0 &&
                (query.StartsWith(" ") || query.EndsWith(" ") || foundTabs.Count + foundRecent.Count < BookmarksBelow);
        }
        if (wantBookmarks) foundBookmarks = Rank(bookmarks.Values.SelectMany(l => l), words, false, limit);

        foreach (var (category, found) in new[] { ("tabs", foundTabs), ("recent", foundRecent), ("bookmarks", foundBookmarks) })
            if (found.Count > 0) result.Sections.Add(new SearchSection { Category = category, Items = found });
        return result;
    }

    /// <summary>The result as JSON, in the Linux server's shape (GET /tab-search).</summary>
    public static string ToJson(SearchResult r) => new JsonObject
    {
        ["sections"] = new JsonArray(r.Sections.Select(s => (JsonNode)new JsonObject
        {
            ["category"] = s.Category,
            ["items"] = new JsonArray(s.Items.Select(i => (JsonNode)ItemJson(i, r.Live)).ToArray()),
        }).ToArray()),
        ["showProfile"] = r.ShowProfile,
    }.ToJsonString();

    static JsonObject ItemJson(SearchItem i, HashSet<string> live)
    {
        var o = new JsonObject { ["kind"] = i.Kind, ["profile"] = i.Profile, ["title"] = i.Title, ["url"] = i.Url, ["iconKey"] = IconKey(i.Url) };
        switch (i.Kind)
        {
            case "tab": o["windowId"] = i.WindowId; o["tabId"] = i.TabId; o["lastUsed"] = i.Recency; break;
            case "recent": o["sessionId"] = i.SessionId; o["closedAt"] = i.Recency; o["live"] = live.Contains(i.Profile); break;
            default: o["id"] = i.Id; o["live"] = live.Contains(i.Profile); break;
        }
        return o;
    }

    /// <summary>The result for lib/tab-search.ahk: a header line ("showProfile\t0|1"), then per
    /// section "section\t<category>" and per item "item\t" + kind, profile, windowId, tabId,
    /// sessionId, iconKey, live, title, url (tab-separated; tabs/newlines in values become spaces).</summary>
    public static string ToTsv(SearchResult r)
    {
        static string Clean(string s) => s.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
        var sb = new StringBuilder().Append("showProfile\t").Append(r.ShowProfile ? 1 : 0).Append('\n');
        foreach (var s in r.Sections)
        {
            sb.Append("section\t").Append(s.Category).Append('\n');
            foreach (var i in s.Items)
                sb.AppendJoin('\t', "item", i.Kind, Clean(i.Profile), i.WindowId, i.TabId, Clean(i.SessionId),
                    Clean(IconKey(i.Url) ?? ""), r.Live.Contains(i.Profile) ? 1 : 0, Clean(i.Title), Clean(i.Url)).Append('\n');
        }
        return sb.ToString();
    }

    // ---- favicons ---------------------------------------------------------------------------------

    /// <summary>Which favicon a URL shows: host plus first path segment ("docs.google.com/document"),
    /// so apps sharing a host still differ. Null for non-web URLs. Same as Linux's icon_key.</summary>
    public static string? IconKey(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https") || u.Host.Length == 0)
            return null;
        var host = u.Host.ToLowerInvariant() + (u.IsDefaultPort ? "" : ":" + u.Port);
        var seg = u.AbsolutePath.TrimStart('/').Split('/', 2)[0];
        return seg.Length > 0 ? host + "/" + Uri.UnescapeDataString(seg) : host;
    }

    static string Stem(string key) => Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant();

    HashSet<string> KnownIcons()
    {
        if (knownIcons is null)
        {
            knownIcons = new();
            if (Directory.Exists(faviconDir))
                foreach (var f in Directory.EnumerateFiles(faviconDir, "*.png")) knownIcons.Add(Path.GetFileNameWithoutExtension(f));
        }
        return knownIcons;
    }

    /// <summary>POST /favicons/missing: the page URLs (one per icon key) whose icon isn't stored yet.</summary>
    public string[] MissingFavicons(IEnumerable<string> pageUrls)
    {
        var byKey = new Dictionary<string, string>();
        foreach (var url in pageUrls)
            if (IconKey(url) is { } key && !byKey.ContainsKey(key)) byKey[key] = url;
        var known = KnownIcons();
        return byKey.Where(kv => !known.Contains(Stem(kv.Key))).Select(kv => kv.Value).ToArray();
    }

    public const int MaxIconBytes = 64 * 1024;
    static readonly byte[] PngMagic = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    /// <summary>Stores a favicon for a page URL's key. False for anything but a small PNG.</summary>
    public bool PutFavicon(string pageUrl, byte[] png)
    {
        if (IconKey(pageUrl) is not { } key || png.Length > MaxIconBytes || !png.AsSpan().StartsWith(PngMagic)) return false;
        var stem = Stem(key);
        try
        {
            Directory.CreateDirectory(faviconDir);
            File.WriteAllBytes(Path.Combine(faviconDir, stem + ".tmp"), png);
            File.Move(Path.Combine(faviconDir, stem + ".tmp"), Path.Combine(faviconDir, stem + ".png"), true);
        }
        catch (IOException) { return false; }
        KnownIcons().Add(stem);
        return true;
    }

    public byte[]? GetFavicon(string key)
    {
        if (string.IsNullOrEmpty(key)) return null;
        var path = Path.Combine(faviconDir, Stem(key) + ".png");
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }
}
'@
}
