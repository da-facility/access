# Da Facility Access for iOS

Da Facility Access is a RustDesk fork with saved Comet Q and Comet X clients. Its iOS home-screen name is Access. The app icon uses the original RustDesk pixels converted to grayscale with slightly darker midtones. Open Settings > GL.iNet KVM clients, add a name and LAN or Tailscale address, then select it in the GL.iNet KVMs section of Connection. The RustDesk ID field and existing peer list remain available.

The new session uses GLKVM's HTTP, WebSocket and Janus protocols. A GLKVM address is not a RustDesk peer ID and does not use a RustDesk relay server.

## Connection and controls

- Addresses default to HTTPS. Include a port when needed. URL paths, embedded passwords, query strings and fragments are rejected.
- Client definitions and approved certificate fingerprints persist locally. Enable Remember password to save a password in the iOS Keychain after successful login and prefill it on the next visit. Unchecking it immediately removes the saved copy. Changing the client address or username, or deleting the client, also removes its saved password. Keychain entries stay on this device and are available only while it is unlocked. Session tokens are not saved.
- A self-signed certificate requires approval of its SHA-256 fingerprint. Trust applies only to that client's host, port and certificate. Changing the address clears the saved fingerprint.
- When the KVM requires touchscreen approval, the app waits for approval and reports expiry.
- Swipe the video as a trackpad to move the pointer without pressing a mouse button. Tap to click at the pointer. Left and Right buttons click without moving it. Drag holds the left button while you swipe; tap Drag again to release. Scroll arrows move the remote page. Two-finger drags scroll vertically or horizontally with natural touch direction. Pinch to zoom from 100% to 400%; the view follows the pointer when it reaches an edge. A percentage button appears on the right above 100%; tap it to reset the view. Starting a two-finger gesture releases a latched drag.
- Sessions hide the title, connected-status bar and system overlays. Landscape uses safe side margins with compact controls around an aspect-correct video display. Controls have equal spacing between buttons and at the ends of each rail; short rails remain scrollable. Portrait puts the controls above and below the display. Back is the first control at the top left; leaving the session restores the system overlays.
- External keyboards send physical key codes. External mice support pointing, left/right buttons and scrolling. The keyboard sheet sends text and provides navigation keys.
- Leaving the app releases held keys and mouse buttons. Returning from the background requires a new connection.
- Comet X has a four-port selector. It sends the explicit port identity `1.1` through `1.4` and reads the resulting switch state.

Enable Tailscale on the controlling iPhone and the KVM before using a Tailscale address. The app does not configure or embed the VPN.

## Feature overlap and work for parity

This table compares the current implementation with the GLKVM console. "Implemented" describes the code path; hardware verification is recorded separately below. RustDesk widgets and gestures can be reused, but RustDesk's session protocol cannot perform GLKVM operations.

| Capability | Existing RustDesk overlap | This fork and remaining work |
| --- | --- | --- |
| Saved connections | Peer list, address book and Settings | Local GL.iNet list plus per-account RustDesk and KVM address books through the included API server |
| Direct LAN / Tailscale connection | Direct remote sessions | Implemented using the KVM origin; VPN must already be connected |
| Password login and Q device approval | Login dialogs | Implemented against GLKVM auth endpoints; optional per-client password storage in iOS Keychain |
| TLS trust | Connection trust UI | Per-client certificate approval implemented |
| Video | Remote display and scaling | H.264 Janus/WebRTC implemented; H.265, Direct mode and FEC/adaptive transports need separate support |
| Mouse | Pointer and touch input | Touch trackpad, direct physical-mouse input, click, latched drag, right click and wheel implemented using absolute HID coordinates; relative HID mode, sensitivity, inversion and richer gestures remain |
| Keyboard | Keys and modifiers | Hardware keys, modifier controls, text sending and navigation keys implemented; layout selection, macros and live software typing remain |
| Clipboard | Text transfer | One-way text injection implemented; reading remote text requires OCR or another KVM mechanism |
| Comet X channels | Monitor selection is a UI analogue | Four-port selection implemented against the switch API; hardware testing required |
| Q device profiles | No direct equivalent | Device type, touch mode and EDID calibration remain in the KVM console |
| Audio / microphone | Audio controls | Not implemented; add negotiated receive audio and explicit microphone permission/control |
| Display configuration | Quality and scaling controls | Fit-to-screen, 1–4× pinch zoom and one-tap zoom reset implemented; rotation, EDID, bitrate, resolution and frame rate controls remain |
| Virtual media / files | File browser UI | New mass-storage upload, mount and download APIs required; RustDesk file transfer cannot be used directly |
| Power / wake / accessories | Remote actions UI | ATX, Wake-on-LAN and Fingerbot operations require separate device capabilities and APIs |
| Terminal | Terminal UI | Requires the KVM terminal or serial protocol and its authorization |
| Recording / screenshots / OCR | Capture controls | Not implemented for KVM sessions |
| Discovery / cloud / sharing | Address book and accounts | Basic Access accounts and personal books implemented; GL.iNet discovery, cloud binding, relay and shared books remain separate work |
| Firmware / network / security administration | Settings patterns | Keep in the KVM console until model-specific APIs and failure recovery are tested |
| Session recovery and multi-client control | Reconnect UI | Manual reconnect implemented; automatic recovery, exclusivity and conflict indicators remain |
| Localization and accessibility | RustDesk translations and widgets | New KVM copy is English; translation and broader VoiceOver testing remain |

