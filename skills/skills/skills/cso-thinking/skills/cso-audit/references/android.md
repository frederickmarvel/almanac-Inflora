# Android security checklist

> Native Android app. Grounded in OWASP MASVS v2 (L1 + L2), MASTG (Mobile Application Security Testing Guide), Android Developer Documentation security guidance.

Read this file when the `android` profile is active.

## Threat outcomes we defend against

1. **On-device data theft** — backup leakage, world-readable storage, weak keychain usage
2. **Inter-app abuse** — exported components, deep-link hijacking, intent injection
3. **Network MitM** — cleartext traffic, missing pinning, weak TLS
4. **Reverse engineering / tampering** — no obfuscation, no integrity check (L2 only)
5. **Credential & key compromise** — hardcoded secrets, weak crypto, key in source

## Checklist (A-1 to A-10)

Mapped to MASVS-STORAGE, MASVS-CRYPTO, MASVS-AUTH, MASVS-NETWORK, MASVS-PLATFORM, MASVS-CODE, MASVS-RESILIENCE.

### A-1: Manifest hygiene — MASVS-PLATFORM
- **A-1.1** `android:allowBackup` set to `false` (or scoped via `android:fullBackupContent` / `android:dataExtractionRules`) for sensitive apps. Default `true` exfiltrates app data via `adb backup`.
- **A-1.2** `android:debuggable` not set to `true` in release builds. (Should be controlled by build type — verify release variant.)
- **A-1.3** `android:exported` explicitly set on every `<activity>`, `<service>`, `<receiver>`, `<provider>` (required since Android 12 / API 31).
  - `exported=true` only when intentional. Each exported component = inter-app attack surface.
- **A-1.4** Intent filters with `<action android:name="android.intent.action.VIEW">` + custom scheme / `https` (deep links) verify with **App Links** (`autoVerify="true"`) — prevents URL hijacking by other apps.
- **A-1.5** Permissions requested minimal — no `READ_CONTACTS`, `ACCESS_FINE_LOCATION`, `RECORD_AUDIO` etc. unless used. `SYSTEM_ALERT_WINDOW`, `WRITE_SETTINGS` rarely justified.
- **A-1.6** No `android:sharedUserId` (deprecated; allows cross-app data sharing).

### A-2: Storage — MASVS-STORAGE
- **A-2.1** No sensitive data in `SharedPreferences` without using **EncryptedSharedPreferences** (Jetpack Security).
- **A-2.2** No sensitive data in external storage (`getExternalFilesDir`, MediaStore) without explicit user consent + encryption.
- **A-2.3** Files created with `MODE_PRIVATE`; never `MODE_WORLD_READABLE` or `MODE_WORLD_WRITEABLE` (removed in modern API but check legacy code).
- **A-2.4** Database files (SQLite, Room) holding sensitive data use **SQLCipher** or equivalent.
- **A-2.5** Files in app cache directory are still readable on rooted device — sensitive caches encrypted.
- **A-2.6** Pasteboard (`ClipboardManager`) — sensitive values cleared after copy; consider `setPrimaryClipDescription` with `EXTRA_IS_SENSITIVE` (API 33+).
- **A-2.7** WebView caching of sensitive pages disabled (`setCacheMode(LOAD_NO_CACHE)`).

### A-3: Logging
- **A-3.1** `Log.d` / `Log.v` / `println` with sensitive values stripped in release builds (use ProGuard rule or a logging wrapper).
- **A-3.2** No PII / tokens / passwords / session IDs in logs.

### A-4: Cryptography — MASVS-CRYPTO
- **A-4.1** No MD5, SHA-1, DES, 3DES, RC4 for security purposes.
- **A-4.2** AES-GCM (or AES-CBC with HMAC) with **per-message random IV** and proper key length (256-bit preferred).
- **A-4.3** No hardcoded keys / IVs in source.
- **A-4.4** Keys stored in **Android Keystore** — `KeyGenParameterSpec` with `setUserAuthenticationRequired(true)` for high-value keys; `setIsStrongBoxBacked(true)` where hardware-backed available.
- **A-4.5** PRNGs: `SecureRandom`, not `java.util.Random`.
- **A-4.6** No use of `ECB` mode.

### A-5: Network — MASVS-NETWORK
- **A-5.1** **Network Security Config** (`res/xml/network_security_config.xml`) declared and applied in manifest.
- **A-5.2** `cleartextTrafficPermitted="false"` (or scoped to specific debug domains). Default since API 28 is false — but verify.
- **A-5.3** **Certificate pinning** for sensitive APIs (`<pin-set>` in NSC, OR OkHttp `CertificatePinner`). Pin to public-key hash, not full cert.
- **A-5.4** No custom `TrustManager` that bypasses validation (`checkServerTrusted` empty) — `critical`.
- **A-5.5** `HostnameVerifier` not set to allow-all.
- **A-5.6** WebView: `setMixedContentMode(MIXED_CONTENT_NEVER_ALLOW)`; `setAllowFileAccess(false)`, `setAllowContentAccess(false)` unless needed.

