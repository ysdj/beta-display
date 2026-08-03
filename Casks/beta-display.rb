cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.8"
  sha256 arm:   "2e7d37614fd998af4006925d58bf6b36d31ed7f7cbc7f9a9b48fd7c29ad3bd08",
         intel: "00936c4b59e4309c9bd57ab908f47cd077652a7c04f80d5172710dd43c780fe3"

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
