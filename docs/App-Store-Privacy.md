# App Store privacy notes

Spoon includes Firebase Analytics and Firebase Crashlytics 12.17.0. Both
services are disabled until the user explicitly allows technical data
collection in the first-launch dialog or in Settings. The preference can be
revoked at any time.

Spoon does not set a Firebase user ID and does not attach repository URLs,
working-copy paths, file contents, credentials, commit messages, or diagnostic
exports as custom Firebase values or logs.

Before submitting a build, make the App Store Connect privacy answers and the
public privacy policy consistent with the Firebase SDKs linked by that build.
At minimum, review Apple's Diagnostics / Crash Data and Usage Data / Product
Interaction categories against Firebase's current Apple-platform disclosure
guide. Opt-in collection that remains enabled across launches still needs to be
disclosed.

References:

- https://firebase.google.com/docs/ios/app-store-data-collection
- https://developer.apple.com/app-store/app-privacy-details/
- https://firebase.google.com/docs/crashlytics/ios/customize-crash-reports
- https://firebase.google.com/docs/analytics/ios/configure-data-collection
