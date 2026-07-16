class BlueTicker < Formula
  desc "Japanese stock analysis CLI tool powered by EDINET"
  homepage "https://github.com/sollahiro/blue-ticker"
  url "https://github.com/sollahiro/blue-ticker/releases/download/v26.5.3/blue-ticker-macos-arm64.tar.gz"
  version "26.5.3"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # Updated by CI

  def install
    bin.install "ticker"
    bin.install_symlink "ticker" => "blt"
  end

  test do
    system "#{bin}/ticker", "--version"
    system "#{bin}/blt", "--version"
    assert_match "7203", shell_output("#{bin}/ticker search 7203")
  end
end