Prioritize real-device video/input coverage on both models, then relative mouse and keyboard layouts, audio, display controls, virtual media and power controls. Full GLKVM console parity also includes device administration and cloud services, beyond remote control.

Protocol sources inspected on 2026-10-05:

- [GLKVM authentication](https://github.com/gl-inet/glkvm/blob/main/kvmd/apps/kvmd/api/auth.py), including cookies and two-step approval.
- [GLKVM HID](https://github.com/gl-inet/glkvm/blob/main/kvmd/apps/kvmd/api/hid.py), including signed 16-bit absolute coordinates and text injection.
- [GLKVM Janus client](https://github.com/gl-inet/glkvm/blob/main/web/share/js/kvm/stream_janus.js), including watch/start negotiation.
- [GLKVM switch API](https://github.com/gl-inet/glkvm/blob/main/kvmd/apps/kvmd/api/switch.py).
- [Comet Q console guide](https://docs.gl-inet.com/kvm/en/user_guide/gl-rmq1/console_guide/) and [Comet X console guide](https://docs.gl-inet.com/kvm/en/user_guide/gl-rm4pe/console_guide/).

## Account address books

The optional [Access API server](../services/address-book/README.md) provides separate accounts and personal address books. Set its HTTPS origin in Settings → ID/Relay Server → API Server, then log in using the existing Account controls. Keep the existing RustDesk ID/relay configuration. The address-book tab uses its existing Add ID/editor for RustDesk machines and shows a GL.iNet KVMs row when the API server advertises that extension.

The account KVM page supports adding, editing, removing and connecting to Comet Q/X entries, plus copying an existing local client into the account. KVM passwords remain in the phone's Keychain, scoped to the API origin and account. Approved certificate fingerprints persist in the account without adding account entries to the device's local KVM list. Other API servers keep the existing address-book UI.

## Building on an Apple Silicon Mac

The initial toolchain uses Flutter 3.24.5, Rust 1.81.0, CocoaPods, Xcode 27 and vcpkg commit `9e593bb18ea69cc5095e012465dcd675a822ed0d`. The application minimum is iOS 15. The default tools directory is `../.toolchains` beside the repository; set `IOS_TOOLS_ROOT` to use another location.

Required Homebrew packages:

```sh
brew install cocoapods cmake ninja nasm yasm pkg-config autoconf autoconf-archive automake libtool libsodium
```

Install Flutter 3.24.5 for macOS ARM64 under `$IOS_TOOLS_ROOT/flutter`. Clone vcpkg under `$IOS_TOOLS_ROOT/vcpkg`, check out the pinned commit and run `bootstrap-vcpkg.sh -disableMetrics`. Install Rust 1.81.0 with rustup. The build script adds the iOS targets and installs the native dependencies. Xcode must have an iOS simulator runtime installed. Flutter 3.24.5 also requires Rosetta on Apple Silicon for its physical-device AOT compiler. The iOS scene adapter supports Xcode 27 while retaining the pinned Flutter version.

The generated Flutter/Rust bridge must match upstream source commit `5406950b02c102fadb917177d4c7b37615f86340`. `scripts/ios/fetch-bridge.sh` downloads its upstream CI artifact using authenticated `gh`. If that artifact expires, regenerate it using the pinned revision's `.github/workflows/bridge.yml`. Regenerate the bridge whenever changing Rust FFI declarations.

With an iPhone simulator booted:

```sh
scripts/ios/build.sh simulator
```

Set `SIMULATOR_ID` to choose a particular booted simulator. The script builds, installs and launches `io.dafacility.rustdesk.glinet`, using ad-hoc signing so Keychain is available. It uses one ARM64 architecture to avoid an incompatibility between Flutter 3.24's multi-architecture `lipo` invocation and Xcode 27.

Build an unsigned physical-device app:

```sh
scripts/ios/build.sh device
```

The initial Rust core build uses software codecs. GLKVM H.264 uses the independent native WebRTC renderer. RustDesk hardware codec acceleration is not enabled by this build script.

## Installing on an iPhone

1. Add the Apple development account to Xcode and select a development team.
2. Connect and unlock the iPhone, accept Trust This Computer, and enable Developer Mode when iOS requests it.
3. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices` to obtain its identifier.
4. Set `DEVELOPMENT_TEAM` and `DEVICE_ID`, then run `scripts/ios/build.sh deploy`.

The deploy command makes a signed Release build, installs it and launches it. Release uses ahead-of-time compilation and does not depend on an old Flutter debug engine's JIT support on recent physical iPhones. The bundle ID and display name are separate from the App Store RustDesk installation. The script never embeds an Apple account, signing key or KVM credential.

## Installing through Wireless Wire

Wireless Wire v1 exposes usbmux services to libimobiledevice, not to Xcode or Finder. A phone attached through the bridge can therefore remain unavailable in `devicectl` while installation works.

With the Wireless Wire client already configured, the phone unlocked and trusted, and its device registration included in the development provisioning profile:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/ios/build.sh wireless-deploy
```

The command makes a signed Release app, packages `flutter/build/ios-device/Access.ipa` without macOS metadata files, and installs it through `ideviceinstaller`. Open Access on the iPhone afterward. Set `WIRELESS_WIRE` if its launcher is not at `~/.local/bin/wireless-wire`. The script does not alter the bridge, tokens or pairing records.

## Verification

The focused test suite is `flutter test test/glinet_kvm_test.dart test/glinet_clients_test.dart test/glinet_login_test.dart test/glinet_pointer_test.dart`. It covers address validation, profile serialization, physical key mapping, coordinate bounds, login-cookie forwarding, input events, text injection and key/button release on disconnect. The UI tests save a client through the editor, verify it appears under Connection, reload its definition from disk, and check that a failed screen-awake plugin cannot freeze sign-in. Protocol tests use a local fixture; passing them alone does not establish hardware compatibility.

Verified on 2026-10-05:

- Fourteen focused tests pass, including trackpad swipes without clicks, taps at the current pointer, physical-mouse button release, two-finger scrolling in all four directions without clicks or zoom, pinch zoom/reset with scaled pointer motion, and equal control spacing in both orientations. Password tests verify masked prefill, forgetting a saved password, and separation by client, origin and username. The sign-in regression test fails on the original implementation and passes with the fix. Analysis reports no issues in the KVM modules or tests; including the renamed Home page reports only its two pre-existing WillPopScope deprecation notices.
- The full app builds and runs on an ARM64 iPhone simulator with iOS 27. The Connection screen retains RustDesk's ID field and peer tabs and adds GL.iNet clients.
- A native simulator smoke test using the production KVM transport and renderer authenticated to a Comet Q over Tailscale and received 1920×1080 H.264 video.
- The same native test sent absolute mouse movement and verified keyboard input by toggling the connected Mac's Caps Lock LED state, then restoring its original state. Text injection, clicks and drags have protocol coverage but still need interactive hardware acceptance testing.
- A native simulator test reproduces a screen-awake plugin channel mismatch before login. Pinning the Dart interface to the native plugin's matching version fixes it. KVM sessions also tolerate screen-awake failures so they cannot block login or cleanup.
- The native transport rejects the Comet Q's untrusted certificate, closes that connection, then authenticates and opens the input socket after pinning the verified certificate. Screen-awake enable and disable both succeed.
- The Release iPhone app builds, signs and passes `codesign --verify --deep --strict`. Installation through Wireless Wire completed at 100%, and querying the phone confirms Access build 70 is installed with the pointer and full-screen layout update. The user confirmed that it opens on the physical phone. The bridge cannot start the iOS 27 debugserver, so opening the app remains a manual step. The user confirmed video and login work on build 69. The user confirmed that build 70 works well on the phone. Build 71 with the gesture update was installed and launched over direct USB.
- A native test opens the production session page, logs into the Comet Q, receives video and confirms the session has no AppBar. Landscape screenshots verify the enlarged video and side controls. A further native test pinches the production session to 200%, verifies the percentage button, taps it, and confirms the zoom returns to 100%.
- Signed Release build 72 includes Remember password and is packaged as `flutter/build/ios-device/Access-build72.ipa`. It passes signature verification and awaits the phone reconnecting through Wireless Wire.
- A native Keychain test logs into the Comet Q through the production session page, saves the password, relaunches the app, verifies masked prefill and then unchecks Remember password to verify deletion.
- Signed build 73 includes account address books and is packaged as `flutter/build/ios-device/Access-build73.ipa`, awaiting the phone reconnecting through Wireless Wire.
- The included API server passes three integration tests covering authentication, ownership isolation, persistence, RustDesk CRUD/tags/pagination and KVM validation. Browser testing signs into a disposable account and saves/reloads a RustDesk connection and Comet X. Native simulator testing uses the unmodified RustDesk login/address-book models to authenticate and add/reload/delete a peer, then uses the account KVM editor to add a KVM and reload it from the server. A Flutter test checks account/server isolation of Keychain identities.
- Comet X hardware is not available for testing. Four-port switching remains unverified on hardware.

The Device Hub accessibility interface timed out, so simulator screen rendering was inspected with `simctl` screenshots. The saved-client workflow has widget test coverage. Real-device tests do not yet cover every session control, background transition or reconnect.

## Regression surface

- `connection_page.dart` adds an iOS-only GL.iNet section. Existing RustDesk connection methods remain unchanged.
- `settings_page.dart` adds the iOS-only client editor entry, respecting disabled settings.
- `home_page.dart` uses Da Facility Access as the iOS screen title. Other platforms keep their existing title.
- `pubspec.yaml` and dependency locks add WebRTC and the direct SHA-256 dependency. They also pin the existing screen-awake plugin and its Dart interface to matching versions, which changes shared screen-awake calls. The lock files resolve the existing declared dependencies and Flutter test packages against the pinned Flutter 3.24.5 SDK; this affects shared dependency resolution.
- The iOS project selects the correct Rust archive for simulator/device, raises its deployment target to iOS 15, and uses a distinct bundle ID and display name. The Podfile raises pod deployment targets to match Xcode 27. Info.plist adds local-network permission text and the required scene manifest. The app-icon PNGs change only for the requested grayscale branding.
- `AppDelegate.swift` starts and registers plugins with an explicit Flutter engine. New `SceneDelegate.swift` attaches its window and forwards scene lifecycle and URL events. This startup change is required because iOS 27 terminates applications that do not adopt scenes. Cold-start RustDesk deep links need additional acceptance testing.
- The libvpx overlay changes only ARM64 simulator builds because its upstream iOS target selects the physical-device SDK. Other libvpx builds retain the prior path.
- New KVM state and protocol code live in `flutter/lib/glinet`. `kvm_session_page.dart` catches screen-awake failures and includes initial cleanup in its connection error handling, preventing the reported sign-in freeze. It also uses the new feature-local pointer and viewport widgets, manages the drag button, and hides/restores system overlays during KVM sessions. These changes implement the requested trackpad controls and full-screen layout without changing RustDesk remote sessions. `kvm_pointer.dart` now handles multi-touch scrolling and zoom while mapping physical and touch pointer input through the zoomed view. `kvm_session_page.dart` owns the zoom value and reset indicator. `kvm_session_viewport.dart` distributes rail controls evenly, including edge gaps. All three changes are limited to KVM interaction and layout. No RustDesk session protocol, server configuration or peer storage was replaced.

- The remember-password change adds a Keychain channel registration in `AppDelegate.swift` and compiles `KvmKeychain.swift` through `Runner.xcodeproj/project.pbxproj`. These iOS startup/build hooks are required to expose native Keychain access. `kvm_session_page.dart` loads saved credentials, provides the checkbox and saves only after successful authentication. `kvm_profile.dart` scopes credentials and removes them when a client identity changes or is deleted. The new `kvm_password_store.dart` is the Dart channel wrapper. Existing RustDesk peer-password storage is unchanged.
- `scripts/ios/build.sh` now ad-hoc signs simulator builds so iOS Keychain access works. Device signing is unchanged.

Known limits include English-only new labels, manual reconnect, no separate 2FA challenge UI beyond Comet Q touchscreen approval, no video transport fallback, and unverified Comet X hardware behavior. Use the device console for features not yet implemented.

The account-address-book change modifies three existing runtime files. `common/widgets/address_book.dart` adds an iOS-only, capability-gated GL.iNet row. `glinet/kvm_clients_page.dart` exposes the existing editor through an additive helper, leaving local editing unchanged. `glinet/kvm_session_page.dart` accepts an optional trust-save callback so account entries save certificate pins to the account instead of entering the local client list; sessions without that callback keep local storage. The new API/page modules and `services/address-book` contain the remaining implementation. RustDesk authentication, peer models, ID/relay routing and remote-session code are unchanged.
