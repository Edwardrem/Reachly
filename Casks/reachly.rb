# Homebrew cask template. The release workflow substitutes the version and
# checksum and pushes it to the tap repository (default Edwardrem/homebrew-reachly).
cask "reachly" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/Edwardrem/Reachly/releases/download/v#{version}/Reachly-#{version}.dmg"
  name "Reachly"
  desc "Free, open-source SSH client and terminal for macOS with a built-in Claude agent"
  homepage "https://edwardrem.github.io/Reachly/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Reachly.app"

  zap trash: [
    "~/Library/Application Support/Reachly",
    "~/Library/Preferences/io.github.edwardrem.reachly.plist",
  ]
end
