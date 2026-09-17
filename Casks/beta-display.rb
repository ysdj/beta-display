cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.14"
  sha256 arm:   "ba1b7c1afe1ac36baa346725b0447b2955ac3b76f09a169a697182b4ce50e697",
         intel: "0954262e0af616d4384974cc6b668310c9ed3880876decbb11a17c313f4dace0"

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
