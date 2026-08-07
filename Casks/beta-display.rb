cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.11"
  sha256 arm:   "2e88f8ae3bd3e4ce414210d9d5eaa7708f379b0bc86a60dfdaeed7620696deaa",
         intel: "5bcea98de786713c5ee9a5f5cfcec7569d65f582c1e8d9fe429a2c7893c1c8ac"

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
