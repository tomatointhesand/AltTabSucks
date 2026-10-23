# test-tab-search.ps1 - tests for Server/TabSearch.ps1, the Windows side of the tab search popup.
# Mirrors linux/server/tests/test_tab_search.py (same rules) plus the saved data and favicons.
# Run with: bash dev-scripts/run-ps-tests.sh

. "$PSScriptRoot/assert.ps1"
. "$PSScriptRoot/../../Server/TabSearch.ps1"

$root = Join-Path ([IO.Path]::GetTempPath()) "alttabsucks-tab-search-test-$PID"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
$script:storeN = 0
function NewDir { Join-Path $root ("store" + (++$script:storeN)) }  # each store saves to its own folder

function Json($o) { ConvertTo-Json -InputObject $o -Depth 10 -Compress }
function Tab($id, $title, $url, $last, [switch]$active) {
    [ordered]@{ id = $id; title = $title; url = $url.Substring(0, [Math]::Min(30, $url.Length)); fullUrl = $url; lastAccessed = $last; active = [bool]$active }
}
function New-Store {
    $s = [AltTabSucks.TabSearchStore]::new((NewDir))
    $s.SetTabs((Json @{ profile = "Personal"; windows = @(
        @{ id = 1; focused = $true; tabs = @(
            (Tab 11 "Inbox - Gmail" "https://mail.google.com/mail/u/0/#inbox" 500 -active),
            (Tab 12 "YouTube" "https://www.youtube.com/watch?v=abc" 400),
            (Tab 13 "Sailing forecast" "https://windy.com/sailing" 300)) },
        @{ id = 2; focused = $false; tabs = @((Tab 21 "GitHub - alttabsucks" "https://github.com/tomatointhesand/AltTabSucks" 450 -active)) }) }))
    $s.SetRecent((Json @{ profile = "Personal"; items = @(
        @{ sessionId = "s1"; title = "Old sailing article"; url = "https://news.example/sail"; closedAt = 100 },
        @{ sessionId = "s2"; title = "Recipe"; url = "https://food.example/pasta"; closedAt = 200 }) }))
    $s.SetBookmarks((Json @{ profile = "Personal"; items = @(@{ id = "b1"; title = "Pasta recipes"; url = "https://food.example/" }) }))
    $s.MarkPoll("Personal")
    $s
}
function Sections($r) { $o = [ordered]@{}; foreach ($sec in $r.Sections) { $o[$sec.Category] = @($sec.Items) }; $o }
function Cats($r) { , @($r.Sections | ForEach-Object Category) }  # , : keep a one-item list a list

# ---- open tabs ----------------------------------------------------------------------------------

$s = New-Store
Assert-Equal @($s.OpenTabs($s.LiveProfiles()) | ForEach-Object TabId) @(21, 12, 13) "open tabs: most recently used first, without the tab you're on"
Assert-Equal @($s.OpenTabs($s.LiveProfiles(), "GitHub - alttabsucks - Edge") | ForEach-Object TabId) @(11, 12, 13) "  ...KWin/AHK's front window caption decides which tab you're on"
Assert-Equal @($s.OpenTabs($s.LiveProfiles(), "") | ForEach-Object TabId) @(11, 21, 12, 13) "  ...front window isn't a browser: all tabs listed"
Assert-Equal @($s.OpenTabs([Collections.Generic.HashSet[string]]::new())).Count 0 "  ...none from a browser that isn't running"

$u = [AltTabSucks.TabSearchStore]::new((NewDir))
$u.SetTabs((Json @{ profile = "P"; windows = @(@{ id = 1; focused = $false; tabs = @(
    ((Tab 1 "flicked past" "https://a.example" 900) + @{ lastUsed = 100 }),
    ((Tab 2 "really used" "https://b.example" 500) + @{ lastUsed = 400 })) }) }))
$u.MarkPoll("P")
Assert-Equal @($u.OpenTabs($u.LiveProfiles()) | ForEach-Object Title) @("really used", "flicked past") "lastUsed (1.5s rule) beats lastAccessed"

# ---- sections -----------------------------------------------------------------------------------

$r = Sections ($s.Search("sail"))
Assert-Equal @(@($r["tabs"] | ForEach-Object TabId), @($r["recent"] | ForEach-Object SessionId)) @(@(13), @("s1")) "open and recently closed tabs show together"
Assert-Equal (Cats ($s.Search("pasta"))) @("recent", "bookmarks") "bookmarks join with fewer than 5 results"
Assert-Equal (Cats ($s.Search("https"))) @("tabs", "recent") "  ...not with 5 or more"
$s.SetBookmarks((Json @{ profile = "Personal"; items = @(@{ id = "b2"; title = "Docs"; url = "https://docs.example/" }) }))
Assert-Equal (Cats ($s.Search("https "))) @("tabs", "recent", "bookmarks") "  ...a trailing space adds bookmarks"
Assert-Equal (Cats ($s.Search(" https"))) @("tabs", "recent", "bookmarks") "  ...and a leading one"
Assert-Equal (Cats ($s.Search("  docs"))) @("bookmarks") "two spaces search bookmarks only"
$e = Sections ($s.Search(""))
Assert-Equal @($e.Keys) @("tabs", "recent") "empty query: open and recently closed, no bookmarks"
Assert-Equal @($e["recent"] | ForEach-Object SessionId) @("s2", "s1") "  ...most recently closed first"
Assert-Equal @($s.Search("zzz").Sections).Count 0 "nothing matches"
Assert-Equal @(($s.Search("sail").Sections[0].Items) | ForEach-Object TabId) @(13) "title matches rank first (url-only matches after)"

