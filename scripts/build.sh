#!/bin/bash
#
# build.sh — PTT UETS (e-Tebligat) E-İmza için native Apple Silicon (arm64) .app üretir.
#
# Kaynak: https://api.etebligat.gov.tr/v1/auth/_eimza/uets-eimza.jnlp
#   Java Web Start uygulaması; JWS Java 11+'da kaldırıldığı için Mac'te açılamıyor.
#   Çözüm: ana jar + main-class'ı jpackage ile arm64 **Java 11** runtime'ı GÖMÜLEREK
#   çift-tıkla açılan native .app'e paketle.
#
# UETS ≠ PTT KEP Webmail (KRİTİK):
#   UETS e-Tebligat (etebligat.gov.tr) ile PTT KEP Webmail (ptt.hs01.kep.tr) AYRI
#   sistemlerdir; her biri kendi jar'ını sunar. Main-Class'ları aynı olsa da işlem
#   kodları karşılıklı geçmez — yanlış uygulamaya kod girilirse sunucu şunu döner:
#   "İmzalama işlemi için E-İmza uygulamasını işlem yapmak istediğiniz arayüzden
#   indirerek…". Bu yüzden UETS için AYRI bir .app (ayrı bundle-id) paketlenir.
#
# Neden Java 11 (Java 8 değil):
#   - Java 11 = otomatik HiDPI (JEP 263) → Retina'da KESKİN metin (Java 8 arm64 Swing bulanık).
#   - uets-eimza.jar = Java 8 bytecode (major 52) → Java 11'de sorunsuz çalışır.
#
# Kart erişimi:
#   - Jar, IAIK PKCS#11 wrapper DEĞİL, TÜBİTAK ESYA API (APDUSmartCard) +
#     javax.smartcardio kullanır → e-Devlet paketleyicisindeki Javassist
#     connect-fix patch'i GEREKMEZ.
#   - AKİS için kullanıcıda **arm64** AKİS middleware kurulu olmalı.
#
# Kritik ek:
#   - JNLP, uygulamaya jnlp.config property'sini geçirir; sunucu adresleri
#     (getdata/setdata) bu config.properties'ten okunur. .app'e -Djnlp.config=<URL>
#     gömülmezse uygulama sunucuyu bulamaz.
#
# Tam JRE şart (jlink-strip DEĞİL): smartcardio/crypto provider'ları için
#   --runtime-image <tam arm64 Zulu 11>.
#
# + ASCII executable adı (codesign Türkçe karakterle bozuluyor) + ad-hoc imza
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
DOWNLOADS="$ROOT/downloads"

APP_NAME="PTT UETS E-İmza"          # görünen ad (Türkçe)
APP="$BUILD/$APP_NAME.app"
ASCII_NAME="PTTUETSEImza"           # executable/CFBundleExecutable (ASCII şart, codesign)
# PTT KEP paketleyicisi tr.gov.ptt.kep.digitalsignature kullanıyor; ikisi aynı Mac'te
# yan yana kurulabilsin diye burada AYRI bir bundle-id şart.
BUNDLE_ID="tr.gov.ptt.uets.digitalsignature"
MAIN_CLASS="tr.gov.ptt.kep.digitalsignature.swing.FrmApplet"
MAIN_JAR="uets-eimza.jar"
# Görünen ürün sürümü: JNLP'deki <jar version="1.1.60"> değeri. config.properties'te
# sürüm alanı YOK (KEP'teki applet.version burada bulunmuyor). CFBundleVersion buna
# eşitlenir; yayın etiketi <APP_VERSION>_<N> olur.
#
# NOT (tutarsızlık): uygulamanın pencere başlığı "UETS v1.1.50" yazıyor — jar içindeki
# sürüm sabiti güncellenmemiş. Tek bir jar var (uets-eimza.jar,
# ?version-id=1.1.60 ve uets-eimza__V1.1.60.jar aynı baytları döndürüyor), dolayısıyla
# 1.1.60 = dağıtım sürümü, 1.1.50 = jar'ın kendi (bayat) etiketi. PTT jar'ı
# güncellediğinde DEĞİŞEN değer JNLP'deki olduğu için sürümleme buna bağlanır.
APP_VERSION="${APP_VERSION:-1.1.60}"

