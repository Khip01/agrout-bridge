/// Bridge version string.
///
/// Resolved at compile time from the `PACKAGE_VERSION` environment variable
/// (passed via `--dart-define=PACKAGE_VERSION=x.y.z` in the build script).
/// Falls back to the hardcoded value below if the define is absent, so that
/// `dart run` and un-defines builds still show a version.
///
/// Keep the fallback in sync with `package.json` `version` when releasing.
const bridgeVersion = String.fromEnvironment(
  'PACKAGE_VERSION',
  defaultValue: '0.1.15',
);
