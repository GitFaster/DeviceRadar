# DriveRadar — Walking Mode update

## What's changed
- Added Driving / Walking mode selection to destination search and route preview.
- Walking routes use MapKit pedestrian directions and avoid driving-only route handoff.
- Walking mode is retained by navigation, rerouting, and stop insertion for the active session.
- Added a visible WALKING MODE badge and pedestrian location marker.
- Walking navigation uses a flat map camera and hides driving-specific traffic/camera route details.
- Kept existing driving mode as the default.

## Open
Open `DeviceRadar.xcodeproj` in Xcode and build the `DeviceRadar` scheme. This environment did not have Xcode available, so a simulator/device build could not be run here.

Walking routes depend on Apple Maps' pedestrian-routing coverage in the selected region. Follow posted signs and pedestrian crossing rules.
