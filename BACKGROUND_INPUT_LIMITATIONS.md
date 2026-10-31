# Background Input Investigation and Limitations

## Result

macOS has public APIs that can create synthetic events and post them to a process, but it does not provide a general, guaranteed “control any background window” facility. Event creation/posting success is distinct from application receipt, and receipt is distinct from the application acting on the event.

Macro therefore labels its backend **Targeted CGEvent (Experimental)** and never reports successful receipt without evidence from the target.

## APIs investigated

### `CGWindowListCopyWindowInfo`

Used for read-only discovery. Macro records the Window Server ID, owner PID, bounds, application name, and bundle identifier without activating the application. The current list intentionally includes normal, visible, on-screen windows. macOS or the application may hide the title, which is displayed as “Untitled Window.”

### Global `CGEvent.post(tap:)`

Rejected as Macro’s primary backend. A global event is dispatched through the system event stream and normally follows the current input destination. Global mouse events can affect the real pointer. That does not meet the isolation requirement.

### `CGEvent.postToPid`

Implemented as the experimental backend. Keyboard and mouse Quartz events are constructed from a private event source and posted to the selected PID. Macro does not activate the application and does not intentionally post these events to the global HID stream.

Limitations:

- The API accepts a process, not a specific window ID. Window selection supplies process identity and coordinate bounds; it cannot force the process to route an event to one of several windows.
- There is no public receipt acknowledgment.
- A target may ignore synthetic, non-focused, or non-HID events.
- Mouse locations are event metadata. Applications can compare them with real cursor/focus state or use another input path.

### `AXUIElementPostKeyboardEvent`

Apple documents this as posting keyboard events to an application Accessibility element rather than always using the active application. It is keyboard-only, can return “not implemented,” and does not solve targeted mouse input. Macro keeps its backend abstraction open for an Accessibility variant but currently uses the more general PID-targeted Quartz experiment.

### Accessibility and Input Monitoring

`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions` manage Accessibility authorization. `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` manage permission to observe global input. macOS controls both decisions; Macro does not bypass them.

Accessibility authorization is checked before every scheduled action so revocation stops execution. Input Monitoring is used for passive recording and the global Escape emergency stop.

### Event monitors

Recording uses `NSEvent.addGlobalMonitorForEvents`. It observes input without consuming or modifying it, so input continues to the application the user is actively using. A local monitor covers Escape while Macro is active. A global Escape monitor is available when Input Monitoring is authorized.

## Keyboard isolation

Macro posts keyboard events only to the selected PID. It does not activate the target or globally synthesize keystrokes. This preserves the user’s normal typing path in principle, but target acceptance is application-dependent. Standard virtual key codes are currently based on a US layout.

## Mouse isolation

Macro does not call cursor-warping APIs and does not post mouse events globally. It posts a mouse event with screen or target-window-relative coordinates to the selected PID. The physical pointer should remain under the user’s control, but acceptance and interpretation of the synthetic coordinates are target-dependent and must be observed by the user.

## Roblox findings

On 2026-10-30, Roblox was observed running as `RobloxPlayer`. The Window Server exposed its main window as a normal on-screen layer-0 window, but did not expose a title. Macro can therefore discover it as **Roblox — Untitled Window**.

Background input consumption has not been proven. Sending live gameplay input automatically during development could change the user’s game/account state, so no unattended gameplay test was performed. The in-app diagnostic can post E, a center click, or a center move when the user explicitly requests it. Its result correctly says “posted, receipt cannot be verified.”

Roblox may use focused HID/game input and ignore Quartz events posted to its background process. If the diagnostic only works while Roblox is focused—or never works—public APIs do not provide a legitimate way for Macro to bypass that behavior.

## Safety behavior

- Escape cancels the schedule and releases held automation inputs.
- Stop, errors, permission revocation, target termination, and app termination also release held inputs.
- Timing uses cancellable asynchronous sleeps in 20 ms slices; the UI thread is never blocked.
- Pause stops timing progression rather than merely delaying the next action.

## What cannot be claimed

Macro cannot claim that Roblox or another target received an event merely because macOS accepted the post. It cannot guarantee independent background control for applications that require focus or direct HID state, and it does not attempt to bypass macOS privacy controls or target anti-cheat protections.
