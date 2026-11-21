# Health → Garmin

An iPhone app that uploads new Apple Health workouts to Garmin Connect automatically, without creating duplicates.

## Build with GitHub Actions
1. Push this folder to a GitHub repo, or to a branch of one. The workflow in `.github/workflows/build.yml` runs on every push. You can also start it by hand: Actions → "Build iOS app" → Run workflow.
2. When the run finishes, download the **HealthToGarmin-ipa** artifact and unzip it to get `HealthToGarmin.ipa`.
3. Install it with **Sideloadly** or **AltStore** using your Apple ID. They re-sign the app with your Apple ID. A free Apple ID's signature expires after 7 days. A paid developer account ($99/yr) lasts a year, and HealthKit background delivery is most reliable with a paid account.

## Or build locally
`brew install xcodegen && xcodegen generate && open HealthToGarmin.xcodeproj`. Then set your Team under Signing and run the app on your iPhone.

## Using it
1. Tap **Allow Health access** and turn on Workouts, Heart Rate, Routes, Distance and Energy.
2. Sign in to Garmin. If your account has two-factor sign-in, the app asks for the code.
3. Choose **Export workouts since**. It defaults to the day you install the app, so your old history isn't uploaded unless you pick an earlier date.
4. From then on, iOS wakes the app when a workout is saved to Health. An hourly background refresh is a backup. You can also pull down on the screen to sync by hand.

## How duplicates are prevented
- **Ledger:** every Health workout ID that has been handled is saved after each upload. A workout is never sent twice, even if the app crashes mid-sync.
- **Garmin-sourced workouts are skipped:** workouts that Garmin Connect wrote into Apple Health are never sent back.
- **Garmin is checked before each upload:** the app reads your Garmin activity list. If an activity starts within 3 minutes of the workout, or overlaps more than half of it, the workout is skipped. This covers cases like wearing a Garmin watch and an Apple Watch on the same run.
- **Garmin's own duplicate check:** if Garmin rejects an upload as a duplicate (HTTP 409), the workout is marked "already in Garmin".
- **One sync at a time:** a foreground sync and a background sync can't run at once.

## Limitations
- Garmin has no public upload API for individuals. The app signs in the same way Garmin's mobile app does, using the open-source `garth` method. Garmin can change that sign-in at any time without notice. Your password isn't stored; only the Garmin tokens are kept, in the Keychain.
- Files are uploaded as TCX, which only has three sport types: Running, Biking and Other. Other workouts arrive as "Other", and you can change the type in Garmin Connect. Distance, time, calories, heart rate and GPS routes all transfer.
