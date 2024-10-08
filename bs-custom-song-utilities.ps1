param ($bsdir, $task, [switch]$verbose = $false)

function Test-Paths {
    param([string]$PlaylistDirectory, [string]$PlayerDataPath, [string]$SongHashDataPath, [string]$CustomLevelsPath)

    foreach ($path in $PSBoundParameters.GetEnumerator()) {
        if (Test-Path -Path $path.Value) {
            if ($verbose) { Write-Host $path.Key "exists at: " $path.Value }
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
        if ($verbose) { Write-Host "Processing:" $bplistdir }
        $jsonData = Get-Content -Path $bplistdir | ConvertFrom-Json
        if ($verbose) { Write-Host "Found this many songs:" $jsonData.songs.Count }
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
    if ($verbose) { Write-Host "[Get-SongHashTable] Test-Json:" ($rawData | Test-Json) }

    $songHashTable = @{}
    $jsonData = $rawData | ConvertFrom-Json
    foreach ($elem in $jsonData.PsObject.Properties) {
        $songDir = $elem.Name -replace '.*\\'
        $songHashTable[$elem.VALUE.songHash] = $songDir
        if ($verbose) { Write-Host "[Get-SongHashTable] Added to songHashTable:" $elem.VALUE.songHash " | " $songDir }
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

    if ($verbose) { Write-Host "Actually remove songs?" $removeSongs }
    $all_songs_to_save = $(Get-PlayListSongHashes($playlistDir); Get-FavoritesSongHashes($playerDataPath)) | Select-Object -Unique
    Write-Host "Added this many unique songs to NOT be deleted:" $all_songs_to_save.Length
    $songHashTable = Get-SongHashTable $songHashDataPath
    if ($verbose) { Write-Host "songHashTable item count:" $songHashTable.Count }

    $songsNotInHashTable = 0; $savedSongs = 0; $deletedSongs = 0; $bytesToDelete = 0; $bytesToSave = 0
    # Loop through all custom song folders
    $custom_song_dirs = Get-ChildItem -LiteralPath $customLevelsPath -Directory -Depth 1
    ForEach ($custom_song_dir in $custom_song_dirs) {
        # Get the BeatSaver code
        $beatSaverCode = $custom_song_dir.Name.Substring(0, $custom_song_dir.Name.IndexOf(" ("))
        # Use BeatSaver code to find entry in songHashTable
        $subString = $beatSaverCode + " ("
        $matchInSongHashTable = $songHashTable.GetEnumerator() | Where-Object { $_.Value -like "$subString*" } | Select-Object -first 1
        if ($matchInSongHashTable) {
            if ($all_songs_to_save.Contains($matchInSongHashTable.Key)) {
                if ($verbose) { Write-Host "SAVE:" $matchInSongHashTable.Value }
                $bytesToSave += Get-DirectorySizeInBytes $custom_song_dir
                $savedSongs++
            }
            else {
                if ($verbose) { Write-Host "DELETE:" $matchInSongHashTable.Value }
                $bytesToDelete += Get-DirectorySizeInBytes $custom_song_dir
                if ($removeSongs -eq $true) { Remove-Item -LiteralPath $custom_song_dir -Force -Recurse }
                $deletedSongs++
            }
        }
        else {
            if ($verbose) { Write-Host "Did NOT find matching song in Song Hash Table. Do NOT delete. | " $custom_song_dir.Name }
            $bytesToSave += Get-DirectorySizeInBytes $custom_song_dir
            $songsNotInHashTable++
        }
    }

    $removeSongsSummary = @{}
    $removeSongsSummary["songsNotInHashTable"] = $songsNotInHashTable
    $removeSongsSummary["savedSongs"] = $savedSongs
    $removeSongsSummary["deletedSongs"] = $deletedSongs
    $removeSongsSummary["gigabytesToDelete"] = [Math]::Round($bytesToDelete / 1Gb, 3)
    $removeSongsSummary["gigabytesToSave"] = [Math]::Round($bytesToSave / 1Gb, 3)

    return $removeSongsSummary
}

function Backup-PlaylistsAndFavorites {
    param([string]$playlistDir, [string]$playerDataPath, [string]$songHashDataPath)

    # Generate backup content from favorites
    $songHashTable = Get-SongHashTable $songHashDataPath
    $faveSongHashes = Get-FavoritesSongHashes($playerDataPath)
    $playerFavoritesPlaylist = @()
    $playerFavoritesPlaylist += "# Beat Saber Custom Song Backup"
    $playerFavoritesPlaylist += "`n## Favorites"

    ForEach ($faveSongHash in $faveSongHashes) {
        $matchInSongHashTable = $songHashTable.GetEnumerator() | Where-Object { $_.Key -like $faveSongHash }
        if ($matchInSongHashTable) { 
            $matchingSongValue = $matchInSongHashTable.Value
            $songNameStartPos = $matchingSongValue.IndexOf(" (")
            $realSongStartPosition = $songNameStartPos + 2
            $songNameEndPos = (($matchingSongValue).Length - $realSongStartPosition) - 1
            $beatSaverCode = $matchingSongValue.Substring(0, $songNameStartPos)
            
            $songName = $matchingSongValue.Substring($realSongStartPosition, $songNameEndPos)
            $stringToAdd = "* [$songName](https://beatsaver.com/maps/$beatSaverCode)"
            if ($verbose) { Write-Host "Adding: $stringToAdd" }
            $playerFavoritesPlaylist += $stringToAdd
        }
        else {
            Write-Host "Could not find match for hash:" $faveSongHash
        }
    }

    $playlistsToBackup = [ordered]@{}
    $playlistsToBackup['player-favorites'] = $playerFavoritesPlaylist

    # Generate backup content from playlists
    $playlists = Get-ChildItem -Path $playlistDir -Filter *.bplist -Recurse -File -Name
    $playListCount = ($playlists | Measure-Object).Count
    Write-Host "Found this many playlists:" $playListCount

    $playlists | ForEach-Object {
        $playlist = $_
        $bplistdir = $pldir + "\" + $playlist
        $jsonData = Get-Content -Path $bplistdir | ConvertFrom-Json

        $playlistName = $jsonData.playlistTitle
        $playlistSongs = @()
        $playlistSongs += "`n## $playlistName"
        if ($verbose) { Write-Host "Processing: $playlistName | Location:" $bplistdir }
        if ($verbose) { Write-Host "Found this many songs:" $jsonData.songs.Count }
        $jsonData.songs | ForEach-Object {
            $songHash = $_.hash

            # We might not be able to get the key/bsr from certain playlists, so try to grab it from songHashTable
            $matchInSongHashTable = $songHashTable.GetEnumerator() | Where-Object { $_.Key -like $songHash }
            if ($matchInSongHashTable) { 
                $matchingSongValue = $matchInSongHashTable.Value
                $songNameStartPos = $matchingSongValue.IndexOf(" (")
                $beatSaverCode = $matchingSongValue.Substring(0, $songNameStartPos)
                $key = $beatSaverCode
            }
            else {
                $key = $_.key
            }

            $songName = $_.songName
            $stringToAdd = "* [$songName](https://beatsaver.com/maps/$key)"
            if ($verbose) { Write-Host "Adding: $stringToAdd" }
            $playlistSongs += $stringToAdd
        }

        $playlistsToBackup[$playlistName] = $playlistSongs
    }
    # Write $playlistsToBackup to a .md file
    $backupFileName = "bs-custom-song-backup-" + (Get-Date -Format "yyyy-MM-dd").ToString() + ".md"
    Write-Host "File name:" $backupFileName
    $stringToWrite = ""
    foreach ($pl in $playlistsToBackup.GetEnumerator()) {
        foreach ($song in $pl.value) {
            if ($verbose) { Write-Host "Writing: $song" }
            $stringToWrite += $song + "`n"
        }
    }
    $stringToWrite | Out-File -FilePath .\$backupFileName
}

# Main Script Code
if ($verbose) { "paramers supplied: [" + $PSBoundParameters.Keys + "] [" + $PSBoundParameters.Values + "]" }
$wd = ($PSBoundParameters.ContainsKey('bsdir')) ? $bsdir : (Get-Location | Convert-Path)
if ($verbose) { "Working Directory: " + $wd }
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
        $summary = Remove-UnlistedSongs $false $pldir $player_data_path $shd_path $cldir
        Write-Host "`n### Summary ###"
        Write-Host "Songs not found in SongHashData.dat:" $summary.songsNotInHashTable "| Songs to be saved:" $summary.savedSongs "| Songs to be deleted:" $summary.deletedSongs "| GB to be deleted:" $summary.gigabytesToDelete "| GB to NOT be deleted:" $summary.gigabytesToSave

        Break
    }
    "clean" {
        "## Performing Task: Clean up custom songs not in playlist or favorites ##"
        $prompt = Read-Host "WARNING: This will delete any custom songs you have that are not in a playlist or in your favorites. You should probably run this script with -task info first to see what will be deleted. Do you still want to proceed? [Type 'yes' without quotes to proceed]"
        if ($prompt.ToLower() -ne "yes") { Exit }
        $summary = Remove-UnlistedSongs $true $pldir $player_data_path $shd_path $cldir
        Write-Host "`n### Summary ###"
        Write-Host "Songs Not Found in SongHashData.dat:" $summary.songsNotInHashTable "| Songs Saved:" $summary.savedSongs "| Songs Deleted:" $summary.deletedSongs "| GB deleted:" $summary.gigabytesToDelete "| GB NOT deleted:" $summary.gigabytesToSave

        Break
    }
    "backup" {
        "## Performing Task: Backing up playlists and favorites ##"
        Backup-PlaylistsAndFavorites $pldir $player_data_path $shd_path
        
        Break
    }
    Default {
        Write-Host "You will need to know where Beat Saber is installed on your machine. For example on my machine its 

G:\Games\Steam\steamapps\common\Beat Saber

Include this path in quotes after the bsdir parameter - see examples below. Alternatively you can just copy the bs-custom-song-utilities.ps1 script into that directory and run it there without any bsdir parameter.

To backup all of your favorites and playlist songs to a markdown file, supply backup to the task parameter like this:

.\bs-custom-song-utilities.ps1 -bsdir 'G:\Games\Steam\steamapps\common\Beat Saber' -task backup

This will create a markdown file (extension .md) wherever you ran the script from. Markdown files are just text but you can view them neatly formatted with working links in something like Visual Studio Code. 

To get an overview of what would happen if you were to run the clean option (delete all custom songs not in favorites or a playlist) **without** actually deleting anything, supply info to the task parameter:

.\bs-custom-song-utilities.ps1 -bsdir 'G:\Games\Steam\steamapps\common\Beat Saber' -task info

To actually delete all of your custom songs not in favorites or in a playlist, supply clean to the task parameter:

.\bs-custom-song-utilities.ps1 -bsdir 'G:\Games\Steam\steamapps\common\Beat Saber' -task clean

If you want to nerd it up and get more information while the script runs, simply add the -verbose argument. Its just a switch and does not need any parameters supplied to it. Ex:

.\bs-custom-song-utilities.ps1 -bsdir 'G:\Games\Steam\steamapps\common\Beat Saber' -task info -verbose
"
    }
}
