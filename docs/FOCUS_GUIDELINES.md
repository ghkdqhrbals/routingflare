# routingflare macOS Focus Guidelines

These rules define how routingflare opens and focuses its management window.

## Official References

- `NSApplication.activate(ignoringOtherApps:)`
  https://developer.apple.com/documentation/appkit/nsapplication/activate%28ignoringotherapps%3A%29
- `NSWindow.makeKeyAndOrderFront(_:)`
  https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront%28_%3A%29
- `NSWindow.Level`
  https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct
- Human Interface Guidelines: Split views
  https://developer.apple.com/design/human-interface-guidelines/split-views

## Window Rules

1. The management UI must use a normal `NSWindow`, not `NSPanel`.
2. The management window level must stay `.normal`.
3. Do not use floating, pop-up, modal, or status-menu window levels for the management window.
4. Do not use `orderFrontRegardless()` for the management window.
5. Tooltip or transient UI may use a separate nonactivating panel, but it must not share code paths with the management window.

## Focus Rules

1. User intent opens the management window:
   - app launch
   - menu bar "Open routingflare"
   - menu bar "Settings"
   - menu bar "About"
   - CLI `open` command
2. On those actions, routingflare may call `NSApplication.shared.activate(ignoringOtherApps: true)`.
3. After activation, call `makeKeyAndOrderFront(_:)` on the existing or newly created management window.
4. The app must not re-activate itself from timers, route updates, logs, background tasks, or status changes.
5. Closing or deactivating the window must allow other apps to become active normally.

## Navigation Rules

1. The sidebar and content area must be a native split view.
2. The sidebar must have a draggable divider and support horizontal resizing.
3. Sidebar rows must make the full row area clickable, not just the text.