CODEBASE="https://api.etebligat.gov.tr/v1/auth/_eimza"
JAR_URL="${JAR_URL:-$CODEBASE/$MAIN_JAR}"
CONFIG_URL="$CODEBASE/config.properties"
JAR_FILE="$DOWNLOADS/$MAIN_JAR"
# İkon: JNLP <icon href="logo.png"/> → codebase'de MEVCUT (250x173 UETS amblemi).
# Kare olmadığı için icns üretilirken şeffaf dolguyla kareye ortalanır.
# Codebase erişilemezse jar içindeki images/logo.png'ye (200x200) düşülür — ama o,
# PTT KEP damgasıdır; iki uygulamanın ikonu aynı görünür.
ICON_PNG="$DOWNLOADS/logo.png"
ICON_URL="$CODEBASE/logo.png"
ICON_IN_JAR="images/logo.png"
ICNS="$BUILD/$ASCII_NAME.icns"

# Gömülecek arm64 Java 11 (runtime). 'jdk' hedefi Azul Zulu 11'i kurar.
JDK11_DEST="$HOME/Library/Java/JavaVirtualMachines/zulu-11-arm64.jdk"
# jpackage için 17+ JDK. 'jpackage-jdk' Zulu 21 kurar.
JDK21_DEST="$HOME/Library/Java/JavaVirtualMachines/zulu-21-arm64.jdk"

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m▸\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

# Gerçekten istenen major sürüm mü (java_home yanlış sürüm döndürebiliyor)
jhome() {  # $1=major  $2=hedef .jdk
	if [ -x "$2/Contents/Home/bin/java" ]; then echo "$2/Contents/Home"; return 0; fi
	local h; h="$(/usr/libexec/java_home -v "$1" -a arm64 2>/dev/null || true)"
	if [ -n "$h" ] && "$h/bin/java" -version 2>&1 | grep -q "version \"$1"; then echo "$h"; fi
	return 0
}
jdk11_home() { jhome 11 "$JDK11_DEST"; }

find_jpackage() {
	local v jh
	for v in 25 24 23 22 21 20 19 18 17; do
		jh="$(/usr/libexec/java_home -v "$v" -a arm64 2>/dev/null || true)"
		[ -n "$jh" ] && [ -x "$jh/bin/jpackage" ] && { echo "$jh/bin/jpackage"; return 0; }
	done
	local home
	for home in $(/usr/libexec/java_home -V 2>&1 | grep -oE '/[^ ]+/Contents/Home' | sort -u); do
		[ -x "$home/bin/jpackage" ] && { echo "$home/bin/jpackage"; return 0; }
	done
	return 1
}

install_zulu() {  # $1=java_version  $2=hedef .jdk
	c_info "Azul Zulu $1 (aarch64) indiriliyor…"
	local url
	url="$(curl -s "https://api.azul.com/metadata/v1/zulu/packages/?java_version=$1&os=macos&arch=aarch64&archive_type=tar.gz&java_package_type=jdk&javafx_bundled=false&latest=true&release_status=ga&availability_types=CA&page=1&page_size=1" \
		| /usr/bin/python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["download_url"])')"
	[ -n "$url" ] || die "Zulu $1 URL'si alınamadı."
	mkdir -p "$DOWNLOADS"; local tmp="$DOWNLOADS/zulu$1.tgz"
	curl -fSL --retry 5 -o "$tmp" "$url"
	gzip -t "$tmp" 2>/dev/null || die "Zulu $1 indirme bozuk."
	local stage; stage="$(mktemp -d)"; tar xzf "$tmp" -C "$stage"
	local b; b="$(find "$stage" -maxdepth 1 -type d -name 'zulu*' | head -1)"
	[ -n "$b" ] || die "Zulu $1 arşiv yapısı farklı."
	mkdir -p "$(dirname "$2")"; rm -rf "$2"; mv "$b" "$2"; rm -rf "$stage"
}

# ----- Hedefler -----

check_deps() {
	c_info "Ön koşullar denetleniyor…"
	local t
	for t in curl unzip zip codesign plutil sips iconutil shasum; do
		command -v "$t" >/dev/null 2>&1 || die "Gerekli araç yok: $t"
	done
	c_ok "Araçlar mevcut"
	local ok=0
	[ -n "$(jdk11_home)" ] && c_ok "arm64 Java 11 (runtime): $(jdk11_home)" || { c_warn "arm64 Java 11 YOK → scripts/build.sh jdk"; ok=1; }
	if jp="$(find_jpackage)"; then c_ok "jpackage: $jp"; else c_warn "jpackage'lı 17+ JDK YOK → scripts/build.sh jpackage-jdk"; ok=1; fi
	return $ok
}

