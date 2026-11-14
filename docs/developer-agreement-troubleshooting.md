# Troubleshooting a missing Apple developer agreement

An HTTP 403 stating that a required agreement is missing or expired suggests an
Apple account or team agreement issue, rather than a problem in Silica's code.
The error alone does not identify which agreement is missing.

1. In [Apple Developer Account](https://developer.apple.com/account/), select the
   team used by Xcode and check membership status and any agreement notices.
   The Account Holder may need to sign in and accept updated terms.
2. Check [App Store Connect](https://appstoreconnect.apple.com/) for agreement
   notices too; an App Store paid-app agreement is not necessarily required for
   Developer ID distribution.
3. In Xcode's **Signing & Capabilities**, verify the selected team. This
   checkout specifies team `ER43ZD2S4U`, but `RELEASING.md` references a
   different team, so do not rely on that document's team ID without checking.

If everything is active and no agreement is visible, contact
[Apple Developer Support](https://developer.apple.com/contact/) with the team
ID, exact error, and time it occurred. Include whether it happens during
**Archive**, **Distribute App/export**, or **notarization**; that distinction
will help isolate the failing Apple service.
