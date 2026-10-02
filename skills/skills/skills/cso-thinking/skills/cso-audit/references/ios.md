# iOS security checklist

> Native iOS app. Grounded in OWASP MASVS v2 (L1 + L2) iOS profile, MASTG, Apple Platform Security Guide.

Read this file when the `ios` profile is active.

## Threat outcomes we defend against

1. **On-device data theft** — weak Keychain accessibility, plist exposure, snapshot leakage
2. **Network MitM** — ATS bypass, missing pinning, weak TLS config
3. **Inter-app abuse** — URL scheme hijacking, universal-link misconfiguration, pasteboard leakage
4. **Reverse engineering / tampering** — no symbol stripping, no integrity check (L2 only)
5. **Credential & key compromise** — hardcoded secrets, weak crypto, key stored insecurely

## Checklist (X-1 to X-10)

Mapped to MASVS categories.

### X-1: Info.plist & entitlements — MASVS-PLATFORM
- **X-1.1** `NSAppTransportSecurity` not opened up — `NSAllowsArbitraryLoads=true` is a `critical` smell. Scoped exceptions only (`NSExceptionDomains`) with justification.
- **X-1.2** URL schemes (`CFBundleURLTypes`) — custom schemes are spoofable by other apps. Prefer **Universal Links** for sensitive flows.
- **X-1.3** `LSApplicationQueriesSchemes` minimal — long list reveals interest in other apps.
- **X-1.4** Background modes only what's used (`NSBackgroundModes`).
- **X-1.5** Permissions usage descriptions present and honest (`NSCameraUsageDescription`, `NSLocationWhenInUseUsageDescription`, etc.).
- **X-1.6** Entitlements: keychain access groups scoped (not wildcard), app groups scoped, no unused entitlements.

### X-2: Keychain & secure storage — MASVS-STORAGE
- **X-2.1** Sensitive items in **Keychain**, not UserDefaults / plist / files.
- **X-2.2** Keychain `kSecAttrAccessible` set to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` or `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for sensitive items. **Avoid** `kSecAttrAccessibleAlways*` (deprecated and weak).
- **X-2.3** Biometric-protected items use `kSecAccessControl` with `.biometryCurrentSet` / `.userPresence`.
- **X-2.4** Generic Passwords vs Internet Passwords — appropriate class chosen.
- **X-2.5** No sensitive data in `Documents/` / `Library/Caches/` plaintext — encrypt or use Keychain.
- **X-2.6** Core Data / Realm databases with sensitive data use **Data Protection class** `NSFileProtectionComplete` (or use SQLCipher).

### X-3: Data protection at rest — MASVS-STORAGE
- **X-3.1** Files written with `Data.write(to:options:)` use `.completeFileProtection` or `.completeUntilFirstUserAuthentication` for sensitive content.
- **X-3.2** App-group container files: protection class explicit; default may be weaker.
- **X-3.3** iCloud Drive / iCloud Backup of sensitive containers controlled (`isExcludedFromBackup` for caches that should not sync).

### X-4: UI snapshot leakage
- **X-4.1** On backgrounding (`applicationWillResignActive`), sensitive screens are obscured or the keyWindow is hidden — prevents the iOS app-switcher screenshot from leaking content (banking app pattern).
- **X-4.2** Password fields use `isSecureTextEntry = true`.
- **X-4.3** Custom keyboards disabled for sensitive input if threat model requires (`extensionPointIdentifier` check in `application(_:shouldAllowExtensionPointIdentifier:)`).

### X-5: Pasteboard — MASVS-STORAGE
- **X-5.1** Sensitive values not copied to `UIPasteboard.general` (system-wide, readable by other apps).
- **X-5.2** If copy needed: use `UIPasteboard(name:create:)` with a local-only pasteboard or set `expirationDate` (iOS 14+).

### X-6: Network — MASVS-NETWORK
- **X-6.1** ATS not bypassed (see X-1.1).
- **X-6.2** **Certificate pinning** for sensitive endpoints via `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)` validating `SecTrust` against pinned key/cert. Or use TrustKit / Alamofire ServerTrustManager.
- **X-6.3** No custom `URLSessionDelegate` that calls `completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))` without validation — that's accept-all-certs, `critical`.
- **X-6.4** WKWebView: `WKWebViewConfiguration.preferences.javaScriptEnabled` controlled; `WKWebsiteDataStore.nonPersistent()` for sensitive sessions.
- **X-6.5** No `UIWebView` (deprecated, removed) — flag any remaining usage.

