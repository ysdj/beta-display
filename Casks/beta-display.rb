cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.4"
  sha256 arm:   "8e246ad152885986d33e09dc7ff382f9bd77c0f919cafe89e468479eeb77be67",
         intel: "fe6ece3517220f64234e0a6bbdeed63b4dd8f4cd989d73d7927331599820b2ee"

  url "https://github.com/ysdj/beta-display/releases/download/v#{version}/BetaDisplay-#{version}-#{arch}.zip"
  name "Beta Display"
  desc "Native display controls"
  homepage "https://github.com/ysdj/beta-display"

  depends_on macos: :ventura

  app "Beta Display.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Beta Display.app"]
  end

  zap trash: [
    "~/Library/Application Support/BetaDisplay",
    "~/Library/Preferences/io.github.ysdj.betadisplay.plist",
  ]
end
