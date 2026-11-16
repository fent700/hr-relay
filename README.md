# HR Relay

Rebroadcasts Apple Watch heart rate to a bike computer (Garmin Edge, Wahoo, etc.) as a standard Bluetooth heart rate sensor, for watches too old to run a watch-side broadcaster app (Series 3 / watchOS 8).

The watch's built-in **Workout** app records heart rate into Health and syncs it to the iPhone. HR Relay reads it there and advertises a BLE Heart Rate Service (0x180D), notifying at 1 Hz.

No account, no server, no time limit.

## Ride setup

1. Open HR Relay, tap **Start relay**, allow Health, Bluetooth and Location.
2. On the watch, start **Indoor Cycle** in the Workout app. Indoor workouts use no GPS on the watch or the phone; the Edge records the route.
3. First time only, with HR Relay open on screen: on the Edge, *Sensors → Add Sensor → Heart Rate*, pick **HR Relay**.
4. Lock the phone and ride.

## Staying alive while locked

- **Workout session keep-alive**: an iPhone-side workout session (iOS 26+). No builder is attached, so nothing is saved to Health.
- **Location keep-alive**: 3 km accuracy (cell/Wi-Fi, no GPS), background runtime only.
- **Pocket mode**: black screen, zero brightness, proximity sensor on. The phone never locks, so Health is never encrypted. Use it if *Updates while locked* stays at 0 on a test ride.

A sample older than 120 s stops being broadcast, so the Edge shows a gap and not a flat line.

## Build

CI (`.github/workflows/build-ipa.yml`) generates the project with XcodeGen, builds Release unsigned, fakesigns the binary with the HealthKit entitlements via `ldid`, and uploads `HRRelay-N.ipa`. Sign with ESign on install. The signing certificate must allow HealthKit.
