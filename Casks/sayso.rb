# Homebrew cask for SaySo. The repository works as its own tap:
#   brew tap pepebits/sayso https://github.com/Pepebits/sayso
#   brew trust pepebits/sayso
#   brew install --cask pepebits/sayso/sayso
# scripts/release.sh updates the version and checksum for each release.
cask "sayso" do
  version "0.3.0"
  sha256 "b31a0b08d819fb0ed3c44ca17f97996571af5e24d9912f3415f04e10afd45d5a"

  url "https://github.com/Pepebits/sayso/releases/download/v#{version}/SaySo-#{version}.dmg"
  name "SaySo"
  desc "Voice dictation and an AI agent reachable through Telegram"
  homepage "https://github.com/Pepebits/sayso"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "SaySo.app"

  uninstall quit: "com.pepebits.sayso"

  zap trash: [
    "~/Library/Application Support/SaySo",
    "~/Library/Caches/com.pepebits.sayso",
    "~/Library/HTTPStorages/com.pepebits.sayso",
    "~/Library/Preferences/com.pepebits.sayso.plist",
    "~/Library/Saved Application State/com.pepebits.sayso.savedState",
    "~/Library/WebKit/com.pepebits.sayso",
  ]
end
