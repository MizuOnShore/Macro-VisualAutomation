# Macro for Windows

This is the native Windows port of Macro. It uses WinForms and the Windows API directly—there is no browser, Electron runtime, or separate background service.

## Requirements

- Windows 10 version 1903 or newer, or Windows 11
- .NET 8 SDK to build from source
- The published application is self-contained and does not require .NET on the destination computer

## Run from source

```powershell
cd WindowsApp
dotnet run --project .\Macro.Windows\Macro.Windows.csproj
```

## Build distributable `.exe` files

```powershell
cd WindowsApp
.\build-windows.ps1
```

The script runs the portable test suite, then creates single-file x64 and ARM64 applications under `WindowsApp\artifacts`.

## Features

- Create, rename, duplicate, delete, reorder, import, and export macros
- Record global keyboard, mouse, drag, movement, and wheel input after a three-second countdown
- Enumerate visible top-level application windows and select an exact target
- Background playback with per-window messages
- Compatibility playback with foreground activation and Windows `SendInput`
- Run once, repeat-count, and infinite playback; pause, resume, stop, progress, and held-input cleanup
- Visual automation workflows with macros, waits, window waits, conditions, schedules, repeats, loop-backs, merges, timers, and stop nodes
- Atomic JSON persistence with last-known-good backup files
- Global F6 record, F7 stop, and F8 play hotkeys
- Per-run logs and diagnostic test input

Macro data is stored in `%LOCALAPPDATA%\Macro`. The field names and enum values match the macOS JSON format, so exported macro files can be moved between the two editions. Windows targets use process names where the macOS edition uses bundle identifiers.

## Input behavior

Background mode sends keyboard and mouse window messages without moving focus. This works for standard Windows controls and applications that process those messages. Games and software using Raw Input, DirectInput, or anti-cheat systems may ignore background messages.

Compatibility mode restores and activates the selected window, moves the system cursor for mouse actions, and sends input through `SendInput`. It is more broadly compatible, but it takes focus and uses the physical cursor.

Windows only confirms that an input API accepted an event; it cannot prove that the target acted on it. The UI therefore describes diagnostic actions as “posted” rather than “received.” Macro does not bypass anti-cheat, elevation boundaries, or other application security controls. To automate an elevated target, Macro must be launched at the same integrity level.
