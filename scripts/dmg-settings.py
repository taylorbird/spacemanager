# dmgbuild settings for the release DMG (used by scripts/package-dmg.sh).
# Defines passed with -D: app (path to "Space Manager.app"), background (TIFF).
# Icon centers must match appX/appsX/iconY in scripts/render-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
appname = os.path.basename(app)

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

background = defines["background"]  # noqa: F821
window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
show_icon_preview = False
icon_size = 128
text_size = 13
icon_locations = {appname: (170, 196), "Applications": (470, 196)}
