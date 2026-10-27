//! iOS screen sharing. A ReplayKit broadcast extension runs the RustDesk host
//! and feeds it the screen; iOS lets no app control other apps, so peers get
//! a view-only session. The extension passes its own data directory, holding
//! the `share.json` settings from the app, and gets its ID in
//! `share-status.json`.

use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    path::Path,
    time::Duration,
};

use base::config::keys;
use hbb_common::{
    bail,
    config::{self, Config},
    log, ResultType,
};

/// Longest side of the shared picture. Keeps encoding within the broadcast
/// extension's 50 MB memory limit.
const MAX_SIDE: usize = 1280;

const VIEW_ONLY_OPTIONS: [&str; 12] = [
    keys::OPTION_ENABLE_KEYBOARD,
    keys::OPTION_ENABLE_CLIPBOARD,
    keys::OPTION_ENABLE_FILE_TRANSFER,
    keys::OPTION_ENABLE_CAMERA,
    keys::OPTION_ENABLE_TERMINAL,
    keys::OPTION_ENABLE_REMOTE_PRINTER,
    keys::OPTION_ENABLE_AUDIO,
    keys::OPTION_ENABLE_TUNNEL,
    keys::OPTION_ENABLE_REMOTE_RESTART,
    keys::OPTION_ENABLE_RECORD_SESSION,
    keys::OPTION_ENABLE_BLOCK_INPUT,
    keys::OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION,
];

#[derive(serde::Deserialize)]
struct ShareSettings {
    #[serde(default)]
    options: HashMap<String, String>,
    password: String,
    #[serde(default)]
    device_name: String,
}

fn start(dir: *const c_char) -> ResultType<()> {
    if dir.is_null() {
        bail!("missing app group directory");
    }
    let dir = unsafe { CStr::from_ptr(dir) }.to_str()?.to_owned();
    *config::APP_DIR.write().unwrap() = dir.clone();
    {
        use hbb_common::env_logger::*;
        let _ = try_init_from_env(Env::default().filter_or(DEFAULT_FILTER_ENV, "info"));
    }
    let settings: ShareSettings =
        serde_json::from_slice(&std::fs::read(Path::new(&dir).join("share.json"))?)?;
    if settings.password.is_empty() {
        bail!("missing share password");
    }
    for (key, value) in settings.options {
        Config::set_option(key, value);
    }
    for key in VIEW_ONLY_OPTIONS {
        Config::set_option(key.to_owned(), "N".to_owned());
    }
    Config::set_option(keys::OPTION_APPROVE_MODE.to_owned(), "password".to_owned());
    Config::set_option(
        keys::OPTION_VERIFICATION_METHOD.to_owned(),
        "use-permanent-password".to_owned(),
    );
    if !Config::set_permanent_password(&settings.password) {
        bail!("could not set the share password");
    }
    *crate::common::DEVICE_NAME.lock().unwrap() = settings.device_name;
    let _ = crate::common::global_init();
    std::fs::write(
        Path::new(&dir).join("share-status.json"),
        serde_json::json!({ "id": Config::get_id() }).to_string(),
    )?;
    std::thread::spawn(|| crate::start_server(true));
    Ok(())
}

/// Starts the RustDesk host in the broadcast extension. Returns 0 on success.
#[no_mangle]
pub extern "C" fn access_share_start(dir: *const c_char) -> i32 {
    match start(dir) {
        Ok(()) => 0,
        Err(err) => {
            log::error!("screen sharing failed to start: {err}");
            1
        }
    }
}

/// Hands one NV12 screen frame from ReplayKit to the video service.
///
/// # Safety
/// `y` and `uv` must point to the frame's planes, valid for `height` and
/// `height / 2` rows of their strides.
#[no_mangle]
pub unsafe extern "C" fn access_share_frame(
    y: *const u8,
    y_stride: usize,
    uv: *const u8,
    uv_stride: usize,
    width: usize,
    height: usize,
) {
    if y.is_null() || uv.is_null() {
        return;
    }
    let y = std::slice::from_raw_parts(y, y_stride * height);
    let uv = std::slice::from_raw_parts(uv, uv_stride * height.div_ceil(2));
    if let Err(err) = scrap::push_nv12(y, y_stride, uv, uv_stride, width, height, MAX_SIDE) {
        hbb_common::throttled_log!(
            Duration::from_secs(10),
            warn,
            "dropped screen frame: {err}"
        );
    }
}

#[no_mangle]
pub extern "C" fn access_share_stop() {
    log::info!("screen sharing stopped");
}
