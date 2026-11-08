# Net Camera

Net Camera displays the output from any USB-based camera on your macOS desktop. It
supports mirroring (horizontal and vertical), rotation in 90° increments, resizing
to any size, a borderless always-on-top mode, aspect-ratio locking, choosing the
camera's capture resolution, and saving stills as PNG. Cameras can be hot-plugged
and the app follows them.

The everyday use it is built around is a USB HDMI capture dongle as a
picture-in-picture monitor — watching a bare-metal machine's video output in a
window on another desktop, alongside whatever else that machine is doing.

## An official fork of Quick Camera

Net Camera is a fork of [Quick Camera](https://github.com/simonguest/quick-camera)
by **Simon Guest**, taken up with the full git history intact — every commit Simon
and the other Quick Camera contributors authored is still in this repository's log,
under their names. Net Camera is licensed under the Apache License 2.0, the same
licence Quick Camera uses; see [LICENSE](LICENSE).

Quick Camera is still developed and published by Simon, and it is still on the
[Mac App Store](https://itunes.apple.com/us/app/qcamera/id598853070?mt=12). If what
you want is a USB camera on your desktop and nothing more, use Quick Camera — it is
the better answer for that, deliberately.

### Why the projects differ

Quick Camera does one thing well: it puts a camera on your screen, stays small, and
stays out of the way. That focus is a design position, not an oversight, and it is
why the project declines features that would cost it.

Net Camera wants more than that one thing, and accepts the price. Where Quick
Camera's video frames exist only to be drawn into a preview layer, Net Camera is
built around access to the frames themselves, so that the picture can be observed by
more than just the window — and it pays for that in CPU where Quick Camera does not
have to.

Two projects, two different bargains. Neither is a criticism of the other.

### What changed from Quick Camera

- Rebranded as Net Camera, bundle identifier `com.xalior.NetCamera`, with its own
  Apple developer identity. Quick Camera's identity and App Store presence are
  Simon's and are untouched.
- A `Makefile` so builds and launches are runnable from a terminal without Xcode's UI.
- **Resolution selection.** Each camera in *Select Source* carries a submenu of the
  resolutions it advertises, and the submenu is always there. Quick Camera's own
  review of this feature asked for it to be hidden behind a preference, default off,
  so that new users would not meet an extra menu level; Net Camera's users want the
  control, so it is unconditional.

- **A frame-based pipeline.** Quick Camera's frames never leave the preview layer.
  Net Camera's leave the capture session, are rotated and mirrored once, and are
  handed to every consumer that wants them. The window is one such consumer and
  holds no privileged copy of the picture.
- **Save Image saves the picture, not a screenshot.** Quick Camera photographs its
  own window. Net Camera writes the frame the window is showing, at the camera's
  resolution rather than the window's, and so saves happily in full screen — which
  the screenshot approach could not do at all.
- **A built-in web server**, on port `50128`, always on, reachable from any machine
  that can reach the Mac. This is the netcam the fork exists for, and it is the
  direct dividend of the pipeline above: a browser becomes another consumer of the
  same frames the window is drawing.

  Point a browser at `http://<the Mac>:50128/` and it shows the live picture, at
  the camera's own resolution, scaled to fit by the browser rather than by the
  Mac. It is served as MJPEG — one JPEG per frame down a response that never ends
  — which is the oldest and least demanding thing that works in every browser
  without a plugin, a player or a handshake. With nobody watching, the encoder
  does not run at all; with several watching, a frame is still encoded only once.

- **Cropping.** *Camera › Crop…* cuts a margin off any edge of the picture, in the
  camera's own pixels — for the black strip a capture dongle delivers down one side.
  The crop is taken before mirroring and rotation, so it stays on the same edge of
  the signal whichever way round the picture is shown, and the window, saved images
  and the web stream all get the same cropped picture.

Beyond that, this is Quick Camera's behaviour, unchanged.

## Building

Requires Xcode. Either open `Net Camera.xcodeproj`, or from the command line:

```bash
make build     # build the app
make run       # build, then launch it
make clean     # remove build products
```

`make build` defaults to the Debug configuration; pass `CONFIGURATION=Release` for a
release build.

Upstream's names are gone from the tree — project, target, module, folders and
source filenames are all Net Camera's. Upstream's credit is not: see the licence
and the fork provenance above, which are a separate obligation and stay.

## Standing on shoulders

Net Camera exists because other people's work exists. Everything it is built on,
credited in full:

- **[Quick Camera](https://github.com/simonguest/quick-camera)** by
  [Simon Guest](https://github.com/simonguest) (Apache-2.0) — not a dependency but
  the origin: Net Camera is its fork, and the great majority of this codebase is
  still Simon's and his contributors' work.
- **Resolution selection** — the ability to choose a camera's capture resolution is
  [gobbledygoober](https://github.com/gobbledygoober)'s work, contributed to Quick
  Camera as [PR #59](https://github.com/simonguest/quick-camera/pull/59) and merged
  here with their commits intact. It began as
  [beazlr02](https://github.com/beazlr02)'s
  [PR #14](https://github.com/simonguest/quick-camera/pull/14), which gobbledygoober
  rebased and extended; the rebase re-authored the commits, so beazlr02's share of it
  is recorded here rather than in the git log.
- **[Hummingbird](https://github.com/hummingbird-project/hummingbird)** by the
  Hummingbird authors (Apache-2.0) — the HTTP server Net Camera answers on. A
  lightweight server framework on Apple's [SwiftNIO](https://github.com/apple/swift-nio),
  and small enough to sit inside a desktop app rather than the other way round.
  It brings SwiftNIO and the rest of the Swift server ecosystem with it; every one
  of those packages is recorded, at the exact version used, in the project's
  `Package.resolved`.
- **Apple's platform frameworks** — AVFoundation for capture, AppKit for the
  interface, IOKit for USB hot-plug detection, Core Graphics and Core Image for
  pixels. Where the platform framework is the mainstream answer, Net Camera uses it
  rather than reaching for a third-party library.

## Licence

Apache License 2.0. See [LICENSE](LICENSE).

Portions copyright © Simon Guest and the Quick Camera contributors.
