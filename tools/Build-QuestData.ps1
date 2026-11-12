<#
.SYNOPSIS
  Builds DoINeedThis/Data/Quests.lua from Wowhead (Forever) data.

.DESCRIPTION
  Collects quest IDs from:
    - the existing Data/Quests.lua
    - completed-quest snapshots (/dint completed) in the SavedVariables file
    - quests learned in-game at the turn-in window (DoINeedThisDB.learned)
  For each quest, reads its requirements from Wowhead's tooltip data, resolves
  item names to item IDs, and keeps only items that can be traded (not
  "Quest Item", "Binds when picked up" or "Soulbound").
  Quests with no tradeable items are left out.

  Responses are cached in tools/.cache so reruns are fast and polite.

.EXAMPLE
  powershell -File tools\Build-QuestData.ps1 -SavedVariables "C:\...\SavedVariables\DoINeedThis.lua"
#>
param(
    [string]$SavedVariables,
    [int[]]$QuestIds = @(),
    [string]$OutFile = (Join-Path $PSScriptRoot "..\DoINeedThis\Data\Quests.lua"),
    [int]$DelayMs = 400
)

$ErrorActionPreference = "Stop"
$CacheDir = Join-Path $PSScriptRoot ".cache"
New-Item -ItemType Directory -Force $CacheDir | Out-Null
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

function Get-Json([string]$url) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $key = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($url)) | ForEach-Object { $_.ToString("x2") })
    $file = Join-Path $CacheDir "$key.json"
    if (Test-Path $file) {
        $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    } else {
        Start-Sleep -Milliseconds $DelayMs
        $resp = Invoke-WebRequest -Uri $url -UserAgent $UA -UseBasicParsing
        $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        [IO.File]::WriteAllText($file, $text, [Text.Encoding]::UTF8)
    }
    if ($text.TrimStart().StartsWith("<")) { return $null }   # HTML error page
    return $text | ConvertFrom-Json
}

