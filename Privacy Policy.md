# Privacy Policy for Net Camera

Net Camera is a macOS application, made by D. Rimron-Soutter, that shows a
connected USB camera's picture in a window and can serve that same picture to
other devices on the local network. This policy describes exactly what the
app does with data, because that is short enough to state in full rather than
in general terms.

## Nothing is collected

Net Camera collects no data of any kind, about you, your device, or your use
of the app, and sends nothing to the developer or to any third party. There is
no analytics, no crash reporting, and no code in the app that opens an
outgoing network connection to anywhere. The app has no way to send data to
the developer, or to anyone else: it can only answer connections made to it
(see "The network stream" below).

Nobody, including the developer, receives any information from your use of
this app.

## The camera picture

The camera picture is not recorded, saved automatically, or sent anywhere by
the app. It exists only as a live video signal, shown in the app's window and,
while the app is running, on the network stream described below. Saving a
picture is something you do deliberately: choosing "Save Image" writes one
frame to a location you pick, using a standard macOS save dialog. The app can
only write to the file you choose; it has no access to the rest of your disk.

## The network stream

Net Camera's reason for existing is to let another device on the same network
watch the camera. While the app is running, it runs a small web server on the
Mac, listening on TCP port 50128, on every network interface the Mac has, not
only ones you might expect (such as a home Wi-Fi network). Any device that can
reach that port on your Mac can open a web page there and watch the live
camera picture.

This stream has no password and no login of any kind. Anyone who can reach the
port can watch it. There is currently no way to restrict who can connect. Take
this into account for the network you run the app on: a network you trust,
such as a home network behind a router, exposes the stream only to devices on
that network; a network you do not control, such as public Wi-Fi, exposes it
more widely.

The server starts automatically when the app launches and stops when the app
quits. There is no setting to turn it off while the app is running.

## Settings

Net Camera remembers your choices between launches: your profiles, each with
its camera, capture resolution, crop, mirroring and rotation, which profile
you last used, the window's size and position, and whether the window has a
border. These are stored by macOS on your Mac, using the standard mechanism
apps use for preferences (`UserDefaults`). They never leave your Mac and are
not shared with the developer or anyone else. The app's own "Clear All
Settings…" menu item, in the Profile menu, deletes all of them; "Remove
Profile…" deletes a single profile. Deleting the app itself leaves its settings folder behind in your home
Library folder until you remove that as well, which is how macOS treats every
sandboxed app.

## Camera access

The app can only see a camera after macOS asks you for permission and you
grant it. You can review or withdraw that permission at any time in System
Settings, under Privacy & Security > Camera.

## Data retention

There is nothing to retain. Net Camera stores nothing about you beyond the
settings described above, which live only on your own Mac for as long as the
app remains installed.

## Children

Net Camera does not collect information from anyone, including children.

## Changes to this policy

If this policy changes, the new version will be posted in the same place. The
app's source code is public, so any change to what the app actually does can
be checked directly against it.

## Where this is handled

D. Rimron-Soutter is based in the United Kingdom, and any handling of
information in connection with this app (for example, replying to an email)
takes place there.

## Licence

Net Camera is open source, licensed under Apache 2.0. The source code is
available in this repository.

## Contact

Questions about this policy or the app can be sent to darran@xalior.com.
