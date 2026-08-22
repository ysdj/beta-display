cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.13"
  sha256 arm:   "ee85ec7e9e8b8d638f3f03ebf0fb1641547d126a2eae931d9261c5086e65a802",
         intel: "096ed8f79ff540c338be69b575a43f8ffaacd5fd9584e8cc2af6c202e4c20a6d"

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
