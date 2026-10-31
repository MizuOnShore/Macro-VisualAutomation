# Macro

Macro now includes native editions for both platforms:

- **macOS 14+** — the original SwiftUI application in `MacroApp`
- **Windows 10/11** — the WinForms application in [`WindowsApp`](WindowsApp/README.md)

The editions share a compatible JSON macro format. Platform target identifiers differ: macOS stores bundle identifiers, while Windows stores process names in the same optional field.

## Download for Windows

[**Download the latest Windows x64 release**](https://github.com/MizuOnShore/Macro-VisualAutomation/releases/latest/download/Macro-Windows-x64.zip)

Unzip `Macro-Windows-x64.zip`, then run `Macro.exe`. The application is self-contained and does not require a separate .NET installation.

> **Windows notice:** The executable is not code-signed yet, so Microsoft SmartScreen may display an “unrecognized app” warning. Review the source in this repository and build it yourself if preferred.

See [WindowsApp/README.md](WindowsApp/README.md) for features, limitations, and build instructions.

## macOS edition

Macro is a native SwiftUI window-targeted automation utility for macOS 14+. It can build timed keyboard and mouse sequences, post experimental Quartz events to one selected process, record global input without blocking it, and persist macros as JSON.

## Build and run

1. Open `Macro.xcodeproj` in Xcode 27.2 or newer.
2. Select the **Macro** scheme and **My Mac** destination.
3. Press **⌘R**.
4. Open **Macro → Settings… → Permissions**.
5. Grant Accessibility for automation. Grant Input Monitoring for recording and the global Escape stop.
6. Quit and rerun Macro if macOS does not update a permission immediately.

The project builds successfully for Apple Silicon with Xcode 27.2 (27B52):

```sh
xcodebuild -project Macro.xcodeproj \
  -scheme Macro \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Using a macro

1. Keep the target window visible, open **Target**, and click **Refresh**.
2. Highlight the desired window and click **Select Highlighted Window**.
3. Use **Send Test Input** before running a sequence. “Posted” means macOS accepted the event; it does not prove the target consumed it.
4. Open **Macros**, select or create a macro, and add actions.
5. Expand an action to edit its key, duration, delay, or coordinates.
6. Choose Run Once, Repeat, or Infinite and click **Play**.
7. Use **Pause**, **Stop**, or press **Escape** for the emergency stop.

Macro releases all automation-held keys and mouse buttons on stop, error, target termination, and app termination.



## JSON storage

The library autosaves to `~/Library/Application Support/Macro/Macros.json`. The macro menu also supports explicit save/reload, JSON import/export, duplicate, inline rename, and delete. Imported files may omit UUIDs and optional fields.

## Recording

Open **Recorder** after granting Input Monitoring. A three-second countdown appears in the main Recorder UI, giving you time to switch to the target. Stop or cancel it from the Recorder page or with the global Stop hotkey (`F7` by default). Recording uses a passive global AppKit monitor, so normal input continues to reach other applications.

Each completed recording creates a new timestamped macro in the library and selects it automatically. Recording again does not append to or overwrite the previous macro.

Before playback, choose a mouse mode beside the loop controls. The choice is saved separately for each macro. **Background** keeps the physical cursor free and sends mouse events directly to the selected process, though games such as Roblox may ignore them. **Compatibility** activates the target and uses the macOS system cursor so game mouse actions can work.

The recorder automatically captures:

- Key presses and releases, including Shift, Command, Option, and Control combinations
- Left, right, middle, single, and multi-clicks
- Pointer movement and click-and-drag sequences
- Mouse wheel and trackpad scrolling
- Timing between every action

Captured actions are saved into a new timestamped macro. Pointer movement is throttled and rapid scroll events are combined to avoid excessive steps. Window-relative mouse coordinates are scaled when the target window changes size. Manual **Add Action** is only needed when you want to build or adjust a sequence by hand.

## Automation workflows

Open **Automation** below Logs to build a visual workflow from saved macros and flow nodes. Drag Macro, Start, Wait, Wait for Window, If / Else, Schedule, Repeat, and Stop nodes from the library onto the dotted canvas. If / Else can check for a matching window, elapsed time since automation start, or a macro run count, then follow its Yes or No output; the paths can rejoin at a later node. Drag from an output handle to another node's input handle to connect them; select a node or connection to edit or delete it.

The editor supports right-click-drag canvas panning, scroll/slider zoom, fit-to-screen, vertical auto-arrange, node movement, connection reconnection and deletion, per-connection bent/curved/straight styles, and obstacle-aware routing that bends wires around node cards. Repeat loop-back paths use the same node-avoiding routing. Valid drop targets highlight while connecting. After a Repeat node's count finishes, execution follows its normal output. Workflow validation marks missing macros, disconnected paths, dead ends, and direct cycles before Run is enabled, while the inspector keeps a timed execution history for the latest run. Narrow windows collapse the searchable library and inspector into toolbar-controlled overlay panels.

Automations reference macro UUIDs, so later edits to a macro are used automatically. They are stored separately and atomically in `~/Library/Application Support/Macro/Automations.json`, with `Automations.backup.json` recovery. Run, pause, stop, F7, and Escape coordinate with the existing Macro engine; the workflow layer does not duplicate keyboard or mouse playback.

## Global hotkeys

The default global controls work even while Macro is in the background:

- **F6** — start recording
- **F7** — stop recording or active playback
- **F8** — play the selected macro

Change them under **Macro → Settings… → Hotkeys**. Click a shortcut control and press a function key or modified key combination. Choices persist between launches. Macro prevents duplicate shortcuts and excludes its three control shortcuts from recorded actions. macOS-reserved shortcuts or shortcuts owned by another app cannot be registered; the Hotkeys screen reports that state.

## Important limitations

- The experimental backend uses `CGEvent.postToPid`, not a global `CGEvent.post` and never activates the target.
- macOS provides no acknowledgment that an application consumed a posted event.
- Games may ignore process-posted Quartz events and read focused HID/game-controller state instead.
- Targeted mouse events carry a synthetic location but do not guarantee that a game will accept clicks while the physical cursor is elsewhere.
- The key map uses standard macOS virtual key codes and may differ on non-US keyboard layouts.

See `BACKGROUND_INPUT_LIMITATIONS.md` for the full API and Roblox findings.
