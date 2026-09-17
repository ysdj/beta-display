cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.15"
  sha256 arm:   "eff5ba59981e4f13a8bc9188ddf0374b0a540beadb4e004bf56eb7656e033281",
         intel: "c715e304ae7bbd390911e50f2444caba4ae9dd24813656db1886275de82fdc7b"

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
