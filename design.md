# KeyNav — Design Document

A macOS menu-bar utility for keyboard-only navigation, built on the Accessibility API.

- **Window mode** (`⌥Space`): label every window on the current Space; press a label to focus that window, focus its input field, and move the cursor to its center.
- **Element mode** (`⌥F`): label every clickable control in the active window; press a label to click it.

---

## 1. Decisions Summary

| Topic | Decision |
|---|---|
| Window scope | Current Space only: on-screen, covered, minimized, and hidden-app windows. Other Spaces are excluded (no private Space APIs). |
| Visible vs. thumbnail | The window's center point is uncovered → label drawn on the window. Otherwise, if a meaningful uncovered region exists, the label goes there; failing that, the window goes to the thumbnail strip. |
| Thumbnail strip | Bottom of the **main** monitor (the one with the menu bar); label at the bottom of each thumbnail. |
| Multi-monitor | On-window labels appear on whichever monitor each window is on. |
| Focus after switch | Restore the app's last-focused element in that window, else focus the first text input. |
| Cursor | Warped to the center of the selected window. |
| Label alphabet | Home row first (`asdfjklgheruiwoqptycvnmxzb`, letters only so it works with any input method); prefix-free; 2 chars only when needed; editable. |
| Click types | Left click by default. If **Shift** is held on the final label key → right click. If **⌘** is held → ⌘-click. Text inputs receive focus instead of a click. |
| Click method | `AXPress` first, synthetic `CGEvent` mouse click as fallback (always used for right-click and ⌘-click). |
| Chaining | Element mode closes after a click. If **⌥** is still held, it rescans and relabels to allow consecutive clicks. |
| Overlay keys | `Esc` cancels; `Backspace` removes the last typed char; non-matching labels dim; clicking anywhere or pressing the hotkey again cancels (the click still reaches the app). Hold `Space` to peek under labels; `Tab` toggles important/all element labels. **Window mode mouse**: the scroll wheel moves a highlight through the labels in label order, looping (only labels matching the typed prefix); the highlighted label is inverted and its window or thumbnail is outlined. The **middle button** or `Return` activates the highlighted window. **Opening by mouse**: holding the middle button for 0.4 s (setting *Hold the middle mouse button to show windows*, on by default) opens window mode; KeyNav's tap holds back the press, and if it is released early or dragged more than 6 pt, the press is replayed to the app as a normal middle click / drag (replayed events are tagged via `eventSourceUserData` so the tap ignores them). Scrolls and the middle click are swallowed while window mode is shown; in element mode scrolling passes through. **Screenshots**: ⌘⇧3/4/5/6 pass through without closing the overlay; for 20 s afterwards clicks don't cancel it and the first Esc passes through to the screenshot UI. The overlay is click-through, so the target app keeps focus *and* hover state (hover-only buttons stay visible); clicks are detected by the event tap. |
| Default hotkeys | `⌥Space` (windows), `⌥F` (elements); re-recordable in Settings. |
| Thumbnails | Live ScreenCaptureKit capture for covered windows; in-memory snapshot cache for minimized/hidden; app icon + title as last fallback. |
| Stack | Swift 6 toolchain (Swift 5 language mode), SwiftPM package + `build.sh` bundler, macOS 14+, AppKit overlays, SwiftUI settings, ScreenCaptureKit, SMAppService. No third-party dependencies. |
| Distribution | Personal use: built locally with `build.sh`, signed with a free Apple Development (Personal Team) certificate so TCC grants survive rebuilds; non-sandboxed. Developer ID + notarization only if it is ever shared. |

---

## 2. Requirements

### 2.1 Functional

1. **Menu-bar app**. No Dock icon (`LSUIElement = YES`). Status item menu: *Show Windows*, *Label Elements*, *Pause KeyNav*, *Settings…*, *Permissions…*, *Quit*.
2. **Auto start** at login via `SMAppService.mainApp` (toggle in Settings).
3. **Window mode**:
   - Enumerate all eligible windows on the current Space.
   - Visible windows: a large label badge drawn on the window.
   - Non-visible windows: thumbnail + label in the strip on the main monitor.
   - Typing a label → un-minimize / unhide as needed → raise and focus the window → focus its default input → warp the cursor to the window center.
