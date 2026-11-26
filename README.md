# iPlex

iPlex is an independent music player for Plex libraries on macOS, Windows, iPhone, iPad, and Apple TV.

Browse artists, albums, genres, tracks, and playlists with Plex artwork and metadata. Choose which sections appear in Settings, where you can also preview and select an app icon. The Classic iPod and iPod Video themes include click-wheel controls. Settings include an equalizer and **Cache Library Artwork**, which downloads album covers and artist pictures from the selected Plex library.

## Install

Download the build for your platform from [GitHub Releases](https://github.com/Bentley734/iPlex/releases).

- **macOS 14 or later** — Unzip the macOS download and move iPlex to Applications. The build is ad hoc signed.
- **Windows** — Extract the Windows ZIP and open iPlex.exe. The Microsoft Edge WebView2 Runtime is required.
- **iOS 17 and tvOS 17 or later** — The IPA downloads are unsigned and require signing before installation.

## Build

- **macOS** — Run `./build.sh` with Xcode or Apple's Command Line Tools. The universal app is written to `dist/iPlex.app`.
- **iOS and tvOS** — Open `MusicRoom.xcodeproj` in Xcode and select the `MusicRoom-iOS` or `MusicRoom-tvOS` scheme. Configure signing for your device. The checked-in project can be regenerated from `project.yml` with XcodeGen.
- **Windows** — On macOS, run `python3 Windows/build.py --help`. The build takes a C# compiler, .NET Framework 4.8 reference assemblies, the [WebView2 SDK 1.0.3537.50](https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.3537.50), and the decoder binaries built with `Windows/Codecs/build-decoders.sh`. Build dependencies and license details for the decoders are in [Windows/Codecs/ThirdParty.txt](Windows/Codecs/ThirdParty.txt).
