APP = CheongyakCal
NAME = 청약캘린더
DIST = dist/$(NAME).app

.PHONY: build secrets bundle icon run install dist-zip clean

SECRETS = Sources/CheongyakCal/Secrets.swift

# ../.env의 DATA_GO_KR_KEY를 읽어 Secrets.swift 생성 (git 제외 파일)
secrets:
	@key=$$(grep '^DATA_GO_KR_KEY=' ../.env | cut -d= -f2); \
	if [ -z "$$key" ]; then echo "❌ ../.env에 DATA_GO_KR_KEY가 없습니다"; exit 1; fi; \
	sed "s|__DATA_GO_KR_KEY__|$$key|" $(SECRETS).template > $(SECRETS); \
	echo "🔑 Secrets.swift 생성됨"

build: secrets
	swift build -c release

icon:
	rm -rf /tmp/cheongyak.iconset
	mkdir -p /tmp/cheongyak.iconset
	for s in 16 32 64 128 256 512; do \
		sips -z $$s $$s ../web/icons/icon-512.png --out /tmp/cheongyak.iconset/icon_$${s}x$${s}.png >/dev/null; \
	done
	cp ../web/icons/icon-512.png /tmp/cheongyak.iconset/icon_512x512@2x.png
	iconutil -c icns /tmp/cheongyak.iconset -o /tmp/AppIcon.icns

bundle: build icon
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources/web
	cp .build/release/$(APP) $(DIST)/Contents/MacOS/
	cp Info.plist $(DIST)/Contents/
	cp /tmp/AppIcon.icns $(DIST)/Contents/Resources/
	cp ../web/index.html $(DIST)/Contents/Resources/web/
	cp -R ../web/vendor $(DIST)/Contents/Resources/web/
	codesign --force --sign - $(DIST)

run: bundle
	pkill -x $(APP) 2>/dev/null || true
	open $(DIST)

install: bundle
	pkill -x $(APP) 2>/dev/null || true
	rm -rf "/Applications/$(NAME).app"
	cp -R $(DIST) /Applications/
	open "/Applications/$(NAME).app"

dist-zip: bundle
	cd dist && ditto -c -k --keepParent "$(NAME).app" "$(NAME).zip"
	@echo "배포 파일: macapp/dist/$(NAME).zip"

clean:
	rm -rf .build dist
