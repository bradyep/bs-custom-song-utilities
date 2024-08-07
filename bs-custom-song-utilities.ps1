param ($bsdir, $task)

function Test-Paths {
    param([string]$PlaylistDirectory, [string]$PlayerDataPath, [string]$SongHashDataPath, [string]$CustomLevelsPath)

    foreach ($path in $PSBoundParameters.GetEnumerator()) {
        if (Test-Path -Path $path.Value) {
            Write-Host $path.Key "exists at: " $path.Value
        }
        else {
            Write-Host $path.Key "does NOT exist at: " $path.Value

            return $false
        }
    }

    return $true
}

function Get-PlayListSongHashes {
    $playlists = Get-ChildItem -Path $pldir -Filter *.bplist -Recurse -File -Name
    $playlistsMeasure = $playlists | Measure-Object
    $playListCount = $playlistsMeasure.Count

    Write-Host "Found this many playlists:" $playListCount
    if ($playListCount -lt 1) { 
        Write-Host "No playlists found. Too risky; exiting out." 
        Exit
    }

    $playlist_songs = @()

    $playlists | ForEach-Object {
        $playlist = $_
        $bplistdir = $pldir + "\" + $playlist
        Write-Host "Processing:" $bplistdir
        
        $jsonData = Get-Content -Path $bplistdir | ConvertFrom-Json
        Write-Host "Found this many songs:" $jsonData.songs.Count
        $jsonData.songs | ForEach-Object {
            $song = $_
            $playlist_songs += $song.hash
        }
    }

    Write-Host "Total number of songs from playlists to preserve:" $playlist_songs.Length

    return $playlist_songs
}

function Get-FavoritesSongHashes {
    $favorites_songs = @()

    $jsonData = Get-Content -Path $player_data_path | ConvertFrom-Json
    if ($jsonData.localPlayers.favoritesLevelIds.Length -lt 1) {
        Write-Host "No favorites found. Too risky; exiting out." 
        Exit
    }
    Write-Host "Found this many songs in Favorites:" $jsonData.localPlayers.favoritesLevelIds.Length
    $jsonData.localPlayers.favoritesLevelIds | ForEach-Object {
        $favorites_songs += $_ -replace 'custom_level_', ''
    }

    return $favorites_songs
}

function Get-SongHashTable {
    param([string]$SongHashDataPath)

    $rawData = Get-Content -Path $SongHashDataPath
    $isValid = $rawData | Test-Json
    Write-Host "[Get-SongHashTable] Test-Json:" $isValid

    $songHashTable = @{}
    $jsonData = $rawData | ConvertFrom-Json
    foreach ($elem in $jsonData.PsObject.Properties) {
        $songDir = $elem.Name -replace '.*\\'
        $songHashTable[$elem.VALUE.songHash] = $songDir
        Write-Host "[Get-SongHashTable] Added to songHashTable:" $elem.VALUE.songHash " | " $songDir
    }
    
    if ($songHashTable.Count -lt 1) {
        Write-Host "Could not find any songs in SongHashData.dat. Too risky to proceed. Exiting out."
        Exit
    }

    return $songHashTable
}

function Remove-UnlistedSongs {
    param([Bool]$removeSongs)

    Write-Host "Actually remove songs?" $removeSongs
    $all_songs_to_save = $(Get-PlayListSongHashes; Get-FavoritesSongHashes) | Select-Object -Unique 
    "Added this many unique hashes to NOT be deleted: " + $all_songs_to_save.Length
    $songHashTable = Get-SongHashTable $shd_path
    Write-Host "songHashTable item count:" $songHashTable.Count

    $songsNotInHashTable = 0; $savedSongs = 0; $deletedSongs = 0
    
    # Loop through all custom song folders
    $custom_song_dirs = Get-ChildItem -LiteralPath $cldir -Directory -Depth 1
    ForEach ($custom_song_dir in $custom_song_dirs) {
        # Get the BeatSaver code
        $pos = $custom_song_dir.Name.IndexOf(" (")
        $beatSaverCode = $custom_song_dir.Name.Substring(0, $pos)
        # Write-Host "BeatSaver code: [$beatSaverCode]"
        # Use BeatSaver code to find entry in songHashTable
        $subString = $beatSaverCode + " ("
        # Write-Host "Using substring:" $subString
        $matchInSongHashTable = $songHashTable.GetEnumerator() | Where-Object { $_.Value -like "$subString*" } | Select-Object -first 1
        if ($matchInSongHashTable) {
            # Write-Host "Found matching song in Song Hash Table. Key ["$matchInSongHashTable.Key"] | Value: ["$matchInSongHashTable.Value"]"
            if ($all_songs_to_save.Contains($matchInSongHashTable.Key)) {
                $savedSongs++
                Write-Host "SAVE:" $matchInSongHashTable.Value
            }
            else {
                $deletedSongs++
                Write-Host "DELETE:" $matchInSongHashTable.Value
            }
        }
        else {
            $songsNotInHashTable++
            Write-Host "Did NOT find matching song in Song Hash Table. Do NOT delete. | " $custom_song_dir.Name
        }
    }

    Write-Host "`n### Summary ###"
    Write-Host "Songs Not Found in SongHashData.dat: $songsNotInHashTable | Songs Saved: $savedSongs | Songs Deleted: $deletedSongs"
}

# Main Script Code
"# Beat Saber Custom Song File Utilities #"
"paramers supplied: [" + $PSBoundParameters.Keys + "] [" + $PSBoundParameters.Values + "]"

if ($PSBoundParameters.ContainsKey('bsdir')) {
    $wd = $bsdir
}
else {
    $wd = Get-Location | Convert-Path
}

"Working Directory: " + $wd
$pldir = $wd + "\Playlists"
$player_data_path = "$env:USERPROFILE\AppData\LocalLow\Hyperbolic Magnetism\Beat Saber\PlayerData.dat"
$shd_path = $wd + "\UserData\SongCore\SongHashData.dat"
$cldir = $wd + "\Beat Saber_Data\CustomLevels"

if ("info", "clean", "backup" -contains $task) {
    if (!(Test-Paths $pldir $player_data_path $shd_path $cldir)) {
        Write-Host "Couldn't find an important directory or file. Too risky to proceed. Exiting out."
        Exit
    }
}

switch ($task) {
    "info" {
        "## Performing Task: Info ##"
        Remove-UnlistedSongs $false

        Break
    }
    "clean" {
        "## Performing Task: Clean up custon songs not in playlist or favorites ##"
        Break
    }
    "backup" {
        "## Performing Task: Backing up playlists and favorites ##"
        Break
    }
    Default {
        "## show readme ##"
    }
}
