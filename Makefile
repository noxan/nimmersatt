app:
	swift build -c release
	rm -rf Nimmersatt.app && mkdir -p Nimmersatt.app/Contents/MacOS
	cp .build/release/Nimmersatt Nimmersatt.app/Contents/MacOS/
	cp Info.plist Nimmersatt.app/Contents/
	codesign --force -s - Nimmersatt.app

check:
	swift run -c release Nimmersatt --check

.PHONY: app check