jdk() {
	[ -n "$(jdk11_home)" ] && { c_ok "arm64 Java 11 zaten kurulu."; return 0; }
	install_zulu 11 "$JDK11_DEST"
	[ -n "$(jdk11_home)" ] && c_ok "Kuruldu: $JDK11_DEST" || die "Java 11 kurulum sonrası görünmüyor."
}

jpackage_jdk() {
	find_jpackage >/dev/null 2>&1 && { c_ok "jpackage zaten var."; return 0; }
	install_zulu 21 "$JDK21_DEST"
	find_jpackage >/dev/null 2>&1 && c_ok "jpackage hazır." || die "jpackage bulunamadı."
}

download() {
	c_info "$MAIN_JAR indiriliyor (codebase: $CODEBASE)…"
	mkdir -p "$DOWNLOADS" "$BUILD"
	# NOT: api.etebligat.gov.tr HEAD isteklerine 404 döner; yalnızca GET çalışır
	# (curl -I ile denetlemeye kalkma).
	[ -s "$JAR_FILE" ] && c_ok "Önbellekten: $JAR_FILE ($(du -h "$JAR_FILE" | cut -f1))" \
		|| { c_info "İndiriliyor: $JAR_URL"; curl -fL --retry 3 -o "$JAR_FILE" "$JAR_URL"; }
	# Doğrula: main-class. Manifest ~1.3 MB (her sınıfın SHA-256'sı var) → yalnızca
	# başı okunur. `unzip -p | head` KULLANMA: head erken çıkınca unzip SIGPIPE alır
	# ve `set -o pipefail` yüzünden betik 141 ile ölür. Önce dosyaya al.
	local mf tmpmf; tmpmf="$(mktemp)"
	unzip -p "$JAR_FILE" META-INF/MANIFEST.MF > "$tmpmf" || die "jar'dan manifest okunamadı (bozuk indirme?)."
	mf="$(head -40 "$tmpmf")"; rm -f "$tmpmf"
	[[ "$mf" == *"$MAIN_CLASS"* ]] || die "Main-Class bulunamadı (bozuk jar?)."
	c_ok "jar doğrulandı (Main-Class: $MAIN_CLASS)"
	# İkon: önce codebase'deki UETS amblemi, olmazsa jar içindeki KEP damgası.
	if [ ! -s "$ICON_PNG" ]; then
		c_info "İkon indiriliyor: $ICON_URL"
		if curl -fL --retry 2 -o "$ICON_PNG" "$ICON_URL" 2>/dev/null \
			&& [ "$(head -c 4 "$ICON_PNG" | xxd -p)" = "89504e47" ]; then
			c_ok "UETS amblemi indirildi ($(sips -g pixelWidth -g pixelHeight "$ICON_PNG" | awk '/pixel/{printf "%s ",$2}'))"
		else
			rm -f "$ICON_PNG"
			c_warn "codebase'de logo.png yok → jar içindeki $ICON_IN_JAR kullanılacak (PTT KEP damgası)."
			unzip -p "$JAR_FILE" "$ICON_IN_JAR" > "$ICON_PNG" || die "İkon jar'dan çıkarılamadı."
		fi
	fi
	[ -s "$ICON_PNG" ] || die "İkon hazırlanamadı."
	c_ok "İkon hazır: $ICON_PNG"
}

icns() {
	[ -s "$ICON_PNG" ] || die "Önce 'download' çalıştır (ikon yok)."
	c_info ".icns üretiliyor…"
	mkdir -p "$BUILD"
	local w h master="$BUILD/_icon_master.png"
	w="$(sips -g pixelWidth  "$ICON_PNG" | awk '/pixelWidth/{print $2}')"
	h="$(sips -g pixelHeight "$ICON_PNG" | awk '/pixelHeight/{print $2}')"
	# 512x512 kare master üret. Kaynak kare değilse (UETS amblemi 250x173) en uzun
	# kenarı 480'e ölçekle ve şeffaf dolguyla 512'lik kareye ORTALA — 'sips -p'
	# dolguyu RGBA(0,0,0,0) yapar, alfa korunur. (Geniş bir kelime-logosu kaçınılmaz
	# olarak dikeyde letterbox olur; 480 = %94 doluluk, kenarda ince boşluk kalır.)
	if [ "$w" = "$h" ]; then
		sips -z 512 512 "$ICON_PNG" --out "$master" >/dev/null
	else
		c_info "kaynak kare değil (${w}x${h}) → şeffaf dolguyla kareye ortalanıyor"
		sips -Z 480 "$ICON_PNG" --out "$master" >/dev/null
		sips -p 512 512 "$master" --out "$master" >/dev/null
	fi
	# Tüm boyutlar tek master'dan → her ölçekte aynı kenar boşluğu.
	local set; set="$BUILD/$ASCII_NAME.iconset"; rm -rf "$set"; mkdir -p "$set"
	local s d
	for s in 16 32 128; do
		sips -z "$s" "$s" "$master" --out "$set/icon_${s}x${s}.png" >/dev/null
		d=$((s*2))
		sips -z "$d" "$d" "$master" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
	done
	sips -z 256 256 "$master" --out "$set/icon_256x256.png"    >/dev/null
	sips -z 512 512 "$master" --out "$set/icon_256x256@2x.png" >/dev/null
	sips -z 512 512 "$master" --out "$set/icon_512x512.png"    >/dev/null
	iconutil -c icns "$set" -o "$ICNS" || die "iconutil başarısız."
	rm -rf "$set" "$master"
	c_ok ".icns üretildi: $ICNS"
}

