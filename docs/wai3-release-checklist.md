# WAI 3 Release Checklist

Status: WAI 3 is unreleased. No upload, TestFlight deployment, production
backend deployment, or public-data change is permitted until every required
item below is complete.

## Invariants while WAI 3 is in development

- [x] Work stays on `feature/wai-3-secure-foundation`.
- [x] The normal project configuration remains WAI `2.2 (16)`.
- [x] WAI 2.2 keeps its current GitHub URLs and bundled JSON fallbacks.
- [x] The WAI 3 build path is separate and uses `WAI3-Info.plist`.
- [x] The WAI 3 build path contains no deploy or install action.
- [ ] No branch push or deployment until explicitly approved by Joao.

## Local WAI 3 build boundary

- [x] Secure mode is enabled only by the WAI 3 Info configuration.
- [x] WAI 3 is versioned separately as `3.0` with a build number above 16.
- [x] All five legacy operational JSON files are excluded by Xcode before the
  app is signed.
- [x] Public GitHub operational URLs are absent from the WAI 3 Info.plist and
  compiled app bundle.
- [x] Service-role keys, Apple private keys, and secret-like settings fail the
  WAI 3 release gate.
- [x] The approved-workspace UI fixture is compiled only in DEBUG, and its
  launch argument and fixture source marker fail the Release gate if present.
- [x] The WAI 2 upgrade fixture is produced only by the dedicated local Release
  builder, and every fixture marker fails the WAI 3 Release gate if present.
- [x] The privacy manifest is present in the built app.
- [x] Simulator Release build passes `scripts/wai3_release_gate.py`.
- [x] Unsigned arm64 iPhone build passes `scripts/wai3_release_gate.py`.
- [ ] Final signed archive passes the same gate before upload.

## Authentication and authorization

- [x] Native Sign in with Apple uses a cryptographic nonce.
- [x] Every backend profile starts as `pending`.
- [x] Only the owner can read their profile.
- [x] Only approved users can read the active release and its private objects.
- [x] App clients cannot approve, revoke, publish, upload, or mutate profiles.
- [x] Revocation clears protected local state after the server confirms it.
- [x] Offline access expires after seven days and fails closed on invalid state.
- [x] Create a dedicated EU staging Supabase project.
- [x] Configure the real Sign in with Apple provider for staging.
- [ ] Test first sign-in, repeat sign-in, Apple private relay email, cancellation,
  expired session, global sign-out, and revoked Apple credential on real devices.
- [ ] Decide and test the App Review access path without exposing operational
  data or creating an authentication bypass.

## Protected operational data

- [x] Transport rules, hotel map, and What's New form one atomic release.
- [x] Each object is content-addressed and checked by byte count and SHA-256.
- [x] Schema, source metadata, generation, and minimum app version are validated.
- [x] Rollback and mixed-generation releases are rejected.
- [x] The offline cache is AES-GCM encrypted, owner-bound, file-protected, and
  excluded from backup.
- [x] Simulator integration tests exercise the real Keychain implementations:
  encryption keys are 256-bit, isolated by service, device-only, stable until
  deletion, and malformed key lengths fail closed.
- [x] Private requests use an ephemeral URL session without response cache,
  cookies, or URL credential storage.
- [x] Local static migration, Edge Function contract, and publisher validation
  tests pass without contacting a backend.
- [ ] Deploy the schema only to staging and execute adversarial RLS tests using
  anonymous, pending, approved, revoked, and service-role clients.
- [ ] The migrations have been executed and inspected on staging PostgreSQL.
  Type-check and run the Edge Function in its Deno runtime before completing
  this release gate.
- [ ] Publish a staging release from the current REV73/REV51 source documents.
- [ ] Test a valid update, interrupted download, invalid hash, invalid schema,
  rollback, oversized response, offline start, and recovery after connectivity.

## Personal and local data

- [x] Calendar access is explicit and calendar/roster content stays device-only.
- [x] Imported rosters are parsed locally.
- [x] Roster validation rejects nonexistent or repeated DST wall times, resolved
  legs outside their duty, and duties entirely outside declared coverage. It
  accepts only genuine carry-in/carry-out overlap at month boundaries.
- [x] Floating Portal DOV duty boundaries use the first origin and final
  destination time zones, while explicit iCal property time zones remain
  authoritative.
