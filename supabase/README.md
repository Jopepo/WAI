# WAI 3 secure data backend

This directory defines the backend contract for WAI 3. It is source-only for
now: nothing in this directory deploys automatically.

## Security boundary

- Users authenticate with native Sign in with Apple.
- Every new profile starts as `pending`.
- An approved profile may read only the active operational release and objects
  in the private `wai-operational-data` bucket.
- Client sessions cannot approve users, publish releases, upload files, or
  change access state.
- The Supabase secret key belongs only in a protected backend environment or
  GitHub environment secret. It must never be added to the app or repository.

This boundary prevents anonymous or unapproved download and removes the public
repository URL from the app. It is access control, not DRM: an approved user
whose device can decrypt and display operational data can still inspect or copy
that data. Do not place credentials, personal data, or information that must be
impossible for an authorized client to extract in these datasets.

## Manual approval

The pending screen shows the profile's `approval_code`. The crew member sends
that code from their company email together with their Nome de Guerra and TAP
number. The personal details remain in that external approval message; the WAI
profile stores only the code and access state.

An administrator approves the matching profile in the Supabase dashboard by
changing `access_status` from `pending` to `approved`. Setting it to `revoked`
blocks future server reads immediately.

## Releases

One release contains all three datasets:

- `transport_rules`
- `hotel_map`
- `whats_new`

The release is activated atomically only after every content-addressed JSON
object has uploaded successfully. Clients must download and validate all three
objects before replacing their local cache, preventing mixed revisions.

The first hosted environment will be an EU staging project. Production remains
out of scope until the WAI 3 branch has passed internal testing.

## Account deletion

`functions/delete-account` is the server-only deletion boundary required by
Sign in with Apple. It is source-only and has not been deployed.

The iOS app requests a fresh Apple authorization code immediately before
deletion. The function then:

1. verifies the caller's current Supabase user JWT;
2. exchanges the single-use code directly with Apple;
3. verifies the Apple identity token signature against Apple's public JWKS and
   validates its issuer, audience, expiry, and subject;
4. checks that the Apple subject belongs to the current Supabase user;
5. revokes the new Apple refresh/access token;
6. hard-deletes only that Supabase user, cascading their `wai_profiles` row.

Before the request leaves the device, WAI writes a device-only Keychain marker.
The marker is removed only after the server result and local cleanup have both
completed. If the app is terminated during that interval, the next launch
fails closed, clears all protected and legacy personal data, and signs out
before rendering operational content.

Ordinary sign-out uses a separate device-only Keychain marker with the same
fail-closed ordering. It clears local authorization and protected personal data
before waiting for the remote sign-out response, and finishes any interrupted
cleanup on the next launch.

The function requires these server-side environment values:

- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, supplied by Supabase;
- `APPLE_TEAM_ID`;
- `APPLE_KEY_ID`;
- `APPLE_CLIENT_ID`, matching the native WAI App ID;
- `APPLE_PRIVATE_KEY`, containing the Sign in with Apple `.p8` private key.

`SUPABASE_SERVICE_ROLE_KEY` and `APPLE_PRIVATE_KEY` must be configured only as
Supabase function secrets. They must never be placed in `Info.plist`, an Xcode
configuration, GitHub, or the app bundle. JWT verification must remain enabled
for this function when it is eventually deployed.

## Internal testing privacy notice

`functions/wai3-privacy-notice` serves the temporary WAI 3 staging privacy
notice without authentication. It does not read environment values, databases,
storage, request bodies, or user data. This staging-only notice must be replaced
by the final reviewed privacy policy before a public release.
