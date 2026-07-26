cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.6"
  sha256 arm:   "cef317560f267d5fa89cfac1ce36bd55e26857917fb4d5e772405bd1f96f4388",
         intel: "efc80d54686a27fc940ed529a6a9f23749026c8d6d6472ad8cd165b835e5ea62"

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