$c = [AltTabSucks.TabSearchStore]::new((NewDir))
$c.SetRecent((Json @{ profile = "Personal"; items = @(@{ sessionId = "s1"; title = "Old"; url = "https://news.example/"; closedAt = 1 }) }))
$cr = $c.Search("")
Assert-Equal @((Cats $cr)[0], @($cr.Sections).Count, $cr.Sections[0].Items[0].Profile, $cr.Live.Count) @("recent", 1, "Personal", 0) "browser closed: only recently closed, not live"

$two = New-Store
$two.SetTabs((Json @{ profile = "Work"; windows = @(@{ id = 9; focused = $false; tabs = @((Tab 91 "Jira" "https://jira.example" 600)) }) }))
Assert-Equal $s.Search("").ShowProfile $false "profile labels: not with one profile open"
$two.MarkPoll("Work")
Assert-Equal $two.Search("").ShowProfile $true "  ...with two"

# ---- output formats -----------------------------------------------------------------------------

$j = [AltTabSucks.TabSearchStore]::ToJson($s.Search("sail")) | ConvertFrom-Json
Assert-Equal @($j.sections[0].category, $j.sections[0].items[0].tabId, $j.sections[0].items[0].iconKey, $j.sections[1].items[0].live) @("tabs", 13, "windy.com/sailing", $true) "JSON in the Linux server's shape"
$tsv = [AltTabSucks.TabSearchStore]::ToTsv($s.Search("sail")) -split "`n"
Assert-Equal $tsv[0..2] @("showProfile`t0", "section`ttabs", "item`ttab`tPersonal`t1`t13`t`twindy.com/sailing`t1`tSailing forecast`thttps://windy.com/sailing") "TSV for the AHK popup"
$t2 = [AltTabSucks.TabSearchStore]::new((NewDir))
$t2.SetTabs((Json @{ profile = "P"; windows = @(@{ id = 1; tabs = @((Tab 1 "a`tb`nc" "https://x.example" 1)) }) })); $t2.MarkPoll("P")
Assert-Equal (([AltTabSucks.TabSearchStore]::ToTsv($t2.Search("")) -split "`n")[2] -split "`t")[8] "a b c" "  ...tabs and newlines in titles can't break a line"

# ---- saved data, closes, liveness ---------------------------------------------------------------

$l = [AltTabSucks.TabSearchStore]::new((Join-Path $root "store1")); $l.Load()  # where $s saved
Assert-Equal @(($l.Search("  docs").Sections[0].Items) | ForEach-Object Id) @("b2") "bookmarks are saved and loaded back"
Assert-Equal @(($l.Search("recipe").Sections[0].Items) | ForEach-Object SessionId) @("s2") "  ...and recently closed"
$s.AddClose("Personal", 12); $s.AddClose("Personal", 13)
Assert-Equal @($s.TakeCloses("Personal")) @(12, 13) "closes are kept until the extension's next poll, all of them"
Assert-Equal @($s.TakeCloses("Personal")).Count 0 "  ...once"
Assert-Equal $s.ActiveTitle("Personal", 2) "GitHub - alttabsucks" "active tab title of a window (to find it on screen)"
$bad = $true; try { $s.SetRecent('{"items":[]}') ; $bad = $false } catch { }
Assert-Equal $bad $true "an upload without a profile is rejected"

# ---- favicons -----------------------------------------------------------------------------------

$png = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")
$urls = "https://docs.google.com/document/d/1", "https://docs.google.com/document/d/2", "https://example.com/x"
Assert-Equal @($s.MissingFavicons([string[]]$urls)) @($urls[0], $urls[2]) "favicons: one page per icon key is missing"
Assert-Equal $s.PutFavicon($urls[0], $png) $true "  ...a PNG is stored"
Assert-Equal @($s.MissingFavicons([string[]]$urls)) @($urls[2]) "  ...and no longer missing"
Assert-Equal ([Convert]::ToBase64String($s.GetFavicon("docs.google.com/document"))) ([Convert]::ToBase64String($png)) "  ...served by key"
Assert-Equal $s.PutFavicon("https://a.example/", [Text.Encoding]::UTF8.GetBytes("<svg/>")) $false "  ...anything but a PNG is refused"
Assert-Equal $s.PutFavicon("chrome://settings", $png) $false "  ...as are non-web pages"
Assert-Equal ([AltTabSucks.TabSearchStore]::new((Join-Path $root "store1")).MissingFavicons([string[]]@($urls[0])).Count) 0 "  ...and they survive a restart"
Assert-Equal @([AltTabSucks.TabSearchStore]::IconKey("https://Example.COM/A?x"), [AltTabSucks.TabSearchStore]::IconKey("http://localhost:9876/hotkeys-ui"), [AltTabSucks.TabSearchStore]::IconKey("chrome://x")) @("example.com/A", "localhost:9876/hotkeys-ui", $null) "icon keys match Linux's"

# ---- speed: the reason this is C# ---------------------------------------------------------------

$big = [AltTabSucks.TabSearchStore]::new((NewDir))
$items = foreach ($n in 1..20000) { @{ id = "$n"; title = "Bookmark $n about sailing and boats"; url = "https://example.com/path/$n" } }
$big.SetBookmarks((Json @{ profile = "P"; items = $items }))
$null = $big.Search("  sail boat")
$sw = [Diagnostics.Stopwatch]::StartNew(); $hits = $big.Search("  sail boat 1999"); $ms = $sw.ElapsedMilliseconds
Assert-Equal (@($hits.Sections[0].Items).Count -gt 0 -and $ms -lt 100) $true "searching 20,000 bookmarks takes under 100ms (took ${ms}ms)"

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Complete-Asserts
