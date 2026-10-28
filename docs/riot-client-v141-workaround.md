# Legends of Runeterra on Linux: "Couldn't update" and the crashing Riot Client (October 2026)

> **Superseded:** the patched runner in this repository (`GE-Proton9-27-LoR1`, see the [README](../README.md)) fixes both problems without keeping an old client. This workaround remains as a fallback for setups that cannot switch runners.

A workaround for running Legends of Runeterra (LoR) through Wine/Proton when the Riot Client either refuses to start with "Couldn't update" or shows no window at all. Tested on 2026-10-27 with Bottles 67 (Flatpak, umu prefix), GE-Proton 9-27, AMD GPU (RADV). It should apply to any Wine prefix (Lutris, umu-run, plain Wine) with adjusted paths, but only the setup above was tested.

## Symptoms

1. A "COULDN'T UPDATE – Something went wrong with the update, even after repairing" dialog that keeps coming back until you reinstall the game.
2. Since about 2026-10-26: the Riot Client never shows a window (only a tray icon, or a black window), even right after a fresh install. LoR itself never starts.

## Cause 1: the Riot Client cannot update itself under Wine

Every few weeks Riot ships a new Riot Client. The client's in-place self-update fails under Wine. In `drive_c/users/<user>/AppData/Local/Riot Games/Riot Client/Logs/Launcher/*.log`:

```
Current install at 'C:/Riot Games/Riot Client' at release '9E948A83D7DDCAEE', but release '626519AF431D7214' available; updating
ERROR| Update failed: Failed getting path to current executable: File path could not be found in a mapped drive: \??\C:\Riot Games\Riot Client\RiotClientServices.exe
```

