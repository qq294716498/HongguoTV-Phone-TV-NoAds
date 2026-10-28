import Cocoa
import FlutterMacOS
import OpenGL.GL3
import CoreVideo

class MainFlutterWindow: NSWindow {
  private var playbackActivity: NSObjectProtocol?
  private var deviceChannel: FlutterMethodChannel?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    deviceChannel = FlutterMethodChannel(name: "duanju/device", binaryMessenger: flutterViewController.engine.binaryMessenger)
    deviceChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "supportsHardwareVideoOutput" {
        result(self.supportsHardwareVideoOutput())
      } else if call.method == "setPlaybackScreenOn" {
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        if let activity = self.playbackActivity {
          ProcessInfo.processInfo.endActivity(activity)
          self.playbackActivity = nil
        }
        if enabled {
          self.playbackActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Video playback")
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }
  private func supportsHardwareVideoOutput() -> Bool {
    let attributes: [CGLPixelFormatAttribute] = [
      kCGLPFAOpenGLProfile,
      CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
      kCGLPFAAccelerated, kCGLPFADoubleBuffer,
      kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 64),
      kCGLPFAColorFloat, kCGLPFABackingStore,
      kCGLPFAAllowOfflineRenderers, kCGLPFASupportsAutomaticGraphicsSwitching,
      CGLPixelFormatAttribute(rawValue: 0)
    ]
    var count: GLint = 0
    var format: CGLPixelFormatObj?
    guard CGLChoosePixelFormat(attributes, &format, &count) == kCGLNoError,
          let format = format else { return false }
    defer { CGLReleasePixelFormat(format) }
    var context: CGLContextObj?
    guard CGLCreateContext(format, nil, &context) == kCGLNoError,
          let context = context else { return false }
    defer { CGLReleaseContext(context) }
    var cache: CVOpenGLTextureCache?
    return CVOpenGLTextureCacheCreate(kCFAllocatorDefault, nil, context, format, nil, &cache) == kCVReturnSuccess && cache != nil
  }

}
