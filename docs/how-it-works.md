# How GE-Proton9-27-LoR works

Technical background for [GE-Proton9-27-LoR1](../README.md): why Legends of Runeterra broke on Linux in October 2026, what the patches change, and how the runner is built.

## The two problems

### 1. "Couldn't update" on every Riot Client release

The Riot Client updates itself every few weeks. Under Wine the update always failed:

```
ERROR| Update failed: Failed getting path to current executable: File path could not be found in a mapped drive: \??\C:\Riot Games\Riot Client\RiotClientServices.exe
```

Windows returns mapped file names as `\Device\HarddiskVolumeN\...`, which the updater matches against `QueryDosDevice`. Wine returns `\??\C:\...`, so the match fails ([Wine bug 51687](https://bugs.winehq.org/show_bug.cgi?id=51687), open since 2021). The failed attempt also deletes `Riot Client.ok`, so the error comes back on every launch until you reinstall.

### 2. Riot Client v142 shows no window

Riot Client v142 (release `626519AF431D7214`, about 2026-10-26) moved from Electron 22 to Electron 43 (Chromium 150). Its window crashes on start with exit code `2147483651`; the crash dump says `DelayLoad-ModuleName = USER32.dll`, `DelayLoad-LastError = 127`. The new client loads functions that the Wine in GE-Proton 9-27 does not have. A fresh install gets the same client, so reinstalling does not help.

Newer Proton versions have these functions, but LoR itself crashed on GE-Proton 11-11 in testing, so the fix keeps GE-Proton 9-27 and adds only what is missing.

## What the patches change

| Patch | DLL | Change |
|---|---|---|
| `0001` | `user32` | Adds `GetPointerDevice`, `GetPointerPenInfo` (pen and touch input) and `IsWindowArranged` (window snapping state). They report "not available" / "not arranged". |
| `0002` | `uiautomationcore` | Adds `UiaDisconnectAllProviders` (accessibility clean-up), which reports success. |
| `0003` | `combase`, `ole32` | Replaces the crashing `RoGetAgileReference` stub with one that returns `E_NOTIMPL`, and exports it from `ole32` too. |
| `0004` | `kernelbase` | `GetMappedFileNameW` returns `\Device\HarddiskVolumeN\...` like Windows does. Fixes problem 1. |

Only these five DLLs are rebuilt, from the exact Wine source of GE-Proton 9-27 with all of GE's patches applied. Every other file of the runner is the original GE-Proton 9-27. On the first start Proton logs `Upgrading prefix from GE-Proton9-27 to GE-Proton9-27-LoR1` and copies the patched DLLs into the prefix; switching back to GE-Proton9-27 copies the originals back.

## Build

`./build.sh` (Docker, git, curl, about 4 GB of disk) does three steps:

1. `scripts/prepare-wine.sh` clones `proton-ge-custom` at tag `GE-Proton9-27`, fetches its `wine` and `wine-staging` submodules, runs the Wine part of GE's `patches/protonprep-valve-staging.sh` unchanged, then applies `patches/*.patch`.
2. `scripts/build-dlls.sh` regenerates Wine's build files the way GE's build does, configures a 64-bit MinGW build and compiles only the five DLLs.
3. `build.sh` copies GE-Proton9-27 (downloaded and checksum-verified, or `--base <dir>`), replaces the five DLLs in `files/lib64/wine/x86_64-windows`, renames the runner (`CURRENT_PREFIX_VERSION`, `version`, `compatibilitytool.vdf`) and packs it into `dist/`.

GE's own patch for Vanguard: Saga of Heroes passes a wide string to `GetEnvironmentVariableA`. GE's older compiler only warned about it; GCC 14 treats it as an error, so the build turns `incompatible-pointer-types`, `int-conversion` and `implicit-function-declaration` back into warnings. The affected code is compiled the same way as in GE's release.

## Checking a new Riot Client version

`tools/check-imports.py` lists every function the Riot Client loads that a runner does not provide:

```bash
tools/check-imports.py "<prefix>/drive_c/Riot Games/Riot Client" /path/to/GE-Proton9-27-LoR1
```

Output for client 142.0.1.5150 on this runner:

```
riot client.exe     delay  ADVAPI32.dll       AddConditionalAce
riot client.exe     delay  USERENV.dll        DeriveAppContainerSidFromAppContainerName
riotgamesapi.dll    delay  ACLSDK.dll         <whole DLL missing>
riotgamesapi.dll    delay  GCloudVoice.dll    <whole DLL missing>
```

These four are also missing in GE-Proton 11, where the client works, so they are never called (Chromium sandbox functions and China-only voice SDKs). Anything new in that list is a candidate for the next patch. A `delay` import only crashes when it is first called; a missing normal `import` stops the program from starting at all.

## Fallback without this runner

`scripts/lor-fix-client` keeps an old Riot Client v141 (Electron 22) and marks it as the newest release so the launcher skips updating. It needs a backup of a v141 install and stops working once Riot's servers reject v141. See [riot-client-v141-workaround.md](riot-client-v141-workaround.md).

## Limits

- The added functions are placeholders. If a future Riot Client actually depends on pen input, window snapping information or agile references, it needs real implementations.
- LoR itself crashed on GE-Proton 11-11 in a single test. Other Proton 10.x and 11.x builds were not tested.
- Riot can change the client again at any time; `tools/check-imports.py` shows quickly whether a runner still covers it.
