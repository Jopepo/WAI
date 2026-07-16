# WAI 3 Privacy Policy - Draft

Status: unreleased draft. Do not publish until every release blocker at the end
of this document has been resolved.

Effective date: to be set when WAI 3 is released.

WAI is a utility for authorized airline crew. WAI 3 uses an account so it can
restrict access to protected operational rules and keep those rules available
offline after authorization.

## Information used for the account

WAI uses Sign in with Apple. Apple and the WAI authentication service process an
Apple account identifier and, when Apple provides it, an email address. The WAI
service also stores an internal user identifier, a one-time approval code, the
account's access status, and the dates associated with that status.

To request approval, the user may choose to prepare an email in Apple's Mail
app. That request asks for the user's crew name, employee/TAP number, company
email address, and approval code. The user reviews and sends the message; WAI
does not upload those fields through its API.

Apple and Supabase may process technical request information needed to provide
and secure authentication and network services. WAI does not use advertising or
analytics SDKs and does not use personal data for tracking or targeted
advertising.

## Calendar, roster, and operational calculations

Calendar access is optional and requires the user's permission. WAI reads
calendar events on the device to identify and parse the crew roster. A user can
instead choose an iCalendar file.

Calendar contents, imported rosters, duties, flight legs, room numbers,
calculation history, hotel stays, wake-up times, and pickup times are processed
locally. WAI does not upload this information to its service. Sensitive local
records are owner-bound and protected with iOS Keychain or encrypted files.
Protected files are excluded from device backup.

Sign-out clears local authorization and protected personal data before waiting
for the remote service. WAI keeps a device-only interruption marker until that
cleanup completes, so an interrupted sign-out is finished before access can be
restored on the next launch.

WAI covers the secure interface while the app is inactive or in the background
to reduce disclosure through the normal app-switcher snapshot. This does not
prevent screenshots taken by the user while the app is active.

## Operational data

After authorization, WAI downloads transport rules, hotel information, and app
notices from a protected service. The app validates each complete release before
using it and keeps an encrypted local copy for limited offline operation. These
datasets contain operational information, not the user's roster or manual data.
WAI does not automatically send hotel details to mapping or contact providers.
If the user explicitly chooses an external Maps, phone, email, or browser
action, the selected hotel search or contact value is passed to that provider.

## Offline access

WAI may allow offline access for up to seven days after the account was last
verified as approved. Protected operational data remains encrypted and bound to
that account on that device. WAI stops offline access when the approval is too
old or when protected state cannot be verified safely.

## Account deletion

The user can permanently delete the WAI account inside the app. WAI requires a
fresh Sign in with Apple confirmation, asks Apple to revoke the authorization,
deletes the current Supabase authentication user and profile, and clears
protected WAI data and credentials from the device. If confirmation fails, the
account is not reported as deleted.

Some records may remain where a service provider or the developer must retain
them for security, fraud prevention, legal compliance, or dispute handling. The
final policy must identify the actual retention periods and applicable provider
terms before release.

## Contact

Questions about WAI privacy can be sent to:

joao.p.possidonio@gmail.com

## Release blockers for this draft

- Confirm the legal name and contact details of the data controller.
- Define the retention and deletion period for approval emails.
- Verify Supabase and Apple operational logging and retention for the deployed
  production configuration.
- Add links to the final Apple and Supabase privacy terms used by the service.
- Confirm any legally required rights, jurisdiction, and complaint authority.
- Set the effective date and publish the final policy at the exact HTTPS URL
  configured in the app and App Store Connect.
