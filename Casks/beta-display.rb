cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.3"
  sha256 arm:   "161de109f4d76f17f6a144709cfdb7768dd490bb1a792a2457c5c22608f3687f",
         intel: "6d50870b154beccdadfc78a8577df1538df313fb075aed6d8b5bcccb17d7d30b"

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
