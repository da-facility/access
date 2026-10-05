#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
mode="${1:-simulator}"
case "$mode" in simulator|device|deploy|wireless-deploy) ;; *) echo 'Usage: build.sh [simulator|device|deploy|wireless-deploy]'; exit 2;; esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$HOME/.cargo/bin:$PATH"
tools_root="${IOS_TOOLS_ROOT:-$repo_root/../.toolchains}"
flutter="$tools_root/flutter/bin/flutter"
vcpkg="$tools_root/vcpkg/vcpkg"
if [[ ! -x "$flutter" || ! -x "$vcpkg" ]]; then
  echo 'Flutter or vcpkg is missing. See docs/glinet-ios.md for the pinned setup.' >&2
  exit 1
fi
if [[ ! -f "$repo_root/flutter/lib/generated_bridge.dart" ]]; then
  "$repo_root/scripts/ios/fetch-bridge.sh"
fi
cd "$repo_root"
git submodule update --init --recursive
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"
if [[ "$mode" == simulator ]]; then
  target=aarch64-apple-ios-sim
  installed="$tools_root/vcpkg/installed-ios-simulator"
  if [[ ! -f "$installed/arm64-ios/lib/libopus.a" ]]; then
    "$vcpkg" install --triplet arm64-ios --overlay-triplets="$repo_root/scripts/ios/simulator-triplets" --x-install-root="$installed"
  fi
  if [[ ! -f "$installed/arm64-ios/lib/libsodium.a" ]]; then
    "$vcpkg" install libsodium:arm64-ios --classic --overlay-triplets="$repo_root/scripts/ios/simulator-triplets" --x-install-root="$installed"
  fi
  export SODIUM_USE_PKG_CONFIG=1 PKG_CONFIG_ALLOW_CROSS=1 LIBSODIUM_STATIC=1
  export PKG_CONFIG_PATH_aarch64_apple_ios_sim="$installed/arm64-ios/lib/pkgconfig"
  export BINDGEN_EXTRA_CLANG_ARGS='--target=arm64-apple-ios15.0-simulator'
else
  target=aarch64-apple-ios
  installed="$tools_root/vcpkg/installed-ios-device"
  if [[ ! -f "$installed/arm64-ios/lib/libopus.a" ]]; then
    "$vcpkg" install --triplet arm64-ios --x-install-root="$installed"
  fi
  export BINDGEN_EXTRA_CLANG_ARGS='--target=arm64-apple-ios15.0'
fi
export VCPKG_INSTALLED_ROOT="$installed"
# magnum-opus reads VCPKG_ROOT/installed directly; use a separate root per SDK.
export VCPKG_ROOT="$tools_root/$target-vcpkg"
mkdir -p "$VCPKG_ROOT"
if [[ ! -e "$VCPKG_ROOT/installed" ]]; then ln -s "$installed" "$VCPKG_ROOT/installed"; fi
rustup target add --toolchain 1.81.0 "$target"
cargo +1.81.0 build --locked --features flutter --release --target "$target" --lib
cd "$repo_root/flutter"
"$flutter" pub get
"$flutter" build ios --config-only --no-codesign
cd ios
pod install

if [[ "$mode" == simulator ]]; then
  simulator_id="${SIMULATOR_ID:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; print(next(d["udid"] for group in json.load(sys.stdin)["devices"].values() for d in group if d["state"] == "Booted" and "iPhone" in d["name"]))')}"
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$repo_root/flutter/build/ios-simulator" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
  app="$repo_root/flutter/build/ios-simulator/Build/Products/Debug-iphonesimulator/Runner.app"
  xcrun simctl install "$simulator_id" "$app"
  xcrun simctl launch "$simulator_id" io.dafacility.rustdesk.glinet
elif [[ "$mode" == device ]]; then
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -sdk iphoneos \
    -destination generic/platform=iOS -derivedDataPath "$repo_root/flutter/build/ios-device" \
    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO
else
  : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team ID}"
  if [[ "$mode" == wireless-deploy ]]; then
    destination=generic/platform=iOS
  else
    : "${DEVICE_ID:?Set DEVICE_ID to the connected iPhone identifier from xcrun devicectl list devices}"
    destination="id=$DEVICE_ID"
  fi
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -sdk iphoneos \
    -destination "$destination" -derivedDataPath "$repo_root/flutter/build/ios-device" \
    -allowProvisioningUpdates ARCHS=arm64 DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic
  app="$repo_root/flutter/build/ios-device/Build/Products/Release-iphoneos/Runner.app"
  if [[ "$mode" == wireless-deploy ]]; then
    wireless_wire="${WIRELESS_WIRE:-$HOME/.local/bin/wireless-wire}"
    "$wireless_wire" doctor --side mac --require-device
    package_dir="$(mktemp -d -t access-ipa)"
    trap 'rm -rf "$package_dir"' EXIT
    mkdir "$package_dir/Payload"
    ditto --norsrc --noextattr "$app" "$package_dir/Payload/Runner.app"
    ipa="$repo_root/flutter/build/ios-device/Access.ipa"
    ditto -c -k --norsrc --noextattr --keepParent "$package_dir/Payload" "$ipa"
    "$wireless_wire" run -- ideviceinstaller install "$ipa"
    echo 'Access is installed. Open it on the iPhone. Wireless Wire v1 does not expose devices to Xcode.'
  else
    xcrun devicectl device install app --device "$DEVICE_ID" "$app"
    xcrun devicectl device process launch --device "$DEVICE_ID" io.dafacility.rustdesk.glinet
  fi
fi
