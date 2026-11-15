class Sino < Formula
  desc "Native macOS menu-bar system monitor"
  homepage "https://github.com/Aduersarius/sino"
  url "https://github.com/Aduersarius/sino/releases/download/v1.4.4/Sino.app.zip"
  sha256 "c30754ba8702513ae64955619bd085ddf3f83f9cc77d231caa2c8a4381a50752"
  version "1.4.4"
  license "MIT"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  # The app ships prebuilt: building from source would run build.sh, which installs into
  # /Applications and would escape the formula's prefix.
  def install
    prefix.install "Sino.app"
  end

  def caveats
    <<~EOS
      Sino is not notarized. Copy it to /Applications and open it once from Finder
      (Right-click → Open) so Gatekeeper remembers it:
        cp -R #{opt_prefix}/Sino.app /Applications/Sino.app
        open /Applications/Sino.app
    EOS
  end

  test do
    assert_path_exists prefix/"Sino.app/Contents/MacOS/Sino"
    assert_predicate prefix/"Sino.app/Contents/MacOS/Sino", :executable?
    assert_equal "1.4.4",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' " \
                              "#{prefix}/Sino.app/Contents/Info.plist").strip
  end
end