### A-6: Authentication — MASVS-AUTH
- **A-6.1** Tokens stored in EncryptedSharedPreferences or Android Keystore-wrapped, not plain SharedPreferences.
- **A-6.2** Biometric auth uses `BiometricPrompt` (AndroidX), not deprecated `FingerprintManager`.
- **A-6.3** Biometric-protected keys: `setUserAuthenticationRequired(true)` with `setInvalidatedByBiometricEnrollment(true)`.
- **A-6.4** OAuth flows use Chrome Custom Tabs / AppAuth, not embedded WebView (prevents credential interception).
- **A-6.5** Re-authentication on app foregrounding for sensitive screens (banking, healthcare).

### A-7: Inter-process communication — MASVS-PLATFORM
- **A-7.1** Implicit intents not used for sending sensitive data (use explicit intents with package/class).
- **A-7.2** `PendingIntent` flags include `FLAG_IMMUTABLE` (required on Android 12+).
- **A-7.3** Broadcast receivers handling sensitive intents use **signature-level permissions** (`<receiver android:permission="...">`).
- **A-7.4** Content providers: `grantUriPermissions` only as needed; URI permissions explicit.
- **A-7.5** `WebView.addJavascriptInterface()` only when needed; methods exposed annotated `@JavascriptInterface`; minimize attack surface.

### A-8: Code & dependencies — MASVS-CODE
- **A-8.1** Run `mobsfscan` — review findings.
- **A-8.2** Run dependency vulnerability check (Gradle Versions plugin + OSV / GitHub Advisory).
- **A-8.3** Native libraries (`.so`) reviewed for known CVEs.
- **A-8.4** Code obfuscation via R8 / ProGuard for release builds.
- **A-8.5** Resource shrinking + minification enabled in release.

### A-9: Resilience (L2 only) — MASVS-RESILIENCE
- **A-9.1** Root / jailbreak detection (defense-in-depth, not a hard gate — assume bypass).
- **A-9.2** Anti-debug / anti-hooking checks (Frida detection).
- **A-9.3** Tampering detection — sign integrity check, native code integrity.
- **A-9.4** Emulator detection if threat model requires.

These are L2 — only flag for apps with elevated risk (banking, payments, DRM). For typical apps these are `info`.

### A-10: Build / release
- **A-10.1** APK / AAB signed with v2/v3 signature scheme (not just v1).
- **A-10.2** Signing key stored securely (KMS / HSM, not in CI plain secret); private key not in repo.
- **A-10.3** Release builds use distinct signing key from debug.
- **A-10.4** `targetSdkVersion` recent (within last 2 years).
- **A-10.5** Google Play App Signing enabled.

## Tools mapping

| Item | Tool that catches it |
|------|---------------------|
| A-1.x | mobsfscan, manual manifest review |
| A-2.x | mobsfscan, qark, manual |
| A-3.x | grep `Log\.`, manual |
| A-4.x | mobsfscan, semgrep, manual |
| A-5.x | mobsfscan, manual NSC review |
| A-6.x | Manual |
| A-7.x | mobsfscan, qark, semgrep, manual |
| A-8.x | mobsfscan, Gradle Versions, osv-scanner |
| A-9.x | Manual |
| A-10.x | Manual, build config review |

## Severity calibration cheat sheet

- Critical: hardcoded crypto key for production data, custom TrustManager that accepts all, exposed content provider returning auth tokens, allowBackup=true on banking app.
- High: missing certificate pinning on auth endpoint, sensitive data in plain SharedPreferences, WebView JS interface exposing native methods, deep links without App Links verification.
- Medium: missing R8 obfuscation, weak password hashing if stored locally, logging of session tokens, exported activity without permission gating.
- Low: missing PendingIntent FLAG_IMMUTABLE, missing biometric re-auth on sensitive screen.
- Info: opportunity for StrongBox, opportunity for Play Integrity API.

## Remediation prompt template

```
Open `<file>:<line>`. Currently:

    <Kotlin/Java/manifest snippet>

Risk: `<one-sentence threat>` per `OWASP MASVS <category>` (`<item id>`).

Change to:

    <replacement snippet>

Verify by:
1. `./gradlew :app:assembleRelease`
2. Inspect the built APK with `apkanalyzer dex packages app-release.apk` (or `aapt dump xmltree app-release.apk AndroidManifest.xml` for manifest changes).
3. Re-run `mobsfscan .` and confirm the rule no longer fires.
```

## References

- OWASP MASVS — https://mas.owasp.org/MASVS/
- OWASP MASTG — https://mas.owasp.org/MASTG/
- Android Developer Security Guide — https://developer.android.com/topic/security
- Android Network Security Config — https://developer.android.com/training/articles/security-config
- Jetpack Security — https://developer.android.com/jetpack/androidx/releases/security
