# KeyNav

Keyboard (and mouse) navigation for macOS windows and controls.

KeyNav is a small menu bar app. Press a shortcut and every window on the current Space gets a big letter label. Type the letter to jump to that window. Press another shortcut and every clickable control in the active window gets a label. Type it to click.

- **Window mode** (default `⌥Space`)
  - Windows you can see get a label right on top of them.
  - Windows that are covered, minimized or hidden appear as thumbnails in a strip at the bottom of the main screen, each with its own label.
  - Picking a window brings it to the front, puts the keyboard focus back where you left it (or on its first text field), and moves the mouse pointer to the window's center.
- **Element mode** (default `⌥F`)
  - Labels buttons, links, text fields, checkboxes, tabs, list rows and more in the frontmost window.
  - Typing a label clicks that control. Text fields get keyboard focus instead.
- **Mouse control**
  - Hold the middle button to open the window picker.
  - Scroll to highlight a window, then middle-click to switch to it, all without touching the keyboard.

It's built on the macOS Accessibility API, works on multiple monitors, and works while a non-Latin input method (such as Pinyin) is active.

## Requirements

- macOS 14 (Sonoma) or later.
- Xcode or the Xcode Command Line Tools (Swift 5.10+).
- A free **Apple Development** signing certificate. A paid developer account is *not* needed (see [Building](#building)).

## Building

```bash
git clone git@github.com:alxwang/keyNav.git
cd keyNav
./build.sh install     # builds, signs, copies to /Applications and launches
```

`./build.sh` on its own builds `build/KeyNav.app` without installing it. Run `swift test` to run the unit tests.

### Signing certificate (one-time)

macOS ties the Accessibility and Screen Recording permissions to the app's code signature. An ad-hoc signed app gets a new signature on every build, so you would have to grant the permissions again each time. `build.sh` therefore signs with your **Apple Development** certificate, which stays the same across builds.

To get the certificate for free:

1. Open Xcode → **Settings → Accounts**, then add your Apple ID.
2. Select the "(Personal Team)" entry → **Manage Certificates…** → **+** → **Apple Development**.

`build.sh` finds that certificate automatically. If you have more than one, choose one explicitly:

```bash
security find-identity -v -p codesigning           # list identities
KEYNAV_SIGN_IDENTITY=<hash> ./build.sh install
```

## First launch: permissions

KeyNav shows a setup window on first launch. It needs two permissions, both under **System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| **Accessibility** (required) | Reads windows and controls, clicks them, and catches the global shortcuts. |
| **Screen Recording** (optional) | Captures thumbnails of hidden or covered windows. Without it, the strip shows app icons instead. |

After granting Screen Recording, quit and reopen KeyNav from the menu bar icon.

## Usage

### Window mode: `⌥Space`

| Action | What it does |
|---|---|
| Type a label | Switch to that window |
| `Return` | Switch to the window highlighted with the mouse wheel (see below) |

### Mouse

You can switch windows with the mouse alone:

1. **Hold the middle button** (the wheel button) for about 0.4 s. The window picker opens, and you can let go.
2. **Scroll the wheel** to move a highlight from label to label, looping at either end. The highlighted label gets bigger with inverted colors, and its window (or thumbnail) gets an outline. On a trackpad, two-finger scroll; one step is about 40 points of scrolling.
3. **Middle-click** to switch to the highlighted window.

| Mouse action | When | What it does |
|---|---|---|
| Hold middle button ~0.4 s | Any time | Opens window mode |
| Quick middle click | Any time | Works as usual (for example, opens a link in a new tab), just a moment later |
| Middle-button drag | Any time | Works as usual (for example, panning) |
| Scroll | Window mode | Moves the highlight. The app underneath doesn't scroll. |
| Middle click | Window mode | Switches to the highlighted window |
| Left or right click | Either mode | Closes the labels. The click still reaches the app. |

The labels never take focus or catch the mouse. Clicks go through them, and buttons that only show on hover stay visible under the labels. To turn the middle-button gesture off, go to **Settings → General → Hold the middle mouse button to show windows**.

### Element mode: `⌥F`

| Action | What it does |
|---|---|
| Type a label | Click that control (text fields get keyboard focus instead) |
| Hold `⇧` on the last letter | Right-click |
| Hold `⌘` on the last letter | ⌘-click (for example, open a link in a new tab) |
| Hold `⌥` on the last letter | Click, then label the window again for the next click |
| `Tab` | Switch between *important* controls (the default) and *all* controls |

By default, element mode labels only the important controls. It leaves out things nested inside a clickable row or link, unnamed decorative buttons, duplicate links, and labels that would overlap. Press `Tab` to see everything.

### In both modes

| Key | What it does |
|---|---|
| `⌫` | Remove the last typed letter |
| `Esc`, the shortcut again, or any click | Close the labels |
| Hold `Space` | Hide the labels while held, to see what's underneath |

Labels use home-row letters first (`a s d f j k l …`). When there are more items than letters, some labels get two letters, and no label is ever the start of another.

## Settings

Open **Settings…** from the menu bar icon. You can change:

- **General**: the shortcuts (click and press a new combination), launch at login, label letters, the middle-button gesture, and pause.
- **Appearance**: label size, colors and opacity.
- **Behavior**: focus restore, cursor movement, which kinds of controls get labels, important-only labeling, the label limit, and Chromium browser IDs.
- **Thumbnails**: size, whether minimized and hidden windows are included, and the snapshot cache.
- **Exclusions**: apps to leave out of window mode, element mode, or both.
- **Permissions** and **About**: permission status, and settings export, import and reset.

## Tips and limitations

- **Shortcuts do nothing:** while a password field is focused, macOS turns on *Secure Input*, which blocks global shortcuts. The menu bar menu shows a warning when this happens.
- **Shortcut conflicts:** a shortcut you choose replaces the same combination in every app. For example, `⌃Tab` stops switching tabs in browsers and editors.
- **Chromium and Electron apps** (Chrome, VS Code, Slack and others) are asked to turn on their accessibility tree when you first label them, so the first scan can take a moment.
- **Other Spaces:** only windows on the current Space are shown.

## How it works

The full design is in [design.md](design.md). In short:

- Window positions and stacking order come from `CGWindowListCopyWindowInfo`.
- A window counts as visible if a large enough part of it isn't covered by other windows.
- Thumbnails are captured with ScreenCaptureKit.
- Controls are found by walking the window's Accessibility tree.
- A single event tap handles the shortcuts and overlay keys, so the target app keeps keyboard focus the whole time.

```
Sources/KeyNav/
├── App/        app delegate, menu bar, permissions, onboarding
├── Core/       event tap, mode state machine, label generator, AX helpers
├── Windows/    window list, visibility analysis, thumbnails, activation
├── Elements/   accessibility-tree scanner, clicking
├── Overlay/    label and thumbnail drawing
└── Settings/   settings model and SwiftUI settings window
```

## License

[MIT](LICENSE)
