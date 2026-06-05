# Release ZIP

mimi release ZIPs are built by `.github/workflows/release-zip.yml`.

## Apple verification requirements

Downloaded macOS apps pass Gatekeeper when the app is:

1. Signed with a **Developer ID Application** certificate, not Apple Development.
2. Signed with hardened runtime.
3. Submitted to Apple notarization.
4. Stapled after notarization.
5. Zipped with `ditto`, preserving app bundle metadata.

The workflow does all five for tag/manual releases. It notarizes a temporary ZIP, staples `build/mimi.app`, then creates the final downloadable ZIP from the stapled app.

## Required GitHub secrets

Create these repository secrets:

- `DEVELOPER_ID_APPLICATION_CERT_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_CERT_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`

### Developer ID certificate

In Apple Developer:

1. Certificates → create **Developer ID Application** certificate.
2. Export certificate + private key from Keychain Access as `.p12`.
3. Base64 encode it:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Store that as `DEVELOPER_ID_APPLICATION_CERT_P12_BASE64`. Store the `.p12` export password as `DEVELOPER_ID_APPLICATION_CERT_PASSWORD`.

### App Store Connect API key

In App Store Connect:

1. Users and Access → Integrations → App Store Connect API.
2. Create API key with access sufficient for notarization.
3. Store key id as `APP_STORE_CONNECT_API_KEY_ID`.
4. Store issuer id as `APP_STORE_CONNECT_API_ISSUER_ID`.
5. Base64 encode downloaded `.p8`:

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

Store as `APP_STORE_CONNECT_API_KEY_P8_BASE64`.

## Release

Push to `main` runs tests only.

Create a notarized ZIP release by pushing a tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Manual workflow dispatch also creates and uploads a notarized ZIP artifact, but only tags publish a GitHub Release.

## Local checks

```bash
scripts/build_app.sh
scripts/create_zip.sh build/mimi-local.zip
```

Local Apple Development/ad-hoc signing is fine for development, but downloaded ZIPs need Developer ID signing plus notarization to avoid Gatekeeper blocking.
