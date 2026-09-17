cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.16"
  sha256 arm:   "27e16cf57a57af1328dc9ae435705b0bc2cb6266bd0059dce8c51969211cdcc6",
         intel: "6a8b0497f3c7b994bd6dc9302a05276f805746cb6551bd3c2d468c275ad86cb2"

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
