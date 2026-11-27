# iPlex

iPlex is an independent music and video player for Plex libraries on macOS, Windows, iPhone, iPad, and Apple TV.

Browse artists, albums, genres, tracks, and playlists with Plex artwork and metadata. Choose which sections appear in Settings, where you can also preview and select an app icon. Liquid Glass has independent text and accent colors, plus adjustable tint and transparency. The Classic iPod and iPod Video mini-player layouts include click-wheel controls. Settings include an equalizer and **Cache Library Artwork**, which downloads album covers, artist pictures, and movie and TV show posters from the selected Plex libraries.

Movies and TV each remember their own Plex library selection. Browse movie posters and TV seasons, then select a movie or episode to play it. iPlex can play MKV and WebM locally through its bundled VideoLAN engine. The app also supports Direct Play through each platform’s media decoder. If the device cannot play that version, iPlex requests a compatible stream from Plex Media Server. You can also choose **Use Compatibility Mode** during playback. Fullscreen is available during playback. On macOS and Windows, Picture in Picture opens a movable, resizable video window with a **Keep on Top** option. On iPhone, iPad, and compatible Apple TV hardware, the system player provides Picture in Picture for supported streams. Direct Play depends on the device, file container, and codecs. Compatibility mode requires video transcoding on the Plex server.

## Install

Download the build for your platform from [GitHub Releases](https://github.com/Bentley734/iPlex/releases).

- **macOS 14 or later** — Unzip the macOS download and move iPlex to Applications. The build is ad hoc signed.
- **Windows** — Extract the Windows ZIP and open iPlex.exe. The Microsoft Edge WebView2 Runtime is required.
- **iOS 17 and tvOS 17 or later** — The IPA downloads are unsigned and require signing before installation.

## Build

- **macOS** — Run `./build.sh` with Xcode or Apple's Command Line Tools. The universal app is written to `dist/iPlex.app`.
- **iOS and tvOS** — Run `./fetch-video-dependencies.sh apple`, then open `MusicRoom.xcodeproj` in Xcode and select the `MusicRoom-iOS` or `MusicRoom-tvOS` scheme. Configure signing for your device. The checked-in project can be regenerated from `project.yml` with XcodeGen.
- **Windows** — On macOS, run `./fetch-video-dependencies.sh windows` and `python3 Windows/build.py --help`. The build takes a C# compiler, .NET Framework 4.8 reference assemblies, the [WebView2 SDK 1.0.3537.50](https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.3537.50), and the decoder binaries built with `Windows/Codecs/build-decoders.sh`. Build dependencies and license details for the decoders are in [Windows/Codecs/ThirdParty.txt](Windows/Codecs/ThirdParty.txt).

The Windows player bundles [hls.js 1.7.4 Light](https://github.com/video-dev/hls.js/tree/v1.7.4) for the Plex compatibility stream. Its license is included in the Windows download.

The packages ship dynamically linked VideoLAN playback libraries. See [the license](Assets/VideoLAN-LICENSE.txt) and [the matching upstream source and build information](Assets/VideoLAN-SOURCE.txt).
