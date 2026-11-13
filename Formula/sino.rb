class Sino < Formula
  desc "Native macOS menu-bar system monitor"
  homepage "https://github.com/Aduersarius/sino"
  url "https://github.com/Aduersarius/sino/releases/download/v1.4.0/Sino.app.zip"
  sha256 "8992196b59b1b651e9171f562fae48a073098ee8b388365a10a549e2bed6a843"
  version "1.4.0"
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
    assert_equal "1.4.0",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' " \
                              "#{prefix}/Sino.app/Contents/Info.plist").strip
  end
end
