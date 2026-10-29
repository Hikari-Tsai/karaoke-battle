import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Desktop-sized UI: never smaller than 1100x700, open at 1440x900 (16:10,
    // which gives the 16:9 video pane room beside the HUD).
    self.minSize = NSSize(width: 1100, height: 700)
    if windowFrame.width < 1440 || windowFrame.height < 900 {
      var f = windowFrame
      f.size = NSSize(width: max(windowFrame.width, 1440), height: max(windowFrame.height, 900))
      self.setFrame(f, display: true)
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
