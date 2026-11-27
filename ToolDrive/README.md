# Embedded Tool Drive archive

This directory carries the platform implementations from the adjacent Tool Drive Offline project. The macOS and Windows folders contain their archive hosts, catalog and media services, and prepared WebKit or WebView2 resources. The mobile framework uses the standalone native catalog, discovery, playback, offline library, and visualizer code.

The hosts share iPlex's window and navigation. Tool Drive's Plex setup and archive data are scoped to the embedded archive. iPlex handles app updates and app-wide icon choices. The prepared desktop resources include the offline catalog and the licenses or attribution that accompany it. Catalog metadata is attributed in the bundled NOTICE.md.

To refresh a desktop catalog UI from the standalone source, use its macOS App/prepare-resources.py script and its --windows mode for the Windows payload. Keep the platform host adaptations when updating the archive services. Do not copy standalone executable updaters into the embedded archive.
