cask "beta-display" do
  arch arm: "arm64", intel: "x86_64"

  version "1.1.0"
  sha256 arm:   "1ea96a441f2b582ace3b136d271559ef75641b6ef347f8503ce95b7357a04562",
         intel: "659ec6acb8a412194f943af1b0b268cba2ac2e8a51a1bff934740d99adebcbda"

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
    "~/Library/Preferences/io.github.ysdj.betadisplay.plist",
    "~/Library/Application Support/BetaDisplay",
  ]
end
