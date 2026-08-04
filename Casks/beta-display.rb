cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.9"
  sha256 arm:   "313aba3dee0a1f493d8c0c319b12000fd27aed5d8252582359edd970aad6437b",
         intel: "3cde888538079e6ae5d01915837d7f15bde8f7575106e08985c2d9e487daac3e"

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
