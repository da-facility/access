use crate::{Frame, Pixfmt};
use lazy_static::lazy_static;
use std::{io, sync::Mutex, time::Duration};

// Broadcast frames arrive from ReplayKit through `push_nv12`; the video
// service picks up the newest one. iOS gives a broadcast extension 50 MB, so
// frames are scaled down before conversion and only the latest is kept.
struct Latest {
    bgra: Vec<u8>,
    width: usize,
    height: usize,
    fresh: bool,
}

lazy_static! {
    static ref LATEST: Mutex<Latest> = Mutex::new(Latest {
        bgra: Vec::new(),
        width: 0,
        height: 0,
        fresh: false,
    });
    static ref SCALED: Mutex<Vec<u8>> = Default::default();
}

/// Stores one NV12 frame from the broadcast, scaled to at most `max_side`
/// pixels on its longer side.
pub fn push_nv12(
    y: &[u8],
    y_stride: usize,
    uv: &[u8],
    uv_stride: usize,
    width: usize,
    height: usize,
    max_side: usize,
) -> io::Result<()> {
    if width == 0 || height == 0 || y.len() < y_stride * height {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let longest = width.max(height);
    let (w, h) = if max_side > 0 && longest > max_side {
        (
            (width * max_side / longest) & !1,
            (height * max_side / longest) & !1,
        )
    } else {
        (width & !1, height & !1)
    };
    let mut scaled = SCALED.lock().unwrap();
    let uv_w = w / 2 * 2;
    scaled.resize(w * h + uv_w * (h / 2), 0);
    let (dst_y, dst_uv) = scaled.split_at_mut(w * h);
    let mut latest = LATEST.lock().unwrap();
    latest.bgra.resize(w * h * 4, 0);
    let result = unsafe {
        let scaled_ok = crate::NV12Scale(
            y.as_ptr(),
            y_stride as _,
            uv.as_ptr(),
            uv_stride as _,
            width as _,
            height as _,
            dst_y.as_mut_ptr(),
            w as _,
            dst_uv.as_mut_ptr(),
            uv_w as _,
            w as _,
            h as _,
            crate::FilterMode::kFilterBox,
        );
        if scaled_ok != 0 {
            scaled_ok
        } else {
            crate::NV12ToARGB(
                dst_y.as_ptr(),
                w as _,
                dst_uv.as_ptr(),
                uv_w as _,
                latest.bgra.as_mut_ptr(),
                (w * 4) as _,
                w as _,
                h as _,
            )
        }
    };
    if result != 0 {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("libyuv failed: {result}"),
        ));
    }
    latest.width = w;
    latest.height = h;
    latest.fresh = true;
    Ok(())
}

fn size() -> (usize, usize) {
    let latest = LATEST.lock().unwrap();
    (latest.width, latest.height)
}

pub struct Capturer {
    display: Display,
    bgra: Vec<u8>,
    started: bool,
}

impl Capturer {
    pub fn new(display: Display) -> io::Result<Capturer> {
        Ok(Capturer {
            display,
            bgra: Vec::new(),
            started: false,
        })
    }

    pub fn width(&self) -> usize {
        self.display.width()
    }

    pub fn height(&self) -> usize {
        self.display.height()
    }
}

impl crate::TraitCapturer for Capturer {
    fn frame<'a>(&'a mut self, _timeout: Duration) -> io::Result<Frame<'a>> {
        let mut latest = LATEST.lock().unwrap();
        // ReplayKit only sends frames when the screen changes, so a new
        // capturer starts from the last one it delivered.
        if !latest.fresh && self.started {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        // A rotation changes the size; the video service restarts on a new
        // display size, so report this frame as unavailable until then.
        if latest.width != self.width() || latest.height != self.height() {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        latest.fresh = false;
        self.started = true;
        self.bgra.clear();
        self.bgra.extend_from_slice(&latest.bgra);
        drop(latest);
        Ok(Frame::PixelBuffer(PixelBuffer {
            data: &self.bgra,
            width: self.width(),
            height: self.height(),
            stride: vec![self.width() * 4],
        }))
    }
}

pub struct PixelBuffer<'a> {
    data: &'a [u8],
    width: usize,
    height: usize,
    stride: Vec<usize>,
}

impl<'a> crate::TraitPixelBuffer for PixelBuffer<'a> {
    fn data(&self) -> &[u8] {
        self.data
    }

    fn width(&self) -> usize {
        self.width
    }

    fn height(&self) -> usize {
        self.height
    }

    fn stride(&self) -> Vec<usize> {
        self.stride.clone()
    }

    fn pixfmt(&self) -> Pixfmt {
        Pixfmt::BGRA
    }
}

pub struct Display {
    width: usize,
    height: usize,
}

impl Display {
    pub fn primary() -> io::Result<Display> {
        let (width, height) = size();
        if width == 0 || height == 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        Ok(Display { width, height })
    }

    pub fn all() -> io::Result<Vec<Display>> {
        Ok(vec![Display::primary()?])
    }

    pub fn width(&self) -> usize {
        self.width
    }

    pub fn height(&self) -> usize {
        self.height
    }

    pub fn origin(&self) -> (i32, i32) {
        (0, 0)
    }

    pub fn is_online(&self) -> bool {
        true
    }

    pub fn is_primary(&self) -> bool {
        true
    }

    pub fn name(&self) -> String {
        "iPhone".into()
    }
}