function Decode([string]$s) { [System.Net.WebUtility]::HtmlDecode($s).Trim() }
function LuaStr([string]$s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

# ---------------------------------------------------------------------------
# Collect quest IDs
# ---------------------------------------------------------------------------
$ids = [System.Collections.Generic.SortedSet[int]]::new()
foreach ($q in $QuestIds) { [void]$ids.Add($q) }

$learned = @{}   # questID -> @{ name; items = @{ itemID = count }; faction }
# Existing entries are kept exactly as they are (baking is additive), so quests
# Wowhead doesn't know about survive reruns.
$existing = @{}
if (Test-Path $OutFile) {
    $text = [IO.File]::ReadAllText((Resolve-Path $OutFile), [Text.Encoding]::UTF8)
    $rx = '(?ms)^\s*\[(\d+)\] = \{ name = ("(?:[^"\\]|\\.)*")(?:, faction = "(\w+)")?, items = \{[^\r\n]*\r?\n(.*?)^\s*\} \},'
    foreach ($m in [regex]::Matches($text, $rx)) {
        $qid = [int]$m.Groups[1].Value
        $items = [ordered]@{}
        foreach ($it in [regex]::Matches($m.Groups[4].Value, '\[(\d+)\] = (\d+), -- ([^\r\n]*)')) {
            $items[$it.Groups[1].Value] = @{ count = [int]$it.Groups[2].Value; name = $it.Groups[3].Value }
        }
        $name = $m.Groups[2].Value.Substring(1, $m.Groups[2].Value.Length - 2) -replace '\\(.)', '$1'
        $existing[$qid] = @{ id = $qid; name = $name; faction = $m.Groups[3].Value; items = $items;
                             learned = $m.Value -match 'learned in-game' }
        [void]$ids.Add($qid)
    }
}
if ($SavedVariables) {
    $sv = [IO.File]::ReadAllText($SavedVariables, [Text.Encoding]::UTF8)
    # completed snapshots: only quests with a name (unnamed ones are hidden flags)
    foreach ($m in [regex]::Matches($sv, '\["id"\] = (\d+),\s*\r?\n\["name"\] = ')) {
        [void]$ids.Add([int]$m.Groups[1].Value)
    }
    # learned quests (flat entries, see Learn.lua):
    #   ["learned"] = { [questID] = { ["name"] = "..", ["items"] = "id:count,id:count", ["faction"] = "Alliance" }, ... }
    $start = $sv.IndexOf('["learned"] = {')
    if ($start -ge 0) {
        $rx = [regex]'\G\s*\[(\d+)\] = \{([^{}]*)\},'
        $pos = $start + '["learned"] = {'.Length
        while (($q = $rx.Match($sv, $pos)).Success) {
            $pos = $q.Index + $q.Length
            $qid = [int]$q.Groups[1].Value
            $body = $q.Groups[2].Value
            $items = @{}
            $itemStr = [regex]::Match($body, '\["items"\] = "([^"]*)"').Groups[1].Value
            foreach ($it in [regex]::Matches($itemStr, '(\d+):(\d+)')) {
                $items[[int]$it.Groups[1].Value] = [int]$it.Groups[2].Value
            }
            $name = [regex]::Match($body, '\["name"\] = "((?:[^"\\]|\\.)*)"').Groups[1].Value
            $faction = [regex]::Match($body, '\["faction"\] = "([^"]*)"').Groups[1].Value
            $learned[$qid] = @{ name = $name; items = $items; faction = $faction }
            [void]$ids.Add($qid)
        }
    }
}
Write-Host "Checking $($ids.Count) quests..."

# ---------------------------------------------------------------------------
# Resolve requirements
# ---------------------------------------------------------------------------
$itemCache = @{}   # name -> @{ id; tradeable; binding } or $null
function Resolve-Item([string]$name) {
    if ($itemCache.ContainsKey($name)) { return $itemCache[$name] }
    $result = $null
    $search = Get-Json ("https://www.wowhead.com/forever/search/suggestions-template?q=" + [uri]::EscapeDataString($name))
    $hit = $search.results | Where-Object { $_.type -eq 3 -and $_.name -eq $name } | Select-Object -First 1
    if ($hit) { $result = Resolve-ItemId $hit.id }
    $itemCache[$name] = $result
    return $result
}
function Resolve-ItemId([int]$id) {
    $tt = Get-Json "https://nether.wowhead.com/forever/tooltip/item/$id"
    if (-not $tt) { return $null }
    $binding = "none"
    if ($tt.tooltip -match 'Quest Item') { $binding = "quest" }
    elseif ($tt.tooltip -match 'Binds when picked up') { $binding = "pickup" }
    elseif ($tt.tooltip -match 'Soulbound') { $binding = "soulbound" }
    return @{ id = $id; name = $tt.name; binding = $binding; tradeable = ($binding -eq "none") }
}

$entries = @()
$skipped = @()
foreach ($qid in $ids) {
    if ($existing.ContainsKey($qid)) {
        $entries += $existing[$qid]
        continue
    }
    $tt = Get-Json "https://nether.wowhead.com/forever/tooltip/quest/$qid"
    $qname = if ($tt) { Decode $tt.name } elseif ($learned[$qid]) { $learned[$qid].name } else { "Quest $qid" }
    $items = [ordered]@{}

    if ($learned.ContainsKey($qid)) {
        # In-game data has exact IDs and counts; just confirm tradeability.
        foreach ($itemId in $learned[$qid].items.Keys) {
            $info = Resolve-ItemId $itemId
            if (-not $info -or $info.tradeable) {
                $items["$itemId"] = @{ count = $learned[$qid].items[$itemId]; name = $(if ($info) { $info.name } else { "item $itemId" }) }
            }
        }
    } elseif ($tt -and $tt.tooltip -match 'Requirements:</span>(.*?)</td>') {
        foreach ($m in [regex]::Matches($Matches[1], ' - (.+?) x (\d+)')) {
            $reqName = Decode $m.Groups[1].Value
            $info = Resolve-Item $reqName
            if ($info -and $info.tradeable) {
                $items["$($info.id)"] = @{ count = [int]$m.Groups[2].Value; name = $info.name }
            } elseif ($info) {
                $skipped += "$qid $qname -> $reqName ($($info.binding))"
            }
        }
    }

    if ($items.Count -gt 0) {
        $isLearned = $learned.ContainsKey($qid)
        $entries += @{ id = $qid; name = $qname; items = $items; learned = $isLearned;
                       faction = $(if ($isLearned) { $learned[$qid].faction } else { "" }) }
    }
}

# ---------------------------------------------------------------------------
# Write Lua
# ---------------------------------------------------------------------------
$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine('local _, ns = ...')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('-- GENERATED by tools/Build-QuestData.ps1 from Wowhead (Forever) data.')
[void]$sb.AppendLine('-- Rerun the script to add new quests; see the script header.')
[void]$sb.AppendLine('--')
[void]$sb.AppendLine('-- Existing entries are never changed by the script, so hand edits (e.g. adding')
[void]$sb.AppendLine('-- faction = "Horde") are safe as long as the line format below is kept.')
[void]$sb.AppendLine('--')
[void]$sb.AppendLine('--   [questID] = { name = "...", faction = "Alliance"|"Horde" (optional), items = {')
[void]$sb.AppendLine('--       [itemID] = count, -- item name')
[void]$sb.AppendLine('--   } },')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('ns.Quests = {')
foreach ($e in ($entries | Sort-Object { $_.id })) {
    $src = if ($e.learned) { " -- learned in-game" } else { "" }
    $fac = if ($e.faction -and $e.faction -notmatch ',') { ", faction = `"$($e.faction)`"" } else { "" }
    [void]$sb.AppendLine("    [$($e.id)] = { name = $(LuaStr $e.name)$fac, items = {$src")
    foreach ($itemId in $e.items.Keys) {
        $it = $e.items[$itemId]
        [void]$sb.AppendLine("        [$itemId] = $($it.count), -- $($it.name)")
    }
    [void]$sb.AppendLine("    } },")
}
[void]$sb.AppendLine('}')

[IO.File]::WriteAllText((Resolve-Path -LiteralPath (Split-Path $OutFile)).Path + "\" + (Split-Path $OutFile -Leaf), $sb.ToString(), [Text.UTF8Encoding]::new($false))

Write-Host "Wrote $($entries.Count) quests with tradeable items to $OutFile"
if ($skipped.Count) {
    Write-Host "`nSkipped (item not tradeable):"
    $skipped | ForEach-Object { Write-Host "  $_" }
}