package() {
	[ -s "$JAR_FILE" ] || die "Önce 'download' çalıştır."
	[ -s "$ICNS" ] || icns
	local jp; jp="$(find_jpackage)" || die "jpackage yok → scripts/build.sh jpackage-jdk"
	local rt; rt="$(jdk11_home)"; [ -n "$rt" ] || die "Java 11 yok → scripts/build.sh jdk"
	[ -f "$rt/lib/jli/libjli.dylib" ] || die "Java 11 runtime layout farklı: $rt"

	c_info "jpackage girdisi hazırlanıyor…"
	local in="$BUILD/_input"; rm -rf "$in"; mkdir -p "$in"
	cp "$JAR_FILE" "$in/"

	c_info "jpackage ile .app paketleniyor (Java 11 gömülü, v$APP_VERSION)…"
	rm -rf "$APP" "$BUILD/$ASCII_NAME.app"
	# jnlp.user.language/country: JNLP'nin uygulamaya geçirdiği property'ler (KEP'te yok).
	"$jp" --type app-image --name "$ASCII_NAME" --app-version "$APP_VERSION" \
		--input "$in" --main-jar "$MAIN_JAR" --main-class "$MAIN_CLASS" \
		--runtime-image "$rt" \
		--java-options "-Djnlp.config=$CONFIG_URL" \
		--java-options "-Djnlp.user.language=tr" \
		--java-options "-Djnlp.user.country=TR" \
		--icon "$ICNS" \
		--mac-package-identifier "$BUNDLE_ID" \
		--dest "$BUILD" 2>&1 | grep -viE 'NoSuchElement|No value' || true
	[ -d "$BUILD/$ASCII_NAME.app" ] || die "jpackage .app üretemedi."

	local plist="$BUILD/$ASCII_NAME.app/Contents/Info.plist"
	plutil -replace CFBundleName -string "$APP_NAME" "$plist"
	plutil -replace CFBundleDisplayName -string "$APP_NAME" "$plist" 2>/dev/null \
		|| plutil -insert CFBundleDisplayName -string "$APP_NAME" "$plist"
	# Retina keskinlik (JEP 263 + bu bayrak)
	plutil -replace NSHighResolutionCapable -bool true "$plist"
	mv "$BUILD/$ASCII_NAME.app" "$APP"
	c_ok "Paketlendi: $APP ($(du -sh "$APP" | cut -f1))"
}

sign() {
	[ -d "$APP" ] || die "Önce 'package' çalıştır."
	c_info "ad-hoc imzalanıyor…"
	find "$APP" -name '._*' -delete 2>/dev/null || true
	codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
	codesign --verify --strict "$APP" 2>/dev/null && c_ok "İmza geçerli (adhoc, strict)" || die "İmza doğrulanamadı."
}

run() {
	[ -d "$APP" ] || die "Önce 'all' çalıştır."
	c_info "Açılıyor: $APP"
	open "$APP"
}

