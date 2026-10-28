import Cocoa
import FlutterMacOS

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
      if call.method == "setPlaybackScreenOn" {
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
}