This is Wine bug [51687](https://bugs.winehq.org/show_bug.cgi?id=51687), open since 2021 (its status may have changed since). The failed attempt also deletes `ProgramData/Riot Games/Metadata/Riot Client/Riot Client.ok`, so every later launch tries the update again and fails. A reinstall used to "fix" it because the installer downloads the newest client directly instead of patching in place.

## Cause 2: Riot Client v142 (Electron 43) crashes on Wine 9

Riot Client v142.0.1 (release `626519AF431D7214`, around 2026-10-26) moved from Electron 22 to Electron 43.7.5 (Chromium 150). Its UI crashes on startup with exit code `2147483651` (`0x80000003`). The crash dump in `AppData/Roaming/riot-client-ux/Crashpad/reports/*.dmp` has these Crashpad annotations:

```
DelayLoad-ModuleName = USER32.dll
DelayLoad-LastError  = 127   (ERROR_PROC_NOT_FOUND)
```

The new client delay-loads three `user32.dll` functions that Wine 9 does not export:

| Function | GE-Proton 9-27 | UMU-Proton 10.0-4 | GE-Proton 11-9 / 11-11, Proton 11.0, Proton Experimental |
|---|---|---|---|
| `IsWindowArranged` | missing | present | present |
| `GetPointerDevice` | missing | missing | present |
| `GetPointerPenInfo` | missing | missing | present |

So newer Proton runs the new client, but in my test `LoR.exe` itself crashed on GE-Proton 11-11 before writing any log ("A critical error has occurred and the process must be terminated"). GE-Proton 9-27 is the version that runs the game. Other Proton 10.x builds were not tested.

Check which client you have:

```bash
strings "<prefix>/drive_c/Riot Games/Riot Client/RiotClientElectron/Riot Client.exe" | grep -o -m1 'Electron/[0-9.]*'
```

`Electron/22.x` works on GE-Proton 9-27. `Electron/43.x` crashes there.

## The workaround

Keep the old Riot Client v141 (Electron 22) and make the launcher believe it is already on the newest release, so it never starts the self-update.

The launcher decides whether to update only by comparing the release ID in `Riot Client.ok` with the newest release from Riot's config server. It checks the installed files against `Riot Client.db` by **size and modification time**, so the client files must be copied with their original timestamps (`cp -a` / `rsync -a`).

You need a copy of a Riot Client v141 install, taken from any LoR prefix installed before about 2026-10-26. I used v141.0.6.5101 (release `437BAC81A5BA755F`).

### 1. Make a backup of a working v141 client (once)

From a prefix where the old client still exists (game closed):

```bash
OLD="/path/to/old/prefix"
WINE_USER=steamuser
BACKUP="$HOME/Games/lor-riot-client-v141"

mkdir -p "$BACKUP/metadata"
cp -a "$OLD/drive_c/Riot Games/Riot Client" "$BACKUP/Riot Client"
cp -a "$OLD/drive_c/users/$WINE_USER/AppData/Roaming/Riot Client" "$BACKUP/profile"
cp -a "$OLD/drive_c/ProgramData/Riot Games/Metadata/Riot Client/Riot Client."{db,level,settings.yaml} "$BACKUP/metadata/"
curl -fsS -o "$BACKUP/metadata/Riot Client.manifest" https://ks-foundation.secure.dyn.riotcdn.net/channels/public/releases/437BAC81A5BA755F.manifest
```

Proton prefixes use the Wine user `steamuser`. Plain Wine uses your Linux user name. Replace `437BAC81A5BA755F` with your old client's release ID: it is in the old launcher logs (`Validated install ... at release '…'` or `Current install ... at release '…'`).

The `profile` folder matters: when Electron 22 starts with a profile last used by the new Electron 43, it shows only a black window. Deleting that folder instead of restoring an old one would probably also work (Electron creates a fresh profile), but I did not test it.

**No old prefix left?** The v141 files are probably still on Riot's CDN under the manifest above, and community tools such as [ManifestDownloader](https://github.com/Morilli/ManifestDownloader) can download releases from a manifest. I have not tested this, and the timestamps the launcher checks may not match a downloaded copy.

### 2. Repair script

Save as `~/.local/bin/lor-fix-client`, `chmod +x` it, and set `LOR_PREFIX` to the prefix that contains `drive_c`:

```bash
#!/usr/bin/env bash
set -euo pipefail

prefix="${LOR_PREFIX:?Set LOR_PREFIX to the Wine prefix that contains drive_c}"
backup="${LOR_CLIENT_BACKUP:-$HOME/Games/lor-riot-client-v141}"
wine_user="${LOR_WINE_USER:-steamuser}"
client="$prefix/drive_c/Riot Games/Riot Client"
metadata="$prefix/drive_c/ProgramData/Riot Games/Metadata/Riot Client"
profile="$prefix/drive_c/users/$wine_user/AppData/Roaming/Riot Client"
config_url='https://clientconfig.rpg.riotgames.com/api/v1/config/public?region=NA&os=windows&app=Riot%20Client&version=141.0.6.5101&patchline=KeystoneFoundationLiveWin&namespace=keystone.self_update'

if grep -qszF "WINEPREFIX=$prefix" /proc/[0-9]*/environ; then
  echo "Legends of Runeterra is still running. Stop it first." >&2
  exit 1
fi

manifest_url=$(curl -fsS "$config_url" | sed -n 's/.*"keystone.self_update.manifest_url":"\([^"]*\)".*/\1/p')

if [[ -z "$manifest_url" ]]; then
  echo "Could not read the latest Riot Client release from Riot." >&2
  exit 1
fi

if ! cmp -s "$backup/metadata/Riot Client.db" "$metadata/Riot Client.db"; then
  rsync -a --delete "$backup/Riot Client/" "$client/"
  rm -rf "$profile" "$metadata/Update"
  cp -a "$backup/profile" "$profile"
  cp -a "$backup/metadata/." "$metadata/"

  echo "Restored the backed-up Riot Client and its Electron profile."
fi

# The launcher only compares this release ID, so v141 files under the newest ID skip the self-update that breaks on GE-Proton 9-27.
printf '%s' "$manifest_url" > "$metadata/Riot Client.ok"

echo "Riot Client marked as ${manifest_url##*/}. Start Legends of Runeterra."
```

Example for a Bottles (Flatpak) umu game:

```bash
LOR_PREFIX="$HOME/.var/app/com.usebottles.bottles/data/bottles/umu/prefixes/<game-id>" lor-fix-client
```

What it does:

- Refuses to run while anything in the prefix is running.
- Reads the newest release URL from Riot's public config endpoint.
- If the installed client is not the backed-up one (for example, v142 got installed), restores the client files, the matching metadata and the Electron 22 profile.
- Writes the newest release URL into `Riot Client.ok`.

It is safe to run repeatedly. On an already fixed prefix it only rewrites `Riot Client.ok`.

### 3. Use

Start the game as usual. Whenever "Couldn't update" or a missing window comes back (a new Riot Client release, or the client's background updater deleting `Riot Client.ok` again): stop the game, run `lor-fix-client`, start again. No reinstall needed.

To check it worked: the newest file in `AppData/Local/Riot Games/Riot Client/Logs/Launcher/` should contain `Validated install at 'C:/Riot Games/Riot Client' at release '…'; skipping update`.

## What did not work

- **Reinstalling:** a fresh install now downloads client v142, which crashes on GE-Proton 9-27.
- **`--launcher-disable-self-update`:** the launcher still updated.
- **`enable_self_update: false` in `C:/Riot Games/Riot Client/system.yaml`:** the launcher still updated. Editing the file also makes it fail verification (size and timestamp), unless both are kept identical.
- **Newer Proton (GE-Proton 11-11):** the Riot Client works, but `LoR.exe` crashes on start.

## Gotchas

- **Language reset:** running the Riot installer again (for example with `--skip-to-install`) resets the game language to `en_US`. Change it back in the Riot Client: profile icon → Settings → Legends of Runeterra → Language. The client then downloads that language's files.
- **Bottles launch arguments:** Bottles game arguments are passed literally. `%command%` (Steam/Lutris syntax) ends up as a plain argument to `LoR.exe`. It is harmless but does nothing.
- **Running the installer in an existing prefix** updates only the Riot Client (a few seconds) without re-downloading the game, which was useful before v142. With v142 it installs the crashing client.

## Limits

This works only as long as Riot's servers accept the v141 client. When they stop, the remaining option is a Proton build that runs both the game and the new client. As of 2026-10-27 I did not find one: GE-Proton 9-27 runs the game but not the client, GE-Proton 11-11 the other way round. If you find a version that runs both, or a fix for LoR on newer Proton, please share it.
