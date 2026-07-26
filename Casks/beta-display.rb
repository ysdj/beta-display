cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.5"
  sha256 arm:   "10b8b0e0e1ba1819fec9ea116788bafe6c79923e1e437daa123e7ac77d4cd450",
         intel: "2eac875db8ad5e01b01a042f61a5e432fe1a30b61e372727c0826505c781e968"

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
