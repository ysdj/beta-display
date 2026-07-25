cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.2"
  sha256 arm:   "f3ffb9f61281716ae46e1480e1aa1ac66b31268fd5d51ffb659e742483c664c1",
         intel: "0fa0acf74018aa9c6066b6d0871e5d779b2d4fb608033cf3ceac5a6e52fab9d0"

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
