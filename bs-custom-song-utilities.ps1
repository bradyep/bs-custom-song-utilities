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

<#
    Accepts a playlist directory and returns an array of song hashes (type: string) found in all playlists
#>
function Get-PlayListSongHashes {
    param($directory)

    $playlists = Get-ChildItem -Path $directory -Filter *.bplist -Recurse -File -Name
    $playListCount = ($playlists | Measure-Object).Count

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
            $playlist_songs += $_.hash
        }
    }

    Write-Host "Total number of songs from playlists to preserve:" $playlist_songs.Length

    return $playlist_songs
}

<#
    Accepts a player data file path and returns an array of song hashes (type: string) found in favorites list
#>
function Get-FavoritesSongHashes {
    param($pdFilePath)

    $favorites_songs = @()
    $jsonData = Get-Content -Path $pdFilePath | ConvertFrom-Json
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
    Write-Host "[Get-SongHashTable] Test-Json:" ($rawData | Test-Json)

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

function Get-DirectorySizeInBytes {
    param($directory)

    $dirObject = $directory | Get-ChildItem | Measure-Object -Sum Length | Select-Object `
    @{Name = ”Size”; Expression = { $_.Sum } }

    return $dirObject.Size
}

function Remove-UnlistedSongs {
    param([Bool]$removeSongs, [string]$playlistDir, [string]$playerDataPath, [string]$songHashDataPath, [string]$customLevelsPath)

    Write-Host "Actually remove songs?" $removeSongs
    $all_songs_to_save = $(Get-PlayListSongHashes($playlistDir); Get-FavoritesSongHashes($playerDataPath)) | Select-Object -Unique
    "Added this many unique hashes to NOT be deleted: " + $all_songs_to_save.Length
    $songHashTable = Get-SongHashTable $songHashDataPath
    Write-Host "songHashTable item count:" $songHashTable.Count

    $songsNotInHashTable = 0; $savedSongs = 0; $deletedSongs = 0; $bytesToDelete = 0; $bytesToSave = 0
    # Loop through all custom song folders
    $custom_song_dirs = Get-ChildItem -LiteralPath $customLevelsPath -Directory -Depth 1
    ForEach ($custom_song_dir in $custom_song_dirs) {
        # Get the BeatSaver code
        $beatSaverCode = $custom_song_dir.Name.Substring(0, $custom_song_dir.Name.IndexOf(" ("))
        # Write-Host "BeatSaver code: [$beatSaverCode]"
        # Use BeatSaver code to find entry in songHashTable
        $subString = $beatSaverCode + " ("
        # Write-Host "Using substring:" $subString
        $matchInSongHashTable = $songHashTable.GetEnumerator() | Where-Object { $_.Value -like "$subString*" } | Select-Object -first 1
        if ($matchInSongHashTable) {
            # Write-Host "Found matching song in Song Hash Table. Key ["$matchInSongHashTable.Key"] | Value: ["$matchInSongHashTable.Value"]"
            if ($all_songs_to_save.Contains($matchInSongHashTable.Key)) {
                Write-Host "SAVE:" $matchInSongHashTable.Value
                $bytesToSave += Get-DirectorySizeInBytes $custom_song_dir
                $savedSongs++
            }
            else {
                Write-Host "DELETE:" $matchInSongHashTable.Value
                $bytesToDelete += Get-DirectorySizeInBytes $custom_song_dir
                $deletedSongs++
            }
        }
        else {
            Write-Host "Did NOT find matching song in Song Hash Table. Do NOT delete. | " $custom_song_dir.Name
            $bytesToSave += Get-DirectorySizeInBytes $custom_song_dir
            $songsNotInHashTable++
        }
    }

    Write-Host "`n### Summary ###"
    $gigabytesToDelete = [Math]::Round($bytesToDelete / 1Gb, 3)
    $gigabytesToSave = [Math]::Round($bytesToSave / 1Gb, 3)
    Write-Host "Songs Not Found in SongHashData.dat: $songsNotInHashTable | Songs Saved: $savedSongs | Songs Deleted: $deletedSongs | GB deleted: $gigabytesToDelete | GB NOT deleted: $gigabytesToSave"
}

function Backup-PlaylistsAndFavorites {
    param([string]$playlistDir, [string]$playerDataPath, [string]$songHashDataPath)

    # Generate backup content from favorites
    $songHashTable = Get-SongHashTable $songHashDataPath
    $faveSongHashes = Get-FavoritesSongHashes($playerDataPath)
    $playerFavoritesPlaylist = @()

    ForEach ($faveSongHash in $faveSongHashes) {
        $matchInSongHashTable = $songHashTable.GetEnumerator() | Where-Object { $_.Key -like $faveSongHash }
        if ($matchInSongHashTable) { 
            $matchingSongValue = $matchInSongHashTable.Value
            $songNameStartPos = $matchingSongValue.IndexOf(" (")
            $realSongStartPosition = $songNameStartPos + 2
            $songNameEndPos = (($matchingSongValue).Length - $realSongStartPosition) - 1
            $beatSaverCode = $matchingSongValue.Substring(0, $songNameStartPos)
            
            $songName = $matchingSongValue.Substring($realSongStartPosition, $songNameEndPos)
            # Write-Host "Found match | bsr: [$beatSaverCode] | songNameStartPos: [$songNameStartPos] | songNameEndPos: [$songNameEndPos] | songName: [$songName] | matchingSongValue: [$matchingSongValue]"
            $stringToAdd = "[$songName](https://beatsaver.com/maps/$beatSaverCode)"
            Write-Host "Adding: $stringToAdd"
            $playerFavoritesPlaylist += $stringToAdd
        } 
        else {
            Write-Host "Could not find match for hash:" $faveSongHash
        }
    }

    $playlistsToBackup = @{}
    $playlistsToBackup['player-favorites'] = $playerFavoritesPlaylist

    # Generate backup content from playlists
    $playlists = Get-ChildItem -Path $playlistDir -Filter *.bplist -Recurse -File -Name
    $playListCount = ($playlists | Measure-Object).Count
    Write-Host "Found this many playlists:" $playListCount

    $playlists | ForEach-Object {
        $playlistSongs = @()
        $playlist = $_
        $bplistdir = $pldir + "\" + $playlist
        $jsonData = Get-Content -Path $bplistdir | ConvertFrom-Json
        $playlistName = $jsonData.playlistTitle
        Write-Host "Processing: $playlistName | Location:" $bplistdir        
        Write-Host "Found this many songs:" $jsonData.songs.Count
        $jsonData.songs | ForEach-Object {
            $key = $_.key
            $songName = $_.songName
            $stringToAdd = "[$songName](https://beatsaver.com/maps/$key)"
            Write-Host "Adding: $stringToAdd"
            $playlistSongs += $stringToAdd
        }

        $playlistsToBackup[$playlistName] = $playerFavoritesPlaylist
    }
    # Write $playlistsToBackup to a .md file
    
}

# Main Script Code
"# Beat Saber Custom Song File Utilities #"
"paramers supplied: [" + $PSBoundParameters.Keys + "] [" + $PSBoundParameters.Values + "]"

$wd = ($PSBoundParameters.ContainsKey('bsdir')) ? $bsdir : (Get-Location | Convert-Path)
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
        Remove-UnlistedSongs $false $pldir $player_data_path $shd_path $cldir

        Break
    }
    "clean" {
        "## Performing Task: Clean up custon songs not in playlist or favorites ##"
        Remove-UnlistedSongs $true $pldir $player_data_path $shd_path $cldir

        Break
    }
    "backup" {
        "## Performing Task: Backing up playlists and favorites ##"
        Backup-PlaylistsAndFavorites $pldir $player_data_path $shd_path
        
        Break
    }
    Default {
        "## show readme ##"
    }
}
