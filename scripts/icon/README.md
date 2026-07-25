# Icon

`AppIcon.icns` in `Resources/` is generated, not hand-drawn. Rebuild it with:

```sh
swiftc -swift-version 6 scripts/icon/build-icns.swift -o /tmp/build-icns
/tmp/build-icns /path/to/flat-1024.png /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```

The source mark lives in `github.com/iannuttall/png2svg` (`icon/flat-1024.png` —
the white P with the plug as a real cutout, on transparency).

## Why the effects are baked in

macOS 15 and earlier do no compositing of app icons: the squircle, the inset, the
drop shadow, the body gradient and the glyph's glow all have to be in the artwork.
Apple's grid puts the body in the middle 824 of a 1024 canvas with a corner radius
of ~22.37% of the body, continuous curvature.

The glow is two stacked shadows at zero offset — a tight core and a wider halo.
It's deliberately restrained: a stronger bloom bled into the plug cutout and
softened the one detail the mark depends on.

## macOS 26

Tahoe masks and lights icons itself from layered artwork, so a `.icon` built in
Icon Composer would render better there — glass material, and automatic dark,
tinted and clear variants. That needs the Icon Composer GUI and an `actool` step
in `build-app.sh`, neither of which is wired up yet. Until then this `.icns` is
used on every version, which is correct everywhere and merely not special on 26.