4. **Element mode**:
   - Scan the focused window (including sheets, toolbars, and open popovers that belong to it) for actionable elements.
   - Label each element; typing a label performs the click.
5. **Settings screen** (see §9) covering hotkey recording, auto start, label alphabet, appearance, behavior toggles, thumbnail options, and per-app exclusions.
6. **Permission onboarding** for Accessibility (required) and Screen Recording (optional; without it, thumbnails fall back to icons).

### 2.2 Non-Functional

| Metric | Target |
|---|---|
| Hotkey → window labels visible | ≤ 120 ms (up to ~40 windows) |
| Hotkey → element labels visible | ≤ 200 ms typical, hard cap 600 ms (partial results shown) |
| Thumbnails | Rendered asynchronously; strip appears immediately with placeholders/cached images |
| Idle CPU | ~0% (no polling; event-driven only) |
| Idle memory | < 60 MB with a full snapshot cache |
| Hung apps | Never block KeyNav: AX messaging timeout 250 ms per app |

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                              KeyNavApp                               │
│  MenuBarController   SettingsWindow (SwiftUI)   OnboardingWindow     │
└───────────┬───────────────────────┬──────────────────────────────────┘
            │                       │
     ┌──────▼───────┐        ┌──────▼───────┐       ┌────────────────┐
     │HotkeyService │        │SettingsStore │◄──────│PermissionMgr   │
     │(Carbon hotkey│        │(UserDefaults)│       │(AX / ScreenRec)│
     └──────┬───────┘        └──────────────┘       └────────────────┘
            │ trigger
     ┌──────▼──────────────────────────────────────────────────────┐
     │                    ModeCoordinator (state machine)          │
     └──┬──────────────┬──────────────────┬───────────────────┬────┘
        │              │                  │                   │
 ┌──────▼─────┐ ┌──────▼──────┐   ┌───────▼───────┐   ┌───────▼───────┐
 │KeyRouter   │ │LabelGen     │   │OverlayCtrl    │   │ (mode workers)│
 │(CGEventTap)│ │(prefix-free)│   │(1 panel/screen│   └───────┬───────┘
 └────────────┘ └─────────────┘   │ + strip)      │           │
                                  └───────────────┘           │
      ┌───────────────────────────────────────────────────────┤
      │ Window mode                                           │ Element mode
┌─────▼──────────┐ ┌─────────────────┐ ┌───────────────┐ ┌────▼───────────┐
│WindowCatalog   │ │VisibilityAnalyzr│ │ThumbnailSvc   │ │ElementScanner  │
│(CG list + AX)  │ │(z-order hit test│ │(SCK + Snapshot│ │(AX tree walk)  │
└─────┬──────────┘ └─────────────────┘ │ Cache)        │ └────┬───────────┘
      │                                └───────────────┘      │
┌─────▼──────────┐ ┌─────────────────┐                   ┌────▼───────────┐
│WindowActivator │ │FocusResolver +  │                   │ElementActivator│
│(raise/unhide/  │ │FocusTracker     │                   │(AXPress / CG   │
│ unminimize)    │ │                 │                   │ mouse events)  │
└────────────────┘ └─────────────────┘                   └────────────────┘
```

### 3.1 Module Responsibilities

| Module | Responsibility |
|---|---|
| `HotkeyService` | *(Removed.)* Carbon `RegisterEventHotKey` silently dropped the first press of every shortcut on macOS 26, so shortcuts are detected by `KeyRouter`'s event tap instead. |
| `KeyRouter` | One always-on **active** `CGEventTap` (session level, needs Accessibility only). While idle, it checks each keyDown against the two shortcuts by key code + modifiers, swallows a match (and its keyUp), and dispatches the action. While an overlay is active, it swallows keystrokes and forwards them to the coordinator, so KeyNav never steals focus from the target app. Disabled while paused or while a shortcut is being recorded. If Accessibility isn't granted at launch, the tap is retried every 2 s. |
| `ModeCoordinator` | State machine (§4); owns the current label → target map and typed prefix. |
| `LabelGenerator` | Produces prefix-free labels from the configured alphabet (§5). |
| `OverlayController` | One borderless, non-activating `NSPanel` per screen (level `.screenSaver`, `canJoinAllSpaces`, `fullScreenAuxiliary`), plus the thumbnail strip on the main screen. Draws badges with Core Animation layers for speed. |
| `WindowCatalog` | Builds the window list by merging `CGWindowListCopyWindowInfo` (z-order, bounds, ID, on-screen status) with AX windows (minimized, title, role, actions). |
| `VisibilityAnalyzer` | Decides on-window label vs. strip, and where the label goes (§6.2). |
| `ThumbnailService` / `SnapshotCache` | ScreenCaptureKit captures and an in-memory LRU of downscaled snapshots (§6.3). |
| `WindowActivator` | Unhide, un-minimize, raise, focus (§6.4). |
| `FocusTracker` / `FocusResolver` | Remember the last focused element per window; choose the default input (§6.5). |
| `ElementScanner` | Walks the AX tree of the focused window and collects actionable elements (§7.1). |
| `ElementActivator` | Performs the press or click (§7.3). |
| `SettingsStore` | Typed settings backed by `UserDefaults`; publishes changes (Observation). |
| `PermissionManager` | Checks and requests AX and Screen Recording permissions; drives onboarding and menu status. |

### 3.2 Threading

- **Main actor**: UI, overlays, coordinator state.
- **Dedicated serial `AXQueue`**: all AX calls (they are blocking IPC). Results are returned as value types (`WindowInfo`, `ElementInfo`) holding the `AXUIElement` references.
- **Swift concurrency `Task`s**: ScreenCaptureKit captures (async API), run in parallel with a concurrency limit of 4.
- **Event tap**: runs on its own thread's run loop; posts to the main actor. The tap callback must return quickly. If macOS disables the tap (`kCGEventTapDisabledByTimeout`), it is re-enabled immediately.

---

## 4. State Machine

```
                ⌥Space                         label complete
   ┌──────┐ ─────────────► ┌──────────────┐ ───────────────► activate window ─┐
   │ Idle │                │ WindowMode   │                                   │
   │      │ ◄───────────── │ prefix: ""   │ ◄─ Backspace (pop prefix)         │
   └──────┘  Esc / click / └──────────────┘                                   │
     ▲  ▲    hotkey again                                                     │
     │  └─────────────────────────────────────────────────────────────────────┘
     │
     │         ⌥F                             label complete
     │      ─────────────► ┌──────────────┐ ───────────────► click element
     │                     │ ElementMode  │                      │
     └──────────────────── │ prefix: ""   │ ◄── ⌥ still held ────┘ (rescan + relabel)
        Esc / click /      └──────────────┘
        hotkey again /     (⌥ not held after click → Idle)
        ⌥ released after click
```

Rules:
- Pressing the *other* hotkey while in a mode switches modes.
- A key that matches no label prefix is ignored (with a subtle shake animation); it does not cancel.
- When the typed prefix uniquely identifies a label, the action fires immediately (no Enter needed).
- When the active app changes or the screen configuration changes during a mode, the overlay is cancelled.
- If the scan returns zero targets, show a brief "No windows" / "No clickable elements" HUD and return to Idle.

### 4.1 Key Interpretation

- Labels are matched by **virtual key code**, not by produced character, so held modifiers (⌥ for chaining, ⇧ for right-click) don't alter what is matched. Key codes are mapped to label characters through the current keyboard layout (`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` with no modifiers), so non-QWERTY layouts work.
- Modifiers are evaluated on the **final** keystroke of a label:
  - ⇧ → right click
  - ⌘ → ⌘-click
  - ⌥ → chain (element mode only)

---

## 5. Label Generation

**Input**: alphabet `A` (ordered, default home-row-first), item count `n`, items pre-sorted by priority.

**Algorithm** (prefix-free, minimal length):

```
k = |A|
if n <= k: return first n chars of A
// m chars used as single labels; remaining (k - m) chars are prefixes of 2-char labels
m = floor((k*k - n) / (k - 1))        // max singles such that m + (k-m)*k >= n
singles  = A[0 ..< m]
prefixes = A[m ..< k]   (reversed, so the weakest keys become prefixes)
labels   = singles + [p + c for p in prefixes for c in A]   → take first n
if n > k*k: extend to 3 chars using the same scheme (practically never hit)
```

**Priority order** (the best items get single, home-row labels):
- **Window mode**: front-to-back z-order for visible windows first, then strip windows in MRU order. The currently focused window gets the *last* single label, since you rarely switch to it.
- **Element mode**: reading order (top-to-bottom, then left-to-right, using a row-banding tolerance of ½ the element height).

Labels are uppercase in the badge for readability, but typed without Shift.

---

## 6. Window Mode

### 6.1 Window Enumeration (`WindowCatalog`)

1. `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`. This gives the front-to-back z-order of the current Space. Keep `layer == 0`, `alpha > 0`, size ≥ 40×40, and owner not excluded.
2. For each running regular app (`NSWorkspace.runningApplications`, `activationPolicy == .regular`, not excluded), get the AX app element and read `kAXWindowsAttribute`. Batch-read `role`, `subrole`, `title`, `position`, `size`, `minimized` with `AXUIElementCopyMultipleAttributeValues`.
3. Keep only AX windows with role `AXWindow` and subrole `AXStandardWindow` / `AXDialog` (configurable).
4. **Map each AX window to a CGWindowID** using `_AXUIElementGetWindow`. This is a private but very widely used and stable symbol (AltTab, Rectangle, yabai), resolved with `dlsym` so a missing symbol degrades gracefully. Fallback: match on PID + frame + title.
5. **Current-Space filter**. A window is included if:
   - it is in the on-screen CG list (step 1), **or**
   - it is minimized (`AXMinimized == true`), **or**
   - its app is hidden (`NSRunningApplication.isHidden`).

   AX windows matching none of these live on another Space and are dropped.
6. Output: `[WindowInfo { id, pid, axElement, title, appName, appIcon, frame, zIndex?, state: .onScreen | .minimized | .hidden }]`.

### 6.2 Visibility Analysis (`VisibilityAnalyzer`)

For each `.onScreen` window, in z-order:

1. **Center test**: find the topmost layer-0 window (from the CG list) whose frame contains the window's center point. If that is this window → *visible*, label at center.
2. **Uncovered-region fallback**: sample a 7×7 grid over the window frame (inset 10%). Points not covered by any window above it are "uncovered."
   - If ≥ 15% of samples are uncovered **and** the largest connected uncovered cluster is at least 120×80 pt, the window is *visible*. The label goes at the cluster's centroid, snapped to the nearest uncovered sample.
   - Otherwise → strip.
3. Points off every screen count as covered.
4. Minimized and hidden windows → always strip.

Overlapping label positions are pushed apart with a small separation pass (to avoid badge collisions when two windows share a center).

### 6.3 Thumbnails (`ThumbnailService` + `SnapshotCache`)

**Live capture** (covered windows on the current Space):
- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` is fetched once per window-mode invocation (≈20–40 ms), or reused from a 2 s cache.
- Per window: `SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow:), configuration:)` with output size = thumbnail size × backing scale, `showsCursor = false`. This captures window content even when occluded.

**Snapshot cache** (minimized / hidden windows can't be captured live):
- An in-memory LRU, keyed by CGWindowID, default max 100 entries, each downscaled to ≤ 480 px on the long edge (~0.5 MB each).
- Populated:
  - (a) with every successful live capture during window mode;
  - (b) when an app deactivates (`NSWorkspace.didActivateApplicationNotification`): the previously frontmost app's on-screen windows are captured in the background, debounced to 1 s;
  - (c) just before KeyNav itself minimizes or hides anything (not applicable in v1).
- Never written to disk. Cleared on *Pause*, on screen lock, and when the cache is disabled in Settings.
- Entries are evicted when the window closes (CG ID disappears on the next enumeration).

**Fallback**: app icon (large) + window title on a neutral card.

**Without Screen Recording permission**, the service is disabled and all strip items use the fallback. Settings shows a "Grant Screen Recording for thumbnails" button.

**Strip layout**:
- A horizontal row centered at the bottom of the main screen's `visibleFrame` (above the Dock).
- Each card: thumbnail (default height 160 pt, aspect preserved, max width 280 pt), app icon + truncated title, and the label badge overlapping the **bottom** edge.
- If the cards overflow the screen width, they shrink down to 60% of their size, then wrap into a second row (rows grow upward).
- Cards appear immediately with cached or placeholder images, which are swapped in as live captures complete.

### 6.4 Activation (`WindowActivator`)

Given the selected `WindowInfo`:

1. If the app is hidden → `NSRunningApplication.unhide()`.
2. If the window is minimized → set `kAXMinimizedAttribute = false` and wait for `kAXWindowDeminiaturizedNotification` or poll the frame (≤ 300 ms).
3. Raise: `AXUIElementPerformAction(window, kAXRaiseAction)` → set `kAXMainAttribute = true` on the window → set `kAXFrontmostAttribute = true` on the app element.
4. Verify via `NSWorkspace.frontmostApplication` and the app's `kAXFocusedWindow`. If macOS 14's cooperative activation refused, retry once with `NSRunningApplication.activate(options: [])` followed by `kAXRaiseAction` again.
5. Run `FocusResolver` (§6.5).
6. Warp the cursor to the window center: `CGWarpMouseCursorPosition(center)`, then `CGAssociateMouseAndMouseCursorPosition(1)` (avoids the post-warp freeze). AX/CG use top-left global coordinates, so no flip is needed here. Skipped if *Move cursor to window* is off.

### 6.5 Default Input Focus

**`FocusTracker`**: observes **only the frontmost app** with an `AXObserver` for `kAXFocusedUIElementChangedNotification`. It re-subscribes on every app activation, so the cost is a single observer at a time. It records `lastFocused[CGWindowID] = AXUIElement`, keeping elements that are inside a window and still valid.

**`FocusResolver`**, after the window is raised:

1. Read the app's `kAXFocusedUIElement`. If it is inside the target window, and it is an editable or meaningful element (not the window itself), **keep it**. The app restored its own focus.
2. Else, if `lastFocused[windowID]` exists and is still valid (attribute read succeeds and the element's window matches) → set `kAXFocusedAttribute = true` on it.
3. Else, BFS the window's AX tree (depth ≤ 25, ≤ 2,000 nodes, 150 ms budget) for the first element in reading order with role in {`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField` subrole, `AXWebArea` focused text input}, enabled, and visible → set `kAXFocusedAttribute = true`.
4. Else, do nothing (the window keeps whatever focus the app gives it).

Steps 2 and 3 can each be disabled in Settings (*Restore last focus*, *Fallback to first text field*).

---

## 7. Element Mode

### 7.1 Scanning (`ElementScanner`)

**Target**: the frontmost app's `kAXFocusedWindow`, plus its child sheets/drawers and any AX elements of role `AXPopover`/`AXMenu` currently open in that app.

**Chromium / Electron enablement**:
- Before scanning, set `AXManualAccessibility = true` on the app element (Electron).
- For known Chromium browsers (configurable bundle-ID list), also set `AXEnhancedUserInterface = true`.

  These are cached per PID so they're only set once. Because `AXEnhancedUserInterface` can interfere with window-manager animations, it is reset to `false` 2 s after the mode ends. Optional: *keep enabled*.

**Traversal**:
- Iterative DFS on `AXQueue`.
- Batch attribute read per node: `role`, `subrole`, `position`, `size`, `enabled`, `children` (or `AXVisibleChildren` / `AXVisibleRows` for scroll areas, tables, and outlines, so off-screen rows aren't walked), and `actionNames` (via `AXUIElementCopyActionNames`).
- Prune any subtree whose frame doesn't intersect the window frame ∩ screen bounds.
- Limits:
  - depth ≤ 40
  - nodes ≤ 5,000
  - time budget 600 ms (partial results are shown if the budget is hit)

**Actionable if** visible, enabled (unless *Show disabled* is on), size ≥ 6×6 pt, and any of:
- role ∈ {`AXButton`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXMenuButton`, `AXLink`, `AXTextField`, `AXTextArea`, `AXComboBox`, `AXSlider`, `AXIncrementor`, `AXDisclosureTriangle`, `AXTab`, `AXMenuItem`, `AXMenuBarItem`*, `AXCell`, `AXRow` (selectable)}
- actions contain `AXPress`, `AXConfirm`, `AXPick`, `AXShowMenu`, or `AXOpen`
- *(configurable)*: `AXStaticText`/`AXImage` with an `AXPress` action

\* The app menu bar is excluded in v1 (window-scoped).

**De-duplication**: if a parent and child are both actionable and their frames overlap ≥ 85%, keep the one with the stronger role (button > cell > group) and prefer the child when it has its own `AXPress`. This collapses wrappers common in web content.

**Cap**: if there are more than *Max elements* (default 300), keep the ones closest to the window center and show "+N more" in a HUD.

**Smart subset** (setting *Label only important controls first*, on by default): the scan produces both the full list and an "important" list. **Tab** switches between the two without rescanning. The important list drops:
1. Elements inside a labeled row, link or button (clicking the container is enough).
2. `AXCell`s and "pressable" groups.
3. `AXButton`s and links with no title, description or help.
4. Links whose `AXURL` was already seen.
5. Labels whose top-left anchors would collide; the higher-ranked, then larger, control wins.

A HUD shows "N of M · Tab shows all".

### 7.2 Element Labels

- **Small controls** (smaller than 3× the badge width or 1.6× its height, e.g. icon buttons) get the badge *beside* them, so the icon stays readable. The badge goes on the first side (left, above, right, below) that is on screen and covers no other labeled control or badge. Containers around the control (such as its row) don't count.
- **Large controls** (text fields, rows) get the badge inside the **top-left corner**, inset 2 pt; overlapping badges are nudged right.
- **Peek**: hold **Space** to hide all labels (in both modes); release it to show them again.
- Smaller default font than window labels (default 14 pt bold vs. 48 pt for windows), both configurable.
- An optional thin outline around each element's frame (*Show element outlines*, off by default).

### 7.3 Clicking (`ElementActivator`)

| Typed with | Element type | Action |
|---|---|---|
| no modifier | text input (`AXTextField`/`AXTextArea`/`AXComboBox`) | `kAXFocusedAttribute = true`; if that fails, synthetic left click |
| no modifier | other | `AXPress` (or the first supported of `AXConfirm`, `AXPick`, `AXOpen`); if unsupported or the call errors → synthetic left click |
| ⇧ | any | `AXShowMenu` if supported, else synthetic right click |
| ⌘ | any | synthetic left click with ⌘ flag |

**Synthetic click**:
- Post `CGEvent(mouseEventSource:mouseType:.leftMouseDown/.leftMouseUp…)` at the element's center (clamped into the visible portion of its frame), with click state 1, and the modifier flags applied to the events.
- The cursor is warped to the point first, then restored to its original position afterwards (unless *Leave cursor on clicked element* is on).

**Chaining**: after the action, if ⌥ is still physically held (from `flagsChanged`), wait 150 ms for the UI to settle, then rescan and relabel. Otherwise exit to Idle.

---

## 8. Overlay Rendering

- **Panels**: `NSPanel(styleMask: [.borderless, .nonactivatingPanel])`, transparent background, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `hidesOnDeactivate = false`.
  - Each panel covers its screen's full frame.
  - Mouse-down anywhere → cancel (not passed through).
- Panels are **pre-created and kept hidden**, and rebuilt on `NSApplication.didChangeScreenParametersNotification`, so showing them costs only a layout pass.
- **Coordinates**: AX/CG use top-left-origin global points; AppKit uses bottom-left-origin. A single `ScreenGeometry.toAppKit(_:)` helper converts using the primary screen's height.
- **Badge**:
  - Rounded rect (corner radius 25% of height), default yellow `#FFD60A` background, black text, 1 pt dark border, soft shadow, SF Mono Bold.
  - Typed-prefix chars are rendered dimmed within the badge. Badges that no longer match fade to 25% opacity.
- **Animation**: 80 ms fade-in; no animation on dismiss (instant, to stay out of the way).
- **Contrast**: on-window badges get a translucent dark halo so they remain readable on any content.

---

## 9. Settings Screen

A SwiftUI `Settings` scene with tabs:

1. **General**
   - Launch at login (SMAppService toggle; shows status if the user disabled it in System Settings)
   - Hotkey recorders: *Show windows*, *Label elements* (`KeyboardShortcuts.Recorder`, with conflict warning)
   - Label alphabet (text field; validated: unique chars, ≥ 2; *Reset to home row* button)
   - Pause KeyNav
2. **Appearance**
   - Window label font size (24–96, default 48); element label font size (10–32, default 14)
   - Badge background / text / border colors; opacity (40–100%)
   - Live preview of a badge
3. **Behavior**
   - Move cursor to window center ✔
   - Restore last focused element ✔ / Fallback to first text field ✔
   - Element roles to label (checkbox list by category: buttons, links, text inputs, checkboxes/radios, tabs, table rows/cells, menus, static text with actions)
   - Show disabled elements ☐ · Show element outlines ☐
   - Max elements (50–1,000, default 300)
   - Leave cursor on clicked element ☐
   - Chromium accessibility: browser bundle-ID list · Keep enhanced UI enabled ☐
4. **Thumbnails**
   - Thumbnail height (80–320, default 160)
   - Include minimized windows ✔ · Include hidden apps ✔
   - Snapshot cache ✔ · Cache size (20–300) · *Clear cache* button
   - Screen Recording status + *Grant* button
5. **Exclusions**
   - App list (add from running apps or `.app` picker; stored by bundle ID). Default excludes: password managers are suggested on first run but not forced; KeyNav itself is always excluded.
   - Per-app scope: *Exclude from window mode* / *Exclude from element mode* / both.
6. **Permissions**
   - Live status of Accessibility and Screen Recording with *Open System Settings* buttons
   - A note about secure input (§11)
7. **About**: version, check for updates (Sparkle, optional), reset all settings.

**Storage**: `UserDefaults` (suite `com.keynav.app`), one `Codable` `Settings` struct persisted as JSON under a versioned key (`settings.v1`), with migration hooks. *Export/Import settings* buttons are in About.

---

## 10. Permissions & Onboarding

| Permission | Needed for | API |
|---|---|---|
| Accessibility | Everything: AX reads/actions, active event tap, synthetic clicks | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` |
| Screen Recording | Thumbnails only | `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` |

- **First launch**: an onboarding window with step 1 (Accessibility, required) and step 2 (Screen Recording, optional, skippable). It polls trust status every 1 s while open and advances automatically.
- If Accessibility is revoked at runtime, hotkeys show a notification "KeyNav needs Accessibility access" and open onboarding.
- **Dev note**: TCC grants are tied to the code signature. Sign debug builds with a stable development certificate, or permissions reset on every build.

---

## 11. Edge Cases & Risks

| Case | Handling |
|---|---|
| **Secure input** active (password field focused; `IsSecureEventInputEnabled()`) | Carbon hotkeys and event taps don't receive keys. Show a menu-bar icon badge; document the limitation. |
| App not responding | 250 ms AX timeout per app (`AXUIElementSetMessagingTimeout`); its windows fall back to CG data only (title from `kCGWindowName` if permitted). |
| Full-screen app on current Space | Only that app's windows are on-screen. Minimized/hidden windows of other apps still appear in the strip; activating one switches Spaces naturally. |
| Window closes while overlay is shown | Activation fails gracefully → brief HUD "Window no longer exists", back to Idle. |
| Mission Control / Exposé open | Cancel the overlay. |
| Very many windows (> 100) | Labels automatically go to 2 chars; strip wraps; performance stays within budget by lazily capturing thumbnails. |
| Elements inside web content with huge DOMs | Visible-rows pruning, frame pruning, node/time budget, partial results. |
| Elements whose `AXPosition` is wrong (some Java/Qt apps) | Synthetic click fallback uses the same frame; per-app exclusion available. |
| `_AXUIElementGetWindow` unavailable in a future macOS | Fallback PID+frame+title matching (§6.1). |
| Cooperative activation (macOS 14+) refusing focus | AX frontmost + raise, then verify + retry (§6.4). Private `SLPSSetFrontProcessWithOptions` is kept as a last-resort, off-by-default fallback behind a hidden flag. |
| Hotkey conflicts (`⌥Space` used by some IMEs / Alfred) | The recorder warns when registration fails; the menu shows the effective hotkey. |
| Right-to-left / non-QWERTY layouts | Key-code mapping via current layout (§4.1). |

---

## 12. Project Layout

```
keyNav/
├── Package.swift            SwiftPM manifest (open in Xcode with `open Package.swift`)
├── build.sh                 swift build → bundle KeyNav.app → codesign (Apple Development)
├── Support/Info.plist       LSUIElement, bundle id com.keynav.app
├── Sources/KeyNav/
│   ├── main.swift
│   ├── App/        AppDelegate.swift (status menu, wiring), Permissions.swift (onboarding, login item)
│   ├── Core/       ModeCoordinator, LabelGenerator, KeyRouter (event tap), HotkeyService (Carbon),
│   │               KeyLayout (key code ↔ char), AX (typed AX helpers + _AXUIElementGetWindow), Geometry
│   ├── Windows/    WindowCatalog, VisibilityAnalyzer, ThumbnailService, WindowActivator (+ FocusTracker/Resolver)
│   ├── Elements/   ElementScanner, ElementActivator
│   ├── Overlay/    Overlay.swift (panels, badges, thumbnail strip, HUD)
│   └── Settings/   Settings.swift (model + store), SettingsView.swift (tabs, hotkey recorder)
└── Tests/KeyNavTests/       label generation, visibility, element ordering/dedupe, settings decoding
```

**Dependencies**: none (no Carbon hotkeys; shortcuts come from the event tap).

**Signing**: `build.sh` picks the first `Apple Development` identity (override with `KEYNAV_SIGN_IDENTITY`). The designated requirement is keyed on the certificate CN, so Accessibility / Screen Recording grants persist across rebuilds. Info.plist sets `LSUIElement = YES` and `NSScreenCaptureUsageDescription`.

---

## 13. Testing Strategy

- **Unit tests** (pure logic, no AX):
  - label generation: prefix-freeness, counts 1…1000, custom alphabets
  - visibility analysis on synthetic window stacks
  - element filtering/dedupe on fixture trees
  - coordinate conversion across multi-screen layouts
  - state-machine transitions
- **Integration tests** (manual + scripted with a test-harness app): a bundled `KeyNavTestTarget` app with known windows (standard, dialog, minimized, hidden) and known controls (buttons, fields, table, web view) to verify scanning and activation end-to-end.
- **App matrix** for manual QA: Finder, Safari, Chrome, Firefox, VS Code (Electron), Slack, Xcode, Terminal/iTerm2, Mail, System Settings, a Java app (IntelliJ), a Qt app.
- **Performance**: `os_signpost` intervals for enumerate / analyze / capture / scan / render; check against budgets in Instruments.

---

## 14. Milestones

| # | Milestone | Contents |
|---|---|---|
| M1 | Skeleton | Menu-bar app, settings store, permissions onboarding, launch-at-login, hotkey registration |
| M2 | Window mode (visible) | WindowCatalog, VisibilityAnalyzer, label generator, overlay panels, KeyRouter, activation + cursor warp |
| M3 | Window mode (hidden) | Thumbnail strip, ScreenCaptureKit, snapshot cache, icon fallback, unhide/un-minimize |
| M4 | Focus | FocusTracker + FocusResolver |
| M5 | Element mode | ElementScanner, filters/dedupe, Chromium enablement, ElementActivator (AXPress + synthetic), modifiers, chaining |
| M6 | Settings UI complete | All tabs, live preview, exclusions, import/export |
| M7 | Hardening | Edge cases (§11), performance tuning, QA matrix, signing + notarization |

---

## 15. Future Ideas (Out of Scope for v1)

- Windows on other Spaces (private CGS APIs, opt-in).
- Labeling the app menu bar and status-bar items.
- Sticky labels (same window keeps its letter across invocations).
- `/` type-to-search over window titles.
- Scroll mode (label scroll areas; `j/k` to scroll).
- Per-app element-role profiles.
