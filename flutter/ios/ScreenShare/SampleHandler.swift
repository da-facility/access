import CoreMedia
import ReplayKit

/// Receives the screen from ReplayKit and serves it to RustDesk viewers.
/// The RustDesk host runs inside this extension, because iOS suspends the
/// main app while the user is in other apps.
class SampleHandler: RPBroadcastSampleHandler {
  private var lastFrame: CFAbsoluteTime = 0

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    let fm = FileManager.default
    guard let settings = ScreenShareStore.read(ScreenShareStore.settings),
      let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      fail("Open Access and start sharing from its Share screen tab.")
      return
    }
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try settings.write(to: dir.appendingPathComponent("share.json"), options: .atomic)
    } catch {
      fail("Screen sharing could not start: \(error.localizedDescription)")
      return
    }
    let started = dir.path.withCString { access_share_start($0) }
    if started != 0 {
      fail("Screen sharing could not start. Open Access and try again.")
      return
    }
    if let status = try? Data(contentsOf: dir.appendingPathComponent("share-status.json")) {
      ScreenShareStore.write(ScreenShareStore.status, status)
    }
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType
  ) {
    guard sampleBufferType == .video,
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
      CVPixelBufferGetPlaneCount(pixelBuffer) == 2
    else { return }
    // Encoding is the expensive part; 15 frames a second is plenty to watch.
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastFrame < 1.0 / 15 { return }
    lastFrame = now
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
      let uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else { return }
    access_share_frame(
      y.assumingMemoryBound(to: UInt8.self),
      CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
      uv.assumingMemoryBound(to: UInt8.self),
      CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
      CVPixelBufferGetWidth(pixelBuffer),
      CVPixelBufferGetHeight(pixelBuffer))
  }

  override func broadcastFinished() {
    access_share_stop()
  }

  private func fail(_ message: String) {
    finishBroadcastWithError(
      NSError(
        domain: "io.dafacility.access.share", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]))
  }
}
