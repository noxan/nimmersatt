app: .build/AppIcon.icns
	swift build -c release
	rm -rf Nimmersatt.app && mkdir -p Nimmersatt.app/Contents/{MacOS,Resources}
	cp .build/release/Nimmersatt Nimmersatt.app/Contents/MacOS/
	cp Info.plist Nimmersatt.app/Contents/
	cp .build/AppIcon.icns Nimmersatt.app/Contents/Resources/
	codesign --force -s - Nimmersatt.app

.build/AppIcon.icns: Assets/AppIcon.png
	mkdir -p .build/AppIcon.iconset
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size $< --out .build/AppIcon.iconset/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$((size * 2)) $$((size * 2)) $< --out .build/AppIcon.iconset/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns .build/AppIcon.iconset -o $@

check:
	swift run -c release Nimmersatt --check

.PHONY: app check release

release:
	./release.sh
