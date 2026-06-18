# frozen_string_literal: true

# Homebrew formula for launch-inspector (LaunchInspector.app).
#
# This file lives in the SOURCE repo for reference, but it must be COPIED into
# the tap repo (github.com/vincentbattez/homebrew-tap/Formula/) to actually be
# usable via `brew install`. See the source repo's docs for the workflow.
#
# Update procedure on each new release:
#   1. tag a new version on the source repo (e.g. v0.1.1)
#   2. compute the tarball sha256:
#        curl -sL https://github.com/vincentbattez/launchs-and-crons-inspector/archive/refs/tags/v0.1.1.tar.gz | shasum -a 256
#   3. bump `url` and `sha256` below
#   4. commit + push to the tap repo
#   5. users get the update with `brew update && brew upgrade launch-inspector`

class LaunchInspector < Formula
  desc "macOS app that lists your cron jobs and launchd plists, with state and schedule"
  homepage "https://github.com/vincentbattez/launchs-and-crons-inspector"
  url "https://github.com/vincentbattez/launchs-and-crons-inspector/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "933d50cc7b381cf496cd3a62e722b1a2bb8b99fa44cd91ee7ea27f9c37654c98"
  license "MIT"
  head "https://github.com/vincentbattez/launchs-and-crons-inspector.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma # Package.swift targets macOS 14+

  APP_BUNDLE_NAME = "LaunchInspector.app"

  def install
    # Compile the SwiftUI app from source with SwiftPM. Building locally (rather
    # than shipping a prebuilt binary) means the result carries no quarantine
    # xattr, so an ad-hoc signature is enough for Gatekeeper to launch it without
    # an Apple Developer ID.
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin_path = ".build/release/LaunchInspector"

    # Wrap the executable into a minimal .app bundle so it's launchable from
    # Finder, Spotlight, or Launchpad once symlinked into /Applications/.
    app = libexec/APP_BUNDLE_NAME
    macos_dir = app/"Contents/MacOS"
    macos_dir.mkpath
    (app/"Contents/Resources").mkpath

    cp bin_path, macos_dir/"LaunchInspector"
    cp "Resources/AppIcon.icns", app/"Contents/Resources/AppIcon.icns"
    (app/"Contents/Info.plist").write info_plist_content

    # Ad-hoc sign so Gatekeeper accepts the bundle without an Apple Developer ID.
    system "/usr/bin/codesign", "--force", "--deep", "--sign", "-", app

    # Expose the headless modes (`launch-inspector --dump` / `--dump-json`) on PATH.
    (bin/"launch-inspector").write <<~SH
      #!/bin/bash
      exec "#{opt_libexec}/#{APP_BUNDLE_NAME}/Contents/MacOS/LaunchInspector" "$@"
    SH
    chmod 0755, bin/"launch-inspector"
  end

  def caveats
    <<~EOS
      ▸ Make it launchable from Finder / Spotlight / Launchpad:
          ln -sf "#{opt_libexec}/#{APP_BUNDLE_NAME}" /Applications/

        Then Cmd+Space → "LaunchInspector".

      ▸ Headless modes from the terminal:
          launch-inspector --dump        # plain-text list
          launch-inspector --dump-json   # full JSON export

      Note: the app is read-only by default. Enable/Disable and Delete are explicit,
      confirmation-gated actions that modify launchd (admin password for /Library items).
    EOS
  end

  def info_plist_content
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>CFBundleDisplayName</key>
          <string>LaunchInspector</string>
          <key>CFBundleName</key>
          <string>LaunchInspector</string>
          <key>CFBundleExecutable</key>
          <string>LaunchInspector</string>
          <key>CFBundleIdentifier</key>
          <string>com.vincentbattez.launch-inspector</string>
          <key>CFBundleIconFile</key>
          <string>AppIcon</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleShortVersionString</key>
          <string>#{version}</string>
          <key>CFBundleVersion</key>
          <string>#{version}</string>
          <key>LSMinimumSystemVersion</key>
          <string>14.0</string>
          <key>LSApplicationCategoryType</key>
          <string>public.app-category.developer-tools</string>
          <key>NSHumanReadableCopyright</key>
          <string>© 2026 Vincent Battez. MIT License.</string>
          <key>NSHighResolutionCapable</key>
          <true/>
      </dict>
      </plist>
    XML
  end

  test do
    macos_dir = libexec/APP_BUNDLE_NAME/"Contents/MacOS"
    assert_match(/Mach-O/, shell_output("file -b #{macos_dir}/LaunchInspector"))
    assert_path_exists libexec/APP_BUNDLE_NAME/"Contents/Info.plist"
    system "/usr/bin/codesign", "--verify", libexec/APP_BUNDLE_NAME
  end
end
