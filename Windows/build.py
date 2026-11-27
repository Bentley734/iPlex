"""Build the iPlex Windows app with the pinned WebView2 SDK and decoder binaries."""
import argparse
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile
from zipfile import ZipFile, ZIP_DEFLATED
from io import BytesIO

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT.parent / "Assets"
SDK_DIGEST = "5ea526bbd728adda0da4d31219267e96460494a427e4894c4e09d9f320f4b9aa"
VLC_PACKAGE = ROOT.parent / "Dependencies/VideoLAN.LibVLC.Windows.3.0.24.nupkg"
VLC_DIGEST = "3da3f37ee2b2b10e5c788d830a3b513658c36521ea1b0f966ed86eb69f41ef3c"
DEFAULT_ICON = "prismatic-note"
ICONS = (
    DEFAULT_ICON, "prismatic-note-dark", "music-gradient", "music-wordmark", "music-crimson",
    "music-monochrome", "music-orange", "music-artists", "music-pink", "napster",
    "napster-mono", "spotify", "plex",
    "wmp-classic", "media-player-classic", "wmp-glass", "vlc-classic", "vlc", "quicktime", "itunes-disc", "itunes-11",
)


def make_icon(png, destination):
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        sizes = (16, 32, 48, 64, 128, 256)
        parts = []
        for size in sizes:
            out = temp / f"{size}.png"
            subprocess.run(["sips", "-z", str(size), str(size), str(png), "--out", str(out)],
                           check=True, stdout=subprocess.DEVNULL)
            parts.append(out.read_bytes())
        offset = 6 + len(parts) * 16
        header = struct.pack("<HHH", 0, 1, len(parts))
        for size, part in zip(sizes, parts):
            width = 0 if size == 256 else size
            header += struct.pack("<BBBBHHII", width, width, 0, 0, 1, 32, len(part), offset)
            offset += len(part)
        destination.write_bytes(header + b"".join(parts))



def package_vlc(package, architecture, destination):
    playback = {
        "audio_filter", "audio_mixer", "audio_output", "codec", "demux", "d3d11", "d3d9",
        "logger", "packetizer", "spu", "stream_filter", "text_renderer", "video_chroma",
        "video_filter", "video_output",
    }
    transport = {
        "libfilesystem_plugin.dll", "libhttp_plugin.dll", "libhttps_plugin.dll",
        "libattachment_plugin.dll", "libgnutls_plugin.dll", "libxml_plugin.dll",
    }
    prefix = f"build/{architecture}/"
    with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
        for name in package.namelist():
            if not name.startswith(prefix) or not name.endswith(".dll"):
                continue
            relative = name.removeprefix(prefix)
            parts = relative.split("/")
            if relative in {"libvlc.dll", "libvlccore.dll"} or (
                len(parts) == 3 and parts[0] == "plugins" and (parts[1] in playback or parts[2] in transport)
            ):
                archive.writestr(relative, package.read(name))


SQLITE_VERSION = "3540100"
SQLITE_DIGESTS = {
    "x86": "97cd8f207ec121e13d3af459e82834a214700659f307603d80814c6bdb19e2d2",
    "x64": "c2d09c8babb9399277055c057c97a53f1ffd7c5f11d0c1f2118ffdfa39f2daa4",
    "arm64": "58a563f64ba4c5df34c3ce667175678e2c1df503b264cd600200eb37aa334201",
}


