cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.1"
  sha256 arm:   "5dddff8d5c9c32ad08de94bc27934f985877ab5f202a28ca6ceb0d83f4c60c17",
         intel: "4b5dac25a850a2082da37f8e4c7e582bfbd8a2753f9b4696f7e44aac866dd576"

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
