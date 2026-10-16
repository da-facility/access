# Access for Android

The Android app uses package ID `io.dafacility.access`, the Access launcher name,
and the grayscale icon from the iOS app. It can be installed alongside RustDesk.
This build targets ARM64 phones running Android 6 or later.

The Connection tab, Settings, and account address book expose the same GL.iNet
clients as iOS. Floating controls, direct touch, touchpad mode, local zoom/pan,
orientation selection, and reconnect after switching apps use the shared Flutter
implementation. Comet X port switching still requires hardware verification.

Remember password uses AES-GCM with an Android Keystore key. Encrypted entries
are stored in the app's no-backup directory, with the client identity authenticated
as associated data. Removing a saved password deletes its encrypted entry. App
uninstallation removes the stored credentials. Passwords and release signing keys
are never included in the repository or APK assets.

## Build

Use Flutter 3.27.4, JDK 17, Android SDK 36, NDK 27.1.12297006,
Rust 1.98.1, and cargo-ndk. Set `ANDROID_HOME`, `ANDROID_NDK_HOME`,
`ANDROID_NDK_ROOT`, `JAVA_HOME`, `VCPKG_ROOT`, and `PATH` for your machine.
On macOS, bindgen also needs `LIBCLANG_PATH` pointing to Xcode's toolchain library
directory. Keep Android's `local.properties` and `key.properties` local and ignored.
On macOS, set `AR` and `RANLIB` to the NDK's `llvm-ar` and `llvm-ranlib` before
compiling Rust. Apple's archive tools can silently produce an empty libsodium
archive for Android objects. A previous build with the wrong tools must first
run `cargo clean --release -p libsodium-sys --target aarch64-linux-android`.
The Android WebRTC plugin requires Flutter's `onSurfaceAvailable` API, introduced
in 3.27. Keep this Android SDK separate from the existing iOS build toolchain.
Use a separate checkout for Android and run `flutter pub get` there with 3.27.4
before building. Flutter's SDK-pinned development dependencies resolve differently
from the iOS SDK; do not replace the iOS checkout's lockfile or package cache.

From the repository root:

```sh
rustup target add --toolchain 1.98.1 aarch64-linux-android
./flutter/build_android_deps.sh arm64-v8a
cargo +1.98.1 ndk --platform 23 --target aarch64-linux-android rustc \
  --locked --release --lib --features flutter,hwcodec -- -C link-arg=-Wl,--no-undefined
mkdir -p flutter/android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/liblibrustdesk.so \
  flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
```

Also copy the NDK's ARM64 `libc++_shared.so` from its host-specific LLVM sysroot
to that same `jniLibs/arm64-v8a` directory. Configure a private release keystore
through the existing `flutter/android/key.properties` mechanism. Preserve that
key for future updates, which must be signed with the same certificate.

Build using Flutter with JDK 17, or invoke the Gradle wrapper with JDK 17 if
Flutter selects Android Studio's newer, incompatible JDK. For the latter, set
`flutter.buildMode=release`, `flutter.versionName`, and `flutter.versionCode` in
`local.properties`, then run from `flutter/android`:

```sh
RUSTUP_TOOLCHAIN=1.98.1 ./gradlew assembleRelease \
  -Ptarget-platform=android-arm64 -Psplit-per-abi=true -Ptarget=lib/main.dart \
  -Pdart-obfuscation=false -Ptrack-widget-creation=false -Ptree-shake-icons=true
```

The APK is written to `flutter/build/app/outputs/apk/release/app-arm64-v8a-release.apk`.
Verify it with Android build-tools `apksigner verify` and install it in an ARM64
emulator before distributing it. Serve only the dedicated download directory
through private Tailscale Serve, never the workspace or signing-key directory.

## Regression surface

Build 75 was checked on an ARM64 Android 16 emulator. The production app installed
and opened the Connection screen with Access branding and the GL.iNet KVM section.
A native Keystore smoke check passed save/read, read after process termination and
restart, and deletion. All 16 focused Flutter KVM tests passed with Flutter 3.27.4.
The APK signature verifies and its only packaged ABI is `arm64-v8a`. Flutter's ABI
split adds 2000 to the base version code, so build 75 is Android version code 2075.
Live KVM video/input and physical Android device acceptance remain unverified.

- Android `app/build.gradle` changes the app ID and raises the minimum API to 23
  for the Keystore AES implementation. Android manifest/resources change the
  launcher and accessibility-service labels and launcher icons.
- Android `MainActivity.kt` registers one password channel. Its implementation
  lives in the new `KvmPasswordStore.kt`; existing RustDesk native channels remain
  unchanged.
- Mobile `home_page.dart`, `connection_page.dart`, `settings_page.dart`, and shared
  `address_book.dart` enable the existing Access name and KVM entry points on
  Android. Their iOS behavior is unchanged.
- `access_book_page.dart` says secure storage instead of Keychain so its text is
  accurate on both platforms. Session input, video, and RustDesk protocol logic
  are unchanged.