# DMG arka planını assets/dmg-background.svg'den üretir: 1x + 2x PNG → HiDPI tiff.
# (rsvg-convert: brew install librsvg ; tiffutil: macOS yerleşik)
assets() {
	local svg="$ROOT/assets/dmg-background.svg"
	[ -f "$svg" ] || die "Kaynak yok: $svg"
	command -v rsvg-convert >/dev/null || die "rsvg-convert yok → brew install librsvg"
	command -v tiffutil >/dev/null || die "tiffutil yok (macOS yerleşik olmalı)"
	c_info "DMG arka planı üretiliyor (svg → png 1x/2x → tiff)…"
	rsvg-convert -w 660  -h 440 "$svg" -o "$ROOT/assets/dmg-background.png"
	rsvg-convert -w 1320 -h 880 "$svg" -o "$ROOT/assets/dmg-background@2x.png"
	tiffutil -cathidpicheck "$ROOT/assets/dmg-background.png" "$ROOT/assets/dmg-background@2x.png" \
		-out "$ROOT/assets/dmg-background.tiff" >/dev/null
	c_ok "Arka plan: assets/dmg-background.tiff"
}

# Sürükle-bırak yerleşimli .dmg üret (arka plan: assets/dmg-background.tiff).
# İkon konumları arka plandaki boş yuvalarla eşleşir: uygulama (170,220), Applications (490,220).
# DMG_OUT ile çıktı yolu özelleştirilebilir (CI sürüm etiketli ad verir).
dmg() {
	[ -d "$APP" ] || die "Önce 'package' (+ 'sign') çalıştır."
	command -v create-dmg >/dev/null || die "create-dmg yok → brew install create-dmg"
	local bg="$ROOT/assets/dmg-background.tiff"
	[ -f "$bg" ] || assets
	local out="${DMG_OUT:-$BUILD/$ASCII_NAME-arm64.dmg}"
	rm -f "$out"
	c_info "DMG üretiliyor (sürükle-bırak yerleşimi)…"
	create-dmg \
		--volname "$APP_NAME" \
		--background "$bg" \
		--window-pos 200 120 \
		--window-size 660 440 \
		--icon-size 120 \
		--icon "$APP_NAME.app" 170 220 \
		--app-drop-link 490 220 \
		--hide-extension "$APP_NAME.app" \
		--no-internet-enable \
		"$out" "$APP" \
		|| die "create-dmg başarısız."
	[ -f "$out" ] || die "DMG üretilemedi."
	c_ok "DMG: $out ($(du -sh "$out" | cut -f1))"
}

all() {
	check_deps || die "Ön koşul eksik (jdk / jpackage-jdk)."
	download; icns; package; sign
	echo
	c_ok "BİTTİ → $APP"
	c_info "Çalıştır: open \"$APP\"   |   Kur: /Applications'a sürükle"
	c_warn "E-imza ancak gerçek kart + arm64 PKCS#11 middleware (AKİS) ile test edilebilir."
	c_warn "Bu uygulama YALNIZCA UETS (e-Tebligat) işlem kodları içindir; PTT KEP Webmail için ayrı uygulama gerekir."
}

clean()     { c_info "build/ temizleniyor…"; rm -rf "$BUILD"; c_ok "temiz"; }
distclean() { c_info "build/ + downloads/ temizleniyor…"; rm -rf "$BUILD" "$DOWNLOADS"; c_ok "temiz"; }

help() {
	cat <<EOF
build.sh — PTT UETS E-İmza native arm64 .app üretici (Java 11 gömülü)

Hedefler:
  all          Tüm hattı çalıştır (varsayılan): download → icns → package → sign
  check-deps   Araç + arm64 Java 11 + jpackage denetimi
  jdk          Gömülecek arm64 Java 11 yoksa Azul Zulu 11 kur
  jpackage-jdk jpackage'lı 17+ JDK yoksa Azul Zulu 21 kur
  download     uets-eimza.jar indir + doğrula + ikonu hazırla
  icns         .icns ikon üret (kare olmayan amblem şeffaf dolguyla ortalanır)
  package      jpackage ile .app üret (Java 11 gömülü + -Djnlp.config)
  sign         ad-hoc codesign
  run          üretilen .app'i aç
  assets       DMG arka planını svg'den üret (rsvg-convert + tiffutil)
  dmg          sürükle-bırak yerleşimli .dmg üret (create-dmg; DMG_OUT ile ad)
  clean / distclean

Ortam: JAR_URL (kaynak), APP_VERSION (vars: $APP_VERSION)
EOF
}

case "${1:-all}" in
	all) all ;; check-deps) check_deps ;; jdk) jdk ;; jpackage-jdk) jpackage_jdk ;;
	download) download ;; icns) icns ;; package) package ;; sign) sign ;; run) run ;;
	assets) assets ;; dmg) dmg ;;
	clean) clean ;; distclean) distclean ;;
	help|-h|--help) help ;;
	*) die "Bilinmeyen hedef: $1  (scripts/build.sh help)" ;;
esac