### X-7: Authentication — MASVS-AUTH
- **X-7.1** Tokens in Keychain, not UserDefaults.
- **X-7.2** Biometric: `LAContext` with `.deviceOwnerAuthenticationWithBiometrics`, fallback policy explicit.
- **X-7.3** OAuth via `ASWebAuthenticationSession`, not WKWebView with form (prevents credential phishing & enables SSO cookies).
- **X-7.4** Re-authentication on app foregrounding for sensitive screens.

### X-8: Inter-process & deep linking — MASVS-PLATFORM
- **X-8.1** `application(_:open:options:)` validates source application bundle ID before processing actions, especially for state-changing operations.
- **X-8.2** Universal Links preferred over custom URL schemes for authentication callbacks.
- **X-8.3** App Extensions: data-shared via App Group is appropriately protected.
- **X-8.4** Share extensions / actions only export safe types.

### X-9: Logging & telemetry
- **X-9.1** No `print()` / `NSLog()` of sensitive values in release builds — use `OSLog` with `privacy: .private` annotations or strip via compiler flag.
- **X-9.2** Crash reporters (Crashlytics, Sentry) configured to scrub PII / tokens.
- **X-9.3** Analytics events don't contain PII.

### X-10: Code & build — MASVS-CODE / RESILIENCE
- **X-10.1** Bitcode / DWARF symbol stripping for release.
- **X-10.2** Hardcoded API keys / secrets not in source (search strings table, `Info.plist`, `xcconfig` for `sk_live`, `AKIA`, etc.).
- **X-10.3** Dependencies (CocoaPods / SPM / Carthage) vulnerability-checked (osv-scanner can read `Package.resolved` and `Podfile.lock`).
- **X-10.4** Code signing: production builds signed with distribution cert; provisioning profile correct.
- **X-10.5** Apple Privacy Manifest (`PrivacyInfo.xcprivacy`) accurate — declares data collection and required-reason API usage (required as of 2024).
- **X-10.6** Jailbreak detection (L2; defense-in-depth — assume bypass): check for known paths, `fork()` behavior, dyld inspection. Not a hard gate.

## Tools mapping

| Item | Tool that catches it |
|------|---------------------|
| X-1.x | mobsfscan, manual plist review |
| X-2.x | mobsfscan, manual |
| X-3.x | Manual |
| X-4.x | Manual |
| X-5.x | grep `UIPasteboard\.general`, manual |
| X-6.x | mobsfscan, manual |
| X-7.x | Manual |
| X-8.x | Manual |
| X-9.x | grep `print\(`, `NSLog`, manual |
| X-10.x | mobsfscan, osv-scanner, manual |

## Severity calibration cheat sheet

- Critical: `NSAllowsArbitraryLoads=true` in production, custom URLSession delegate accepting all certs, hardcoded production API secret in `Info.plist` / source, sensitive data in UserDefaults.
- High: missing cert pinning on auth API, Keychain with `kSecAttrAccessibleAlways*`, sensitive data on pasteboard, OAuth via WKWebView form.
- Medium: missing app-switcher screen obscure for sensitive views, missing privacy manifest, deprecated WebView usage.
- Low: missing biometric re-auth on background, opportunity to use `OSLog .private`.
- Info: opportunity for Lockdown-mode compatibility, opportunity for jailbreak detection (L2 only).

## Remediation prompt template

```
Open `<file>:<line>`. Currently:

    <Swift/Obj-C/plist snippet>

Risk: `<one-sentence threat>` per `OWASP MASVS <category>` (`<item id>`).

Change to:

    <replacement snippet>

If editing `Info.plist`, prefer the Build Settings or `xcconfig` to keep diffs reviewable. Avoid hand-editing the plist if a setting accessor exists.

Verify by:
1. `xcodebuild -scheme <Scheme> -configuration Release archive`
2. For network/ATS changes: `nscurl --ats-diagnostics https://your-api.example.com`
3. For Keychain changes: inspect attributes with a debug `SecItemCopyMatching` call printing returned attributes (debug build only).
4. Re-run `mobsfscan .` and confirm the rule no longer fires.
```

## References

- OWASP MASVS — https://mas.owasp.org/MASVS/
- OWASP MASTG — https://mas.owasp.org/MASTG/
- Apple Platform Security — https://support.apple.com/guide/security/welcome/web
- Apple Privacy Manifest — https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
- App Transport Security — https://developer.apple.com/documentation/security/preventing_insecure_network_connections
