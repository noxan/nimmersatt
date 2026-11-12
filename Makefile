app: .build/icon-assets/Assets.car Assets/AppIcon-preview.png
	swift build -c release
	rm -rf Nimmersatt.app && mkdir -p Nimmersatt.app/Contents/{MacOS,Resources}
	cp .build/release/Nimmersatt Nimmersatt.app/Contents/MacOS/
	cp Info.plist Nimmersatt.app/Contents/
	cp .build/icon-assets/AppIcon.icns Nimmersatt.app/Contents/Resources/
	cp .build/icon-assets/Assets.car Nimmersatt.app/Contents/Resources/
	codesign --force -s - Nimmersatt.app

.build/icon-assets/Assets.car: Assets/AppIcon.png Assets/AppIcon.icon/icon.json
	mkdir -p .build/AppIcon.icon/Assets .build/icon-assets
	cp Assets/AppIcon.icon/icon.json .build/AppIcon.icon/
	cp Assets/AppIcon.png .build/AppIcon.icon/Assets/
	xcrun actool .build/AppIcon.icon --compile .build/icon-assets --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist .build/icon-assets/Info.plist

Assets/AppIcon-preview.png: .build/icon-assets/Assets.car
	sips -s format png .build/icon-assets/AppIcon.icns --out $@ >/dev/null

check:
	swift run -c release Nimmersatt --check

screenshot:
	swift run -c release Nimmersatt --snapshot Assets/screenshot.png --demo

.PHONY: app check release screenshot

release:
	./release.sh