def sqlite_binary(architecture):
    filename = f"sqlite-dll-win-{architecture}-{SQLITE_VERSION}.zip"
    local = ROOT.parent / "Dependencies" / filename
    if local.is_file():
        package = local.read_bytes()
    else:
        package = subprocess.check_output([
            "curl", "--fail", "--silent", "--show-error", "--location", "--retry", "2",
            f"https://www.sqlite.org/2026/{filename}",
        ])
    if hashlib.sha3_256(package).hexdigest() != SQLITE_DIGESTS[architecture]:
        raise SystemExit(f"The SQLite package for {architecture} did not match its published SHA3 digest.")
    with ZipFile(BytesIO(package)) as archive:
        return archive.read("sqlite3.dll")



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("sdk", "compiler", "references", "codecs", "output"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--vlc", type=Path, default=VLC_PACKAGE)
    args = parser.parse_args()
    if not args.vlc.is_file():
        raise SystemExit("Fetch the video runtime with ./fetch-video-dependencies.sh windows first.")
    with args.vlc.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != VLC_DIGEST:
            raise SystemExit("The VideoLAN package did not match the pinned checksum.")
    if hashlib.sha256(args.sdk.read_bytes()).hexdigest() != SDK_DIGEST:
        raise SystemExit("The WebView2 SDK package did not match the pinned checksum.")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        stage = Path(temp)
        flags = ["/nologo", "/target:winexe", "/platform:anycpu", "/langversion:5", "/optimize+",
                 "/codepage:65001", "/nostdlib+", "/out:" + str(args.output / "iPlex.exe")]
        def embed(file, name):
            flags.append(f"/resource:{file},Desktop.{name}")
        for reference in ("mscorlib", "System", "System.Core", "System.Drawing", "System.Windows.Forms",
                          "System.Web.Extensions", "System.Net.Http", "System.Security",
                          "System.IO.Compression", "System.Xml"):
            flags.append("/reference:" + str(args.references / (reference + ".dll")))
        with ZipFile(args.sdk) as sdk:
            for lib in ("Microsoft.Web.WebView2.Core.dll", "Microsoft.Web.WebView2.WinForms.dll"):
                file = stage / lib
                file.write_bytes(sdk.read("lib/net462/" + lib))
                flags.append("/reference:" + str(file))
                embed(file, lib)
            for arch in ("x86", "x64", "arm64"):
                name = arch + ".WebView2Loader.dll"
                file = stage / name
                file.write_bytes(sdk.read(f"runtimes/win-{arch}/native/WebView2Loader.dll"))
                embed(file, name)
                sqlite = stage / (arch + ".sqlite3.dll")
                sqlite.write_bytes(sqlite_binary(arch))
                embed(sqlite, sqlite.name)
            for name in ("LICENSE.txt", "NOTICE.txt"):
                (stage / ("WebView2-" + name)).write_bytes(sdk.read(name))
        with ZipFile(args.vlc) as vlc:
            for arch in ("x86", "x64", "arm64"):
                archive = stage / f"VLC-{arch}.zip"
                package_vlc(vlc, arch, archive)
                embed(archive, archive.name)
        for arch in ("x86", "x64"):
            name = f"Lossless-{arch}.exe"
            embed(args.codecs / name, name)
        site = stage / "site.zip"
        with ZipFile(site, "w", ZIP_DEFLATED) as web:
            for p in sorted((ROOT / "Web").glob("*")):
                if p.is_file() and p.suffix in (".js", ".html", ".css"):
                    web.write(p, p.name)
            for name in ICONS:
                icon = stage / (name + ".ico")
                make_icon(ASSETS / (name + ".png"), icon)
                web.write(icon, icon.name)
            for name in (DEFAULT_ICON + ".png", "wordmark.png", "music-wordmarks.png"):
                web.write(ASSETS / name, name)
            for mark in sorted((ASSETS / "HeaderMarks").glob("*.png")):
                web.write(mark, "HeaderMarks/" + mark.name)
            for background in sorted((ASSETS / "GlassBackgrounds").glob("*.jpg")):
                web.write(background, "GlassBackgrounds/" + background.name)
        embed(site, "site.zip")
        flags.append("/win32icon:" + str(stage / (DEFAULT_ICON + ".ico")))
        command = [str(args.compiler)]
        if args.compiler.suffix == ".dll":
            command.insert(0, os.environ.get("DOTNET_HOST_PATH", "dotnet"))
        subprocess.run(command + flags + [str(p) for p in sorted(ROOT.glob("*.cs"))], check=True)
        with ZipFile(args.output / "iPlex.Windows.zip", "w", ZIP_DEFLATED) as bundle:
            bundle.write(args.output / "iPlex.exe", "iPlex.exe")
            bundle.write(stage / (DEFAULT_ICON + ".ico"), "Icons/Prismatic Note Light.ico")
            bundle.write(ROOT / "HLS-js-LICENSE.txt", "Notices/HLS-js-LICENSE.txt")
            for name in ("VideoLAN-LICENSE.txt", "VideoLAN-SOURCE.txt"):
                bundle.write(ASSETS / name, "Notices/" + name)
            for name in ("WebView2-LICENSE.txt", "WebView2-NOTICE.txt"):
                bundle.write(stage / name, "Notices/" + name)
            for name in ("COPYING.LGPLv2.1", "ThirdParty.txt"):
                bundle.write(args.codecs / name, "Notices/" + name)


if __name__ == "__main__":
    main()
