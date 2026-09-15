class Sino < Formula
  desc "Native macOS menu-bar system monitor"
  homepage "https://github.com/Aduersarius/sino"
  url "https://github.com/Aduersarius/sino/archive/refs/heads/main.tar.gz"
  version "0.1.0"
  license "MIT"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  def install
    chmod "+x", "build.sh"
    system "./build.sh"
    prefix.install "Sino.app"
  end

  def caveats
    <<~EOS
      Unsigned (ad-hoc). Copy to /Applications and open:
        cp -R #{opt_prefix}/Sino.app /Applications && open /Applications/Sino.app
    EOS
  end

  test do
    assert_path_exists prefix/"Sino.app/Contents/MacOS/Sino"
  end
end