- [x] The Calendar bridge preserves TAP endpoint-local wall times and keeps
  absolute boundaries for structured non-TAP calendars.
- [x] Roster, room number, calculation, and hotel-stay state is owner-bound and
  protected at rest.
- [x] Real Keychain round trips cover auth sessions, offline grants, account
  deletion intent, and local sign-out intent, including update and cleanup.
- [x] Secure startup removes legacy personal data and plaintext JSON caches.
- [x] Sign-out, revocation, account deletion, and owner mismatch wipe protected
  state and memory.
- [x] Account deletion requires fresh Apple reauthentication and server
  confirmation.
- [x] A Release-to-Release simulator upgrade from WAI 2.2 to WAI 3 preserves
  saved calculations, hotel stays, cached JSON, unrelated preferences, and
  Calendar permission before first launch; WAI 3 then removes only legacy
  personal data and plaintext caches, including across an offline restart.
- [ ] Run the protected-file attribute test on a physical iPhone and confirm
  the final files report `NSFileProtectionComplete`. The simulator verifies the
  requested protection and backup exclusion but does not expose that metadata.
- [ ] Run account deletion against staging and verify Apple revocation, Supabase
  user deletion, profile cascade, local wipe, relaunch, and interrupted deletion.

## Privacy and App Store

- [x] Engineering privacy data map exists.
- [x] User-facing privacy policy is reachable from signed-out, pending, revoked,
  and approved account states.
- [x] Privacy manifest declares known linked account data and required-reason
  APIs, with tracking disabled.
- [ ] Finalize controller identity, approval-email retention, provider logging,
  legal rights, jurisdiction, and contact details.
- [ ] Publish the final policy at a stable public HTTPS URL without login.
- [ ] Configure that exact URL in the app and App Store Connect.
- [ ] Match App Store Connect privacy answers to the deployed staging/production
  behavior, not only to source-code intent.
- [ ] Generate and manually review Xcode's privacy report from the signed archive.
- [ ] Prepare accurate App Review notes and an accessible review path.

## Final regression

- [x] The normal WAI 2.2 test plan passes with zero failures. Its single
  WAI 3-only secure-entry UI case skips by design in that configuration.
- [x] Python validation/security suite passes.
- [x] `scripts/verify_wai3_local.py` passes as a single local gate covering the
  untouched WAI 2.2 regression and invariant, WAI 3 secure UI, simulator and
  unsigned iPhone Release boundaries, and the Release-to-Release upgrade.
- [x] The WAI 3 secure-entry UI case passes separately in secure mode, including
  dark mode at the largest Dynamic Type size.
- [x] A DEBUG-only approved-workspace UI test exercises the real roster timeline,
  active hotel stay, automatic wake-up/pick-up, duty detail, room editing and
  persistence, endpoint-local duty times, analysis tab, and manual calculator
  without backend access.
- [x] The same approved-workspace path remains usable in dark mode at the
  largest Dynamic Type size; roster, duty detail, calculator, station selection,
  and the five primary toolbar actions are covered by UI assertions and
  persistent screenshots.
- [x] A sanitized iCal-to-timeline regression covers a remote stay end to end,
  including local report, wake-up, and pick-up times.
- [x] A one-time local smoke test imported a current real roster successfully;
  the private file path and roster content are not retained in the project or
  permanent test fixtures.
- [x] Normal WAI 2.2 bundle passes `scripts/wai2_invariant_gate.py`.
- [x] Synthetic WAI 3 simulator/device bundles pass
  `scripts/wai3_release_gate.py`.
- [ ] Complete staging end-to-end tests on at least two physical iPhones.
- [x] Rechecked the manual calculator against all 61 REV73 station fixtures,
  full-minute EWR/YYZ boundaries, fixed/range/alternative rules, local weekday
  and holiday conditions, roster report references, and DST fail-closed cases.
- [ ] Recheck Calendar import, iCal import, timeline, wake-up/pickup, hotels,
  room numbers, saved calculations, sign-out, offline restart, and deletion.
- [ ] Confirm there are no crashes, hangs, clipped controls, or inaccessible
  actions in light/dark mode and supported Dynamic Type sizes.
- [ ] Review the final diff and create intentional commits only after the branch
  is ready for shared review.
- [ ] Obtain explicit approval from Joao before any push or deployment.
