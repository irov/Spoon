# Spoon

Spoon is a native, sandbox-first Subversion client for Apple silicon Macs.
It uses the official Subversion command-line client as the source of truth
while presenting working-copy changes, history, repository browsing, and
common SVN workflows in a responsive macOS interface.

## Product target

- macOS 15 and newer
- Apple silicon
- Mac App Store distribution
- English and Russian localization
- Bundle identifier: `com.wonderland.spoon`

The product and technical specification is available in
[`docs/Spoon-Specification-RU.md`](docs/Spoon-Specification-RU.md).

## Build

1. Install Xcode 26 or newer and XcodeGen.
2. Run `Tools/vendor-toolchain.sh` to create the pinned arm64 Subversion/OpenSSH
   payload, or use the checked-in payload after validating `Vendor/Toolchain/SHA256SUMS`.
3. Run `xcodegen generate`.
4. Open `Spoon.xcodeproj`, or build with:

   ```sh
   xcodebuild -project Spoon.xcodeproj -scheme Spoon \
     -destination 'platform=macOS,arch=arm64' test
   ```

Release archives use Automatic Signing. Set `DEVELOPMENT_TEAM` in `project.yml`
to the App Store Connect team that owns `com.wonderland.spoon` before generating
the project.

## Security and privacy

Spoon runs in App Sandbox. Working-copy access is retained with app-scoped
security bookmarks and handed to the sandbox-inheriting SVN runner over stdin.
Credentials are stored in Keychain; passwords, bookmark data, and commit
messages are never placed in command arguments, the environment, or diagnostics.
Firebase Analytics and Crashlytics are disabled until the user explicitly
allows technical data collection on first launch or in Settings. Spoon does not
attach repository contents, file contents, credentials, commit messages, user
identifiers, or custom path logs to Firebase. Diagnostic export remains a
manual, local-only action.

## License

Spoon source code is available under the MIT License. Bundled third-party
software remains subject to its own licenses; release builds include the
corresponding notices.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the bundled toolchain.
