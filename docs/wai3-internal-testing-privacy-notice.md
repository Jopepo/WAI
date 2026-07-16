# WAI 3 Internal Testing Privacy Notice

Status: temporary notice for authorized WAI 3 staging testers. This is not the
final privacy policy for a public App Store release.

Effective date: 16 July 2026.

WAI 3 is an unreleased utility for authorized airline crew. This internal build
uses an account to restrict access to protected operational rules and to keep a
validated encrypted copy available for limited offline use.

## Account information

WAI uses Sign in with Apple. Apple and the WAI staging authentication service
process an Apple account identifier and, when Apple provides it, an email
address. The staging service also stores an internal user identifier, a random
approval code, the account access status, and timestamps associated with that
status.

An approval request may be prepared in Apple's Mail app. The tester reviews and
sends that email. WAI does not upload the crew name, employee number, or company
email address through its API.

Apple and Supabase may process technical request information needed to provide
and secure authentication and network services. WAI does not use advertising
or analytics SDKs and does not use personal data for tracking or targeted
advertising.

## Data that stays on the device

Calendar access is optional and requires permission. Calendar events, imported
rosters, duties, flight legs, room numbers, calculation history, hotel stays,
wake-up times, pickup times, home routine settings, briefing edits, and
commander passwords are processed locally and are not uploaded to the WAI
service.

Protected local records are bound to the signed-in account and stored using the
iOS Keychain or encrypted files. Sign-out clears local authorization and
protected personal data. The app also covers protected content while inactive
to reduce disclosure through the normal app-switcher snapshot.

## Operational data

After approval, WAI downloads transport rules, hotel information, and app
notices from a protected staging service. The app validates a complete release
before using it and may keep an encrypted local copy for up to seven days after
the account was last verified as approved.

These datasets do not contain the tester's roster or manually entered data.
WAI sends a selected hotel search or contact value to Maps, phone, email, or a
browser provider only when the tester explicitly chooses that external action.

## Internal testing and deletion

The staging environment is not production. Test accounts and staging records
may be reset during development. The automated in-app account deletion service
has not yet completed staging validation. Until that validation is complete, a
tester may request deletion of their staging account and profile using the
contact address below. Protected WAI data can also be removed from the device by
signing out or deleting the app.

Approval-email retention, provider logging, the final controller details, and
the final legal retention periods are still under review. Testers should not
send unnecessary personal information in an approval request.

## Contact

Questions or staging deletion requests can be sent to:

joao.p.possidonio@gmail.com

This notice will be replaced by the final WAI 3 privacy policy before any public
release.
