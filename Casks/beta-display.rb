cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.10"
  sha256 arm:   "21559d9545228c8d45263b0b722b52c9c5d2b1bcac101b9e6075faa1ca870e89",
         intel: "9628a50ba2c79e2b4c5145863bff72aece8648f0ca779617617d2159a97dab27"

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
