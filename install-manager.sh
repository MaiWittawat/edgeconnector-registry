#!/bin/sh
# install-manager.sh = ติดตั้ง / อัปเกรด edgeconnector manager เป็น systemd service (Linux + systemd · POSIX sh)
#
#   curl -fsSL <RELEASE_URL>/install-manager.sh | sudo sh -s -- --token cce1.xxx --server center.example.com:7443
#
# option:
#   --token T            enrollment token ชนิด manager (หรือ env CC_TOKEN) · token ไม่ถูกเขียนลงดิสก์
#   --server HOST:PORT   ที่อยู่ center (ติดตั้งครั้งแรกต้องมี)
#   --version V          version ของ manager · ไม่ใส่ = ตาม channel
#   --channel C          channel (ค่าเริ่มต้น stable)
#   --base-url URL       registry (ค่าเริ่มต้น = RELEASE_URL ที่ฝังไว้)
#   --trusted-key ID=B64 key ที่เชื่อถือ ใส่ซ้ำได้ (ค่าเริ่มต้น = TRUSTED_KEYS ที่ฝังไว้)
#   --ca-cert-file F     CA ส่วนตัวของ center → คัดลอกไป /etc/edgeconnector/ca.pem
#   --reenroll           ล้างตัวตนเดิมแล้ว enroll ใหม่ด้วย --token (ย้ายเครื่อง / กู้เครื่อง)
#   --uninstall          หยุดและลบทุกอย่างของ edgeconnector ออกจากเครื่อง (ใช้คนเดียว ไม่รับ option อื่น · ดู uninstall ข้างล่าง)
#
# ถอนแบบ offline (เครื่องออกเน็ตไม่ได้): ตอนติดตั้ง script เก็บสำเนาจาก registry ไว้ที่ /usr/local/lib/edgeconnector/install-manager.sh
#   sudo sh /usr/local/lib/edgeconnector/install-manager.sh --uninstall
#
# คำสั่งหน้างาน: script ติดตั้ง /usr/local/bin/edgeconnector (wrapper = scripts/edgeconnector) → sudo edgeconnector help
#
# ตอน publish `make manager-release` ฝังค่าลงไฟล์นี้แล้ววางที่รากของ registry:
#   บรรทัด RELEASE_URL / TRUSTED_KEYS ด้านล่าง (placeholder ที่ไม่ถูกแทน = ถือว่าว่าง)
#   บรรทัด @@MANAGER_GUARD@@ ใน write_guard = เนื้อหาของ scripts/manager-guard
#   บรรทัด @@EDGECONNECTOR_CLI@@ ใน write_cli = เนื้อหาของ scripts/edgeconnector
#
# ขั้นตอน (ไม่แตะเครื่องจนกว่าจะตรวจ option, manifest, sha256 และลายเซ็นผ่าน):
#   โหลด manifest + archive ของ manager → ตรวจ → แตกลง /opt/edgeconnector/manager/versions/<v> → manager.env →
#   enroll (ถ้าต้อง) → manager-guard + unit → สลับ current → restart →
#   ไม่ขึ้นใน 15 วินาที = คืน current, manager.env, ca.pem เป็นของเดิม
# รันซ้ำ = อัปเกรด / เปลี่ยนค่าเฉพาะที่ส่งมา (บรรทัดอื่นใน manager.env ไม่แตะ)
#
# ความปลอดภัย: /opt/edgeconnector/manager และ /var/lib/edgeconnector/manager เป็นของ user edgeconnector
# → root ไม่ทำอะไรผ่าน path ข้างในนั้น (อาจมี symlink ที่ถูกวางไว้): แตก archive / สลับ current ทำเป็น edgeconnector (runuser)
#   root แค่สร้างสองโฟลเดอร์นั้นครั้งแรก (ในโฟลเดอร์แม่ที่เป็นของ root) และอ่านว่ามีไฟล์อยู่ไหม
#
# test: INSTALL_MANAGER_DRY_RUN=1 = จบหลังตรวจผ่าน (พิมพ์ "verified manager <v> <os>_<arch>") ไม่แตะเครื่อง ·
#       กับ --uninstall = พิมพ์คำสั่งที่จะรันทีละบรรทัด ("would run: ...") ไม่แตะเครื่อง ·
#       INSTALL_MANAGER_PLATFORM=linux_amd64 = ใช้แทน uname
set -eu
umask 022

RELEASE_URL="https://raw.githubusercontent.com/MaiWittawat/edgeconnector-registry/main"
TRUSTED_KEYS="lab-2026=gK3QtGj9wHs/Vm07udIW31CySE3MVP5e/3dUj0aIXV8="

SELF=/opt/edgeconnector/manager
DATA=/var/lib/edgeconnector/manager
ETC=/etc/edgeconnector
ENV_FILE=$ETC/manager.env
CA_DEST=$ETC/ca.pem
GUARD=/usr/local/lib/edgeconnector/manager-guard
SCRIPT_COPY=/usr/local/lib/edgeconnector/install-manager.sh # สำเนาไว้ถอนแบบ offline
CLI=/usr/local/bin/edgeconnector
SERVICE=edgeconnector-manager
UNIT_FILE=/etc/systemd/system/$SERVICE.service
CHECK_UNIT=$SERVICE-update-check # timer ที่ manager-guard ตั้งตอนอัปเดตตัวเอง
RUN_USER=edgeconnector
MAX_MANIFEST=65536    # 64KB (เท่ากับฝั่ง Go)
MAX_ARCHIVE=209715200 # 200MB
MAX_SCRIPT=1048576    # 1MB (install-manager.sh ที่เก็บสำเนา)

log() { echo "install-manager: $*"; }
warn() { echo "install-manager: warning: $*" >&2; }
die() {
	echo "install-manager: error: $*" >&2
	exit 1
}

# ── ตัวช่วย ──────────────────────────────────────────────────

# version / channel ที่ใช้เป็น path ได้ (เหมือน release.ValidVersion / ValidName)
valid_version() {
	case "$1" in '' | [!0-9A-Za-z]* | *[!0-9A-Za-z.+_-]*) return 1 ;; esac
	[ ${#1} -le 64 ]
}
valid_channel() {
	case "$1" in '' | [!a-z0-9]* | *[!a-z0-9-]*) return 1 ;; esac
	[ ${#1} -le 63 ]
}

# ค่าที่จะลง manager.env ต้องเป็นบรรทัดเดียว ไม่มีช่องว่าง/เครื่องหมายคำพูด
plain() {
	[ "$(printf '%s' "$1" | tr -d '\n')" = "$1" ] &&
		printf '%s\n' "$1" | grep -Eq '^[]A-Za-z0-9._~:/?#@!&+,;=%[-]+$'
}

# ข้อความจาก manifest ที่ยังไม่ผ่านการตรวจ: เหลือเฉพาะตัวอักษรธรรมดาก่อนพิมพ์
shown() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._+=/:@ -' | cut -c 1-100; }

# field แบบ string ของ JSON ที่ย่อหน้าหนึ่ง field ต่อบรรทัด (รูปแบบที่ cc-release เขียน)
json_field() {
	sed -n 's/^[[:space:]]*"'"$1"'":[[:space:]]*"\([^"]*\)".*$/\1/p' "$2" | head -n 1
}

# fetch URL FILE MAXBYTES · CURL_PROTO จำกัด protocol (https base = https เท่านั้น รวมตอน redirect)
fetch() {
	# shellcheck disable=SC2086
	curl -fsSL $CURL_PROTO --max-filesize "$3" -o "$2" "$1"
}

file_size() { wc -c <"$1" | tr -d ' '; }

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	else
		shasum -a 256 "$1" | cut -d ' ' -f 1
	fi
}

# OpenSSL 3 ขึ้นไป (pkeyutl -rawin ของ Ed25519) · macOS ใช้ของ Homebrew
find_openssl() {
	for bin in openssl /opt/homebrew/opt/openssl@3/bin/openssl; do
		if "$bin" version 2>/dev/null | grep -q '^OpenSSL [3-9]'; then
			OPENSSL=$bin
			return 0
		fi
	done
	die "OpenSSL 3 or newer is required to check the signature: apt install openssl (Debian 12 / Ubuntu 22.04 or newer)"
}

# check_keys = ตรวจ KEYS ("id=base64,id=base64") แบบเดียวกับ release.ParseTrustedKeys
# (รายการผิดใน manager.env = manager ทุก version เปิดไม่ขึ้น)
check_keys() {
	seen=,
	set -f
	old_ifs=$IFS
	IFS=,
	for item in $KEYS; do
		[ -n "$item" ] || continue
		case "$item" in *=*) ;; *) die "trusted key \"$item\": want id=base64" ;; esac
		id=${item%%=*}
		case "$id" in '' | */* | *\\*) die "trusted key \"$item\": invalid id" ;; esac
		# Ed25519 public key 32 byte = base64 43 ตัว + "="
		printf '%s\n' "${item#*=}" | grep -Eq '^[A-Za-z0-9+/]{43}=$' ||
			die "trusted key \"$id\": not a base64 Ed25519 public key"
		case "$seen" in *",$id,"*) die "trusted key \"$id\": listed twice" ;; esac
		seen="$seen$id,"
	done
	IFS=$old_ifs
	set +f
	[ "$seen" != , ] || die "no trusted keys: pass --trusted-key <id>=<base64>"
}

# trusted_key ID = base64 ของ key ID ใน KEYS · ไม่มี = คืน 1
trusted_key() {
	set -f
	old_ifs=$IFS
	IFS=,
	found=1
	for item in $KEYS; do
		if [ "${item%%=*}" = "$1" ]; then
			printf '%s' "${item#*=}"
			found=0
			break
		fi
	done
	IFS=$old_ifs
	set +f
	return $found
}

# verify_signature KEY_B64 MESSAGE SIG_B64 = ตรวจ Ed25519 ด้วย openssl
# public key PEM = SPKI DER (prefix 12 byte ของ Ed25519 + key 32 byte)
verify_signature() {
	printf '%s' "$1" | "$OPENSSL" base64 -d -A >"$TMP/key.raw" 2>/dev/null || return 1
	[ "$(file_size "$TMP/key.raw")" = 32 ] || return 1
	printf '\060\052\060\005\006\003\053\145\160\003\041\000' >"$TMP/key.der"
	cat "$TMP/key.raw" >>"$TMP/key.der"
	{
		echo "-----BEGIN PUBLIC KEY-----"
		"$OPENSSL" base64 -in "$TMP/key.der"
		echo "-----END PUBLIC KEY-----"
	} >"$TMP/key.pem"
	printf '%s' "$3" | "$OPENSSL" base64 -d -A >"$TMP/sig" 2>/dev/null || return 1
	printf '%s' "$2" >"$TMP/msg"
	"$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/key.pem" -rawin -in "$TMP/msg" -sigfile "$TMP/sig" >/dev/null 2>&1
}

# โฟลเดอร์ที่ root เขียนลงไปตรง ๆ: ถ้ามีอยู่ต้องเป็นโฟลเดอร์จริง (ไม่ใช่ symlink) ที่เป็นของ root
check_root_dir() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		[ -d "$1" ] && [ ! -L "$1" ] && [ -z "$(find "$1" -prune ! -user 0)" ] ||
			die "$1 must be a directory owned by root"
	fi
}

# โฟลเดอร์ของ manager: ถ้ามีอยู่ต้องเป็นโฟลเดอร์จริง (root อ่านแค่ว่ามีไฟล์ไหม)
check_manager_dir() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		[ -d "$1" ] && [ ! -L "$1" ] || die "$1 must be a directory, not a symlink"
	fi
}

# งานใน SelfDir (โฟลเดอร์ของ manager) รันเป็น user ของ manager เสมอ: self_op unpack V (archive จาก stdin) | switch V
# unpack: มี versions/V/bin/manager แล้ว = ใช้ของเดิม · แตกลง versions/.V.tmp (ชื่อขึ้นต้น "." = manager ไม่นับ) แล้ว rename
# switch: ยกเลิก update/ ที่ค้าง (ไม่ให้ guard ถอยไปที่อื่น) แล้วสลับ current แบบ atomic (GNU mv -T · ไม่มี -T ใช้ ln -sfn)
SELF_OPS='
set -eu
cd "$1"
case "$2" in
unpack)
	mkdir -p versions
	if [ -f "versions/$3/bin/manager" ]; then exit 0; fi
	rm -rf "versions/.$3.tmp" "versions/$3"
	mkdir "versions/.$3.tmp"
	tar -xzf - -C "versions/.$3.tmp"
	test -f "versions/.$3.tmp/bin/manager"
	mv "versions/.$3.tmp" "versions/$3"
	;;
switch)
	rm -rf update
	if mv --help 2>&1 | grep -q -e -T; then
		rm -f .current.tmp
		ln -s "versions/$3" .current.tmp
		mv -T .current.tmp current
	else
		ln -sfn "versions/$3" current
	fi
	;;
previous)
	if [ -d update ] && [ ! -L update ] && [ -f update/previous ] && [ ! -L update/previous ]; then
		head -n 1 update/previous | tr -d "[:space:]" | cut -c 1-100
	fi
	;;
esac
'
self_op() { runuser -u "$RUN_USER" -- /bin/sh -c "$SELF_OPS" sh "$SELF" "$@"; }

# set_env KEY VALUE = แทนบรรทัด KEY= ใน $TMP/manager.env (ไม่มี = ต่อท้าย) · บรรทัดอื่นไม่แตะ
set_env() {
	ENV_VALUE=$2 awk -v k="$1" '
		index($0, k "=") == 1 { if (!done) print k "=" ENVIRON["ENV_VALUE"]; done = 1; next }
		{ print }
		END { if (!done) print k "=" ENVIRON["ENV_VALUE"] }
	' "$TMP/manager.env" >"$TMP/manager.env.new"
	mv -f "$TMP/manager.env.new" "$TMP/manager.env"
}

# install_file SRC DEST MODE = วางไฟล์ (ในโฟลเดอร์ของ root) เมื่อเนื้อหาต่างจากเดิม: เขียน DEST.tmp แล้ว rename · คืน 0 = เปลี่ยน
# ถูกเรียกใน && จึงต้อง die เอง (set -e ไม่มีผลในนั้น)
install_file() {
	if cmp -s "$1" "$2"; then
		return 1
	fi
	cp "$1" "$2.tmp" && chmod "$3" "$2.tmp" && mv -f "$2.tmp" "$2" || die "cannot write $2"
}

# คืน manager.env และ ca.pem เป็นของก่อนรัน (ใช้คู่กับการสลับ current กลับ)
restore_config() {
	if [ -f "$TMP/manager.env.bak" ]; then install_file "$TMP/manager.env.bak" "$ENV_FILE" 0600 || true; fi
	if [ -f "$TMP/ca.pem.bak" ]; then install_file "$TMP/ca.pem.bak" "$CA_DEST" 0644 || true; fi
}

# run_manager ARGS... = รัน manager ตัวใหม่เป็น user edgeconnector ด้วยค่าใน manager.env (+ CC_TOKEN ถ้ามี)
# ค่าอยู่ใน env ของคำสั่งนี้เท่านั้น (manager.env อ่านได้เฉพาะ root · token ไม่ลงดิสก์และไม่อยู่ใน argv)
run_manager() {
	(
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in [A-Za-z_]*=*) export "$line" ;; esac
		done <"$ENV_FILE"
		if [ -n "$TOKEN" ]; then
			CC_TOKEN=$TOKEN
			export CC_TOKEN
		fi
		exec runuser -u "$RUN_USER" -- "$SELF/versions/$VERSION/bin/manager" "$@"
	)
}

# enroll ARGS... = หยุด manager แล้ว enroll · ไม่ผ่าน = เปิด manager ตัวเดิมกลับแล้วหยุด
enroll() {
	systemctl stop "$SERVICE" 2>/dev/null || true
	if ! run_manager -enroll-only "$@"; then
		restore_config # ตัวตนเดิมต้องกลับไปคู่กับ center / CA เดิม (เช่น token ผิดพร้อม --server ใหม่)
		systemctl start "$SERVICE" 2>/dev/null || true
		die "enroll failed (the manager keeps its old identity, if any)"
	fi
}

# เนื้อหาของ manager-guard (make manager-release แทนบรรทัด marker ด้วย scripts/manager-guard)
write_guard() {
	cat >"$1" <<'MANAGER_GUARD_EOF'
#!/bin/sh
# manager-guard = ตัวถอยกลับของ manager ที่อยู่นอก binary (manager ตัวใหม่ที่ค้างหรือ crash วนถอยเองไม่ได้)
# install-manager.sh เขียนไฟล์นี้ไปที่ /usr/local/lib/edgeconnector/manager-guard (root 0755 · manager แก้ไม่ได้)
#
#   manager-guard          ExecStartPre=-+ ของ edgeconnector-manager.service (รันด้วย root ก่อนเปิด manager ทุกครั้ง)
#   manager-guard check    timer ที่ตั้งตอนเปิด manager ตัวใหม่ครั้งแรก (180 วินาทีหลังจากนั้น · รันด้วย root)
#   manager-guard count | rollback [สาเหตุ]   คำสั่งภายใน = งานไฟล์ใน SelfDir (root เรียกแล้วจะสลับเป็น user ของ manager เสมอ)
#
# อ่านไฟล์ที่ manager เขียนตอนอัปเดตตัวเอง (connectormanager/selfupdate.go) ใน CC_SELF_DIR (ค่าเริ่มต้น /opt/edgeconnector/manager):
#   update/{previous,next,attempts}   มี update/ = manager ตัวใหม่ยังไม่ยืนยันว่าถึง center · แต่ละไฟล์ = ข้อความบรรทัดเดียว
#   current -> versions/<v>            symlink แบบ relative
#   update-failed                      guard เขียนเมื่อถอยกลับ (manager อ่าน → รายงานใน host.status → ลบ)
#
# ไม่มี update/ = ไม่ทำอะไร · เปิดตัวใหม่ครั้งที่ 4 (attempts > 3) หรือ timer ครบแล้ว update/ ยังอยู่ = ถอยกลับไป previous
#
# ความปลอดภัย: SelfDir เป็นของ user edgeconnector (manager เขียนเองตอนอัปเดต) จึงอาจมี symlink ที่ถูกวางไว้
# → root ใช้แค่ systemctl / systemd-run · งานไฟล์ทั้งหมดใน SelfDir รันเป็น edgeconnector (runuser)
# และงานไฟล์ไม่ตาม symlink (อ่านเฉพาะไฟล์ธรรมดา · เขียนไฟล์ชั่วคราวใหม่แล้ว rename ทับ)
#
# exit 0 เสมอ (ยกเว้นคำสั่งภายใน rollback ที่บอกผลด้วย exit code) · unit ใช้ "-" นำหน้าอีกชั้น: guard พังต้องไม่ทำให้ manager เปิดไม่ได้
# test: GUARD_NO_TIMER=1 = ไม่เรียก systemd-run · GUARD_NO_SYSTEMCTL=1 = ไม่เรียก systemctl restart

SELF="${CC_SELF_DIR:-/opt/edgeconnector/manager}"
RUN_USER=edgeconnector
SERVICE=edgeconnector-manager
CHECK_UNIT=edgeconnector-manager-update-check
CHECK_AFTER=180 # วินาที · ต้องมากกว่า UpdateDeadline ของ manager (2 นาที) ให้ manager ตัดสินเองก่อน

log() { echo "manager-guard: $*" >&2; }

# ── งานไฟล์ใน SelfDir (รันเป็น user ของ manager) ────────────────

# บรรทัดแรกของไฟล์ธรรมดา ตัดช่องว่าง · ไม่มีไฟล์ / เป็น symlink = ว่าง
read_line() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 0
	head -n 1 "$1" 2>/dev/null | tr -d '[:space:]' | cut -c 1-100
}

# write_file PATH TEXT = เขียน .<ชื่อ>.tmp ใหม่ (ลบของเดิมก่อน · set -C = ไม่เขียนทับ/ไม่ตาม symlink) แล้ว rename ทับ
write_file() {
	tmp="$(dirname "$1")/.$(basename "$1").tmp"
	rm -f "$tmp" || return 1
	(set -C && printf '%s\n' "$2" >"$tmp") || return 1
	if [ -L "$1" ]; then rm -f "$1"; fi # mv ไปที่ symlink ของโฟลเดอร์ = ย้ายเข้าไปในโฟลเดอร์นั้น
	mv -f "$tmp" "$1"
}

# version ที่ใช้เป็นชื่อโฟลเดอร์ได้ (เหมือน release.ValidVersion: ยาวไม่เกิน 64 · ไม่มี "/" · ขึ้นต้นด้วย "." ไม่ได้)
valid_version() {
	case "$1" in
	'' | [!0-9A-Za-z]* | *[!0-9A-Za-z.+_-]*) return 1 ;;
	esac
	[ ${#1} -le 64 ]
}

# สลับ current → versions/$1 แบบ atomic: symlink ชั่วคราวแล้ว mv -T ทับ (GNU)
# mv ที่ไม่มี -T (BSD/macOS ตอนทดสอบ) ใช้ ln -sfn แทน (ไม่ atomic แต่เครื่องลูกค้าเป็น Linux)
switch_current() {
	if mv --help 2>&1 | grep -q -e '-T'; then
		rm -f "$SELF/.current.tmp"
		ln -s "versions/$1" "$SELF/.current.tmp" && mv -T "$SELF/.current.tmp" "$SELF/current"
	else
		ln -sfn "versions/$1" "$SELF/current"
	fi
}

has_update() { [ -d "$SELF/update" ] && [ ! -L "$SELF/update" ]; }

# do_rollback "<สาเหตุ>" = ถอย current กลับ previous + เขียน update-failed + ลบ update/ · คืน 1 = ไม่มี update/ ให้ถอย
# ยึด update/ ด้วยการ rename ก่อน (atomic): manager ที่ยืนยันสำเร็จพร้อมกันพอดีจะไม่ถูกถอยครึ่ง ๆ
do_rollback() {
	claimed="$SELF/.update.guard"
	rm -rf "$claimed"
	has_update || return 1
	mv "$SELF/update" "$claimed" 2>/dev/null || return 1
	prev=$(read_line "$claimed/previous")
	next=$(read_line "$claimed/next")
	valid_version "$next" || next="(unknown version)"
	msg="manager $next $1"
	if ! valid_version "$prev" || [ ! -f "$SELF/versions/$prev/bin/manager" ]; then
		valid_version "$prev" || prev=
		msg="$msg; could not roll back: previous version \"$prev\" is not installed"
	elif switch_current "$prev"; then
		msg="$msg; rolled back to $prev"
	else
		msg="$msg; could not roll back to $prev: switching current failed"
	fi
	log "$msg"
	write_file "$SELF/update-failed" "$msg" || log "could not write $SELF/update-failed"
	rm -rf "$claimed"
	return 0
}

# do_count = นับครั้งที่เปิด manager ตัวใหม่ · พิมพ์จำนวนครั้ง (ถอยกลับแล้ว = ไม่พิมพ์)
do_count() {
	has_update || return 0
	attempts=$(read_line "$SELF/update/attempts")
	case "$attempts" in
	'' | *[!0-9]*) attempts=0 ;;
	????*) attempts=3 ;; # เลขยาวผิดปกติ = ถือว่าครบแล้ว
	esac
	attempts=$((attempts + 1))
	if [ "$attempts" -gt 3 ]; then
		do_rollback "failed to start 3 times" || true
		return 0
	fi
	write_file "$SELF/update/attempts" "$attempts" || log "could not write $SELF/update/attempts"
	echo "$attempts"
}

# file_work count | rollback "<สาเหตุ>" · root = สลับเป็น user ของ manager ก่อนเสมอ (ไม่แตะ path ของ manager ด้วยสิทธิ์ root)
file_work() {
	if [ "$(id -u)" = 0 ]; then
		runuser -u "$RUN_USER" -- env CC_SELF_DIR="$SELF" "$0" "$@"
		return
	fi
	case "$1" in
	count) do_count ;;
	rollback) do_rollback "${2:-was rolled back}" ;;
	esac
}

# ── root: systemd ─────────────────────────────────────────────

# ExecStartPre: นับครั้ง · ครั้งแรกตั้ง timer ไว้ถอยกลับเผื่อ manager ตัวใหม่ค้าง (ไม่ crash ไม่ exit)
on_start() {
	n=$(file_work count) || log "could not count the start attempts"
	if [ "$n" = 1 ] && [ -z "${GUARD_NO_TIMER:-}" ]; then
		systemctl stop "$CHECK_UNIT.timer" 2>/dev/null || true # timer ค้างจากการอัปเดตครั้งก่อน
		systemd-run --on-active="$CHECK_AFTER" --unit="$CHECK_UNIT" --collect \
			--setenv=CC_SELF_DIR="$SELF" "$0" check >/dev/null 2>&1 ||
			log "could not start the update check timer"
	fi
}

# timer: ครบเวลาแล้ว update/ ยังอยู่ = manager ตัวใหม่ไม่ยืนยัน → ถอยกลับแล้วเปิด manager ใหม่
on_check() {
	if file_work rollback "did not reach the center within $CHECK_AFTER seconds" && [ -z "${GUARD_NO_SYSTEMCTL:-}" ]; then
		systemctl --no-block restart "$SERVICE" || log "could not restart $SERVICE"
	fi
}

case "${1:-}" in
'') if [ -d "$SELF/update" ]; then on_start; fi ;;
check) if [ -d "$SELF/update" ]; then on_check; fi ;;
count) file_work count ;;
rollback)
	file_work rollback "${2:-was rolled back}"
	exit
	;;
*) log "unknown argument: $1 (want no argument or check)" ;;
esac
exit 0
MANAGER_GUARD_EOF
}

# เนื้อหาของ /usr/local/bin/edgeconnector (make manager-release แทนบรรทัด marker ด้วย scripts/edgeconnector)
write_cli() {
	cat >"$1" <<'EDGECONNECTOR_CLI_EOF'
#!/bin/sh
# edgeconnector = คำสั่งหน้างานบนเครื่องลูกค้า (sudo edgeconnector manager status | manager doctor | plugin ls | plugin install ... · ดู help)
# install-manager.sh เขียนไฟล์นี้ไปที่ /usr/local/bin/edgeconnector (root 0755 · manager แก้ไม่ได้)
#
# ตัวคำสั่งจริงอยู่ใน binary ของ manager แต่ห้ามรัน binary นั้นเป็น root:
#   /opt/edgeconnector/manager เป็นของ user edgeconnector (manager อัปเดตตัวเองได้) → plugin ที่ถูกเจาะวาง binary ไว้
#   แล้วรอให้ root รัน = ยกระดับเป็น root ได้ · wrapper นี้จึงต้องรันด้วย root (อ่าน manager.env ที่ root อ่านได้คนเดียว)
#   แล้วลดสิทธิ์เป็น edgeconnector ก่อน exec เสมอ (user เดียวกับ manager = อ่าน data dir และ control socket ได้)
#
# setsid -w: รัน binary ใน session ใหม่ที่ไม่มี controlling terminal · ไม่งั้น binary ที่ถูกแทน (จาก root shell เช่น sudo -i)
#   ใช้ ioctl TIOCSTI ยัดคำสั่งเข้า shell ของ root ได้ · -w = รอแล้วคืน exit code เดิม · stdout ยังเป็น terminal (สียังทำงาน)
#   ผลข้างเคียง: Ctrl-C ไม่ถึง CLI · คำสั่งอ่านจบเองภายใน 20 วินาที · คำสั่งที่เปลี่ยนเครื่อง (install รอได้ถึง 10 นาที)
#   ทำต่อบน manager จนจบอยู่แล้วแม้ปิด terminal ไป ดูผลทีหลังด้วย plugin ls
#
# -cli นำหน้าทุกครั้ง: manager รุ่นที่ยังไม่มี CLI (เช่นหลัง manager-guard ถอยกลับ) ไม่รู้จัก flag นี้จึง exit ทันที
# ถ้าส่ง "plugin ls" ไปตรง ๆ รุ่นเก่าจะมองเป็น argument เกินแล้ว "รัน manager ตัวที่สอง" (เปิด plugin ซ้ำ + แย่ง stream ของตัวจริง)
#
# path ตายตัว ไม่รับจาก env: ถ้าเครื่องตั้ง sudo ให้เก็บ env ไว้ ผู้เรียกจะเลือกไฟล์ให้ root อ่าน / binary ให้รันได้
# test ใช้สำเนาของไฟล์นี้ที่แทนสองบรรทัดนี้ด้วย path ใน temp dir

ENV_FILE=/etc/edgeconnector/manager.env
BIN=/opt/edgeconnector/manager/current/bin/manager

if [ "$(id -u)" != 0 ]; then
	echo "edgeconnector: run with sudo: sudo edgeconnector $*" >&2
	exit 1
fi

# ค่าเดียวกับที่ systemd ให้ manager (CC_DATA, CC_ADDR, ...) · บรรทัดละ KEY=VALUE (install-manager.sh เขียนแบบนั้นเสมอ)
if [ -f "$ENV_FILE" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in [A-Za-z_]*=*) export "$line" ;; esac
	done <"$ENV_FILE"
fi

exec runuser -u edgeconnector -- setsid -w "$BIN" -cli "$@"
EDGECONNECTOR_CLI_EOF
}

# ExecStartPre=-+ : "+" = guard รันด้วย root (ใช้ systemctl ได้ · งานไฟล์ส่งต่อให้ user ของ manager) · "-" = guard พังก็ยังเปิด manager
write_unit() {
	cat >"$1" <<EOF
[Unit]
Description=edgeconnector manager
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
User=$RUN_USER
EnvironmentFile=$ENV_FILE
ExecStartPre=-+$GUARD
ExecStart=$SELF/current/bin/manager
Restart=always
RestartSec=2
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

# รอให้ service active ต่อเนื่อง 5 วินาทีภายใน 15 วินาที (ตัวที่ crash วนจะ active สลับ activating)
wait_active() {
	ok=0
	i=0
	while [ $i -lt 15 ]; do
		sleep 1
		i=$((i + 1))
		if systemctl is-active --quiet "$SERVICE"; then
			ok=$((ok + 1))
			[ $ok -ge 5 ] && return 0
		else
			ok=0
		fi
	done
	return 1
}

# ── ถอนการติดตั้ง ────────────────────────────────────────────

# act CMD... = รันคำสั่ง · dry run = พิมพ์ว่าจะรันอะไรแทน (test ตรวจลำดับคำสั่งจากตรงนี้)
act() {
	if [ -n "$DRY_RUN" ]; then
		log "would run: $*"
	else
		"$@"
	fi
}

# connector id ของ manager (ไว้บอกให้ไป revoke ที่ center) · อ่านเป็น user ของ manager เพราะ DATA เป็นของ user นั้น
manager_id() {
	runuser -u "$RUN_USER" -- cat "$DATA/manager/identity.json" 2>/dev/null |
		sed -n 's/.*"connector_id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr -cd 'A-Za-z0-9._-'
}

# uninstall = ลบทุกอย่างที่ script นี้และ manager สร้างไว้บนเครื่อง (ลูกค้าเลิกใช้ / ไม่ต่อสัญญา) · ไม่เก็บอะไรไว้
#   หยุด service (KillMode=control-group = plugin ทุกตัวที่ manager เปิดไว้หยุดไปด้วย) + timer ของการอัปเดตที่ค้าง →
#   ฆ่า process ของ user edgeconnector ที่ยังเหลือ → ลบ unit → ลบ 4 โฟลเดอร์ (โปรแกรม, ตัวตน, plugin + data, config, guard) →
#   ลบ user/group edgeconnector
# ฆ่า process ก่อนลบเสมอ: หลังจากนั้นไม่มีใครเปลี่ยนของในโฟลเดอร์ของ manager ได้ระหว่างที่ root ลบ (กันการสลับเป็น symlink)
# ฝั่ง center ไม่ถูกแตะ: connector ของ manager และ plugin ยังอยู่จนกว่าจะ revoke ที่ center
uninstall() {
	cd /
	mid=
	if [ -z "$DRY_RUN" ]; then
		[ "$(id -u)" = 0 ] || die "run as root: curl ... | sudo sh -s -- --uninstall"
		for cmd in systemctl runuser; do
			command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found (Linux with systemd and util-linux is required)"
		done
		for dir in /opt/edgeconnector /var/lib/edgeconnector "$ETC" /usr/local/lib/edgeconnector; do
			check_root_dir "$dir"
		done
		if id -u "$RUN_USER" >/dev/null 2>&1; then mid=$(manager_id || true); fi
	fi

	act systemctl stop "$CHECK_UNIT.timer" "$CHECK_UNIT.service" 2>/dev/null || true
	act systemctl disable --now "$SERVICE" 2>/dev/null || true
	act pkill -KILL -u "$RUN_USER" 2>/dev/null || true
	act rm -f "$UNIT_FILE"
	act rm -f "$CLI"
	act systemctl daemon-reload || true
	act systemctl reset-failed "$SERVICE" 2>/dev/null || true
	act rm -rf /opt/edgeconnector /var/lib/edgeconnector "$ETC" /usr/local/lib/edgeconnector
	if [ -n "$DRY_RUN" ] || id -u "$RUN_USER" >/dev/null 2>&1; then
		act userdel "$RUN_USER" || warn "could not remove user $RUN_USER"
	fi
	act groupdel "$RUN_USER" 2>/dev/null || true # useradd --user-group: ปกติ userdel ลบ group ให้แล้ว

	log "edgeconnector manager, its plugins and all their data were removed from this machine"
	if [ -n "$mid" ]; then
		log "revoke manager $mid (and its plugins) in the center"
	else
		log "revoke this machine's manager (and its plugins) in the center"
	fi
}

# ── option ───────────────────────────────────────────────────

DRY_RUN=${INSTALL_MANAGER_DRY_RUN:-}
if [ "${1:-}" = --uninstall ]; then
	[ $# -eq 1 ] || die "--uninstall takes no other options"
	uninstall
	exit 0
fi

TOKEN=${CC_TOKEN:-}
SERVER=
VERSION=
CHANNEL=stable
BASE_ARG=
KEYS_ARG=
CA_FILE=
REENROLL=
while [ $# -gt 0 ]; do
	case "$1" in
	--reenroll)
		REENROLL=1
		shift
		continue
		;;
	--token | --server | --version | --channel | --base-url | --trusted-key | --ca-cert-file)
		[ $# -ge 2 ] || die "$1 needs a value"
		;;
	--uninstall) die "--uninstall takes no other options" ;;
	*) die "unknown option: $1" ;;
	esac
	case "$1" in
	--token) TOKEN=$2 ;;
	--server) SERVER=$2 ;;
	--version) VERSION=$2 ;;
	--channel) CHANNEL=$2 ;;
	--base-url) BASE_ARG=$2 ;;
	--trusted-key) KEYS_ARG="${KEYS_ARG:+$KEYS_ARG,}$2" ;;
	--ca-cert-file) CA_FILE=$2 ;;
	esac
	shift 2
done

# placeholder ที่ไม่ถูกแทนตอน publish = ว่าง
case "$RELEASE_URL" in __*__) RELEASE_URL= ;; esac
case "$TRUSTED_KEYS" in __*__) TRUSTED_KEYS= ;; esac

BASE=${BASE_ARG:-$RELEASE_URL}
while [ "${BASE%/}" != "$BASE" ]; do BASE=${BASE%/}; done
KEYS=$(printf '%s' "${KEYS_ARG:-$TRUSTED_KEYS}" | tr -d '[:space:]') # Go ยอมให้มีช่องว่างคั่น

[ -n "$BASE" ] || die "no release URL: pass --base-url https://<registry>"
plain "$BASE" || die "release URL has spaces or quotes: $BASE"
case "$BASE" in *@*) die "release URL must not contain user info (@): $BASE" ;; esac
case "$BASE" in
https://*) CURL_PROTO="--proto =https --proto-redir =https" ;;
http://127.0.0.1 | http://127.0.0.1[:/]* | http://localhost | http://localhost[:/]* | http://\[::1\] | http://\[::1\][:/]*)
	CURL_PROTO="--proto =http,https --proto-redir =http,https" # ทดสอบในเครื่องเท่านั้น
	;;
*) die "release URL must start with https:// (got $BASE)" ;;
esac
[ -n "$KEYS" ] || die "no trusted keys: pass --trusted-key <id>=<base64>"
plain "$KEYS" || die "trusted keys have quotes or other unexpected characters"
check_keys
[ -z "$VERSION" ] || valid_version "$VERSION" || die "invalid version: $VERSION"
valid_channel "$CHANNEL" || die "invalid channel: $CHANNEL"
[ -z "$SERVER" ] || plain "$SERVER" || die "invalid --server: $SERVER"
[ -z "$REENROLL" ] || [ -n "$TOKEN" ] || die "--reenroll needs --token"

if [ -n "${INSTALL_MANAGER_PLATFORM:-}" ]; then
	PLATFORM=$INSTALL_MANAGER_PLATFORM
else
	[ "$(uname -s)" = Linux ] || die "only Linux is supported"
	case "$(uname -m)" in
	x86_64 | amd64) PLATFORM=linux_amd64 ;;
	aarch64 | arm64) PLATFORM=linux_arm64 ;;
	*) die "unsupported CPU: $(uname -m) (manager is built for amd64 and arm64)" ;;
	esac
fi
OS=${PLATFORM%%_*}
ARCH=${PLATFORM#*_}

# ── ตรวจเครื่อง (อ่านอย่างเดียว) ─────────────────────────────

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM

if [ -z "$DRY_RUN" ]; then
	[ "$(id -u)" = 0 ] || die "run as root: curl ... | sudo sh -s -- ..."
	for cmd in systemctl runuser; do
		command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found (Linux with systemd and util-linux is required)"
	done
	id -u "$RUN_USER" >/dev/null 2>&1 || command -v useradd >/dev/null 2>&1 || die "useradd not found"
	for dir in /opt/edgeconnector /var/lib/edgeconnector "$ETC" /usr/local/lib/edgeconnector; do
		check_root_dir "$dir"
	done
	check_manager_dir "$SELF"
	check_manager_dir "$DATA"
	if [ -n "$CA_FILE" ]; then
		[ -f "$CA_FILE" ] && [ -r "$CA_FILE" ] || die "cannot read --ca-cert-file $CA_FILE"
		# ทำเป็น path เต็มก่อน เพราะข้างล่างจะ cd / (path แบบ ./ca.pem จะหาไม่เจอหลังจากนั้น)
		case "$CA_FILE" in
		/*) ;;
		*) CA_FILE=$(cd "$(dirname "$CA_FILE")" && pwd -P)/$(basename "$CA_FILE") ;;
		esac
	fi
	[ -f "$ENV_FILE" ] || [ -n "$SERVER" ] || die "first install needs --server HOST:PORT"
	# ไม่มี token แต่ยังไม่ enroll / ถูก revoke = manager ใช้งานไม่ได้
	if [ -z "$TOKEN" ]; then
		[ -f "$DATA/manager/identity.json" ] || die "this machine is not enrolled: pass --token <manager enrollment token>"
		[ ! -f "$DATA/manager/revoked.json" ] || die "this manager was revoked: pass --token <new manager enrollment token>"
	fi
	write_guard "$TMP/manager-guard"
	write_cli "$TMP/edgeconnector"
	[ "$(head -n 1 "$TMP/manager-guard")" = "#!/bin/sh" ] && [ "$(head -n 1 "$TMP/edgeconnector")" = "#!/bin/sh" ] ||
		die "this install-manager.sh is not the published one (missing embedded manager-guard / edgeconnector): use the one in the registry (make manager-release)"
fi
find_openssl

# ── โหลดและตรวจ ──────────────────────────────────────────────

if [ -z "$VERSION" ]; then
	url="$BASE/manager/channels/$CHANNEL.json"
	fetch "$url" "$TMP/channel.json" "$MAX_MANIFEST" || die "cannot download channel $CHANNEL: $url"
	VERSION=$(json_field version "$TMP/channel.json")
	valid_version "$VERSION" || die "channel $CHANNEL has no valid version: $url"
fi

dir="$BASE/manager/$VERSION/$PLATFORM"
fetch "$dir/manifest.json" "$TMP/manifest.json" "$MAX_MANIFEST" ||
	die "manager $VERSION has no build for $PLATFORM (cannot download $dir/manifest.json)"
m_name=$(json_field name "$TMP/manifest.json")
m_version=$(json_field version "$TMP/manifest.json")
m_os=$(json_field os "$TMP/manifest.json")
m_arch=$(json_field arch "$TMP/manifest.json")
m_sha=$(json_field sha256 "$TMP/manifest.json")
m_sig=$(json_field signature "$TMP/manifest.json")
m_key=$(json_field keyId "$TMP/manifest.json")
m_size=$(json_field size "$TMP/manifest.json")
[ "$m_name $m_version $m_os $m_arch" = "manager $VERSION $OS $ARCH" ] ||
	die "manifest is for \"$(shown "$m_name $m_version $m_os/$m_arch")\", want \"manager $VERSION $OS/$ARCH\""

archive="manager_${VERSION}_${OS}_${ARCH}.tar.gz"
fetch "$dir/$archive" "$TMP/manager.tar.gz" "$MAX_ARCHIVE" || die "cannot download $dir/$archive"
size=$(file_size "$TMP/manager.tar.gz")
[ -z "$m_size" ] || [ "$size" = "$m_size" ] ||
	die "size mismatch: $archive is $size bytes, manifest says $(shown "$m_size")"
sum=$(sha256 "$TMP/manager.tar.gz")
[ -n "$m_sha" ] && [ "$sum" = "$m_sha" ] || die "sha256 mismatch: $archive is $sum, manifest says $(shown "$m_sha")"

key=$(trusted_key "$m_key") || die "signature: key \"$(shown "$m_key")\" of manager $VERSION is not in the trusted keys"
verify_signature "$key" "cc-artifact:manager:$VERSION:$OS:$ARCH:$sum" "$m_sig" ||
	die "bad signature on manager $VERSION $PLATFORM (key $m_key)"
listing=$(tar -tzf "$TMP/manager.tar.gz") || die "cannot read $archive"
[ "$listing" = "bin/
bin/manager" ] || die "$archive must contain only bin/manager"
log "verified manager $VERSION $PLATFORM"

# สำเนาของ script นี้ไว้ถอนแบบ offline: curl | sh อ่านจาก stdin จึงคัดลอกตัวเองไม่ได้ → โหลดจากที่เดียวกับที่ลูกค้า curl
# ไม่ได้ / ไม่ใช่ sh script = แค่เตือน (ติดตั้งต่อได้ · ถอนยังใช้ curl ได้)
if fetch "$BASE/install-manager.sh" "$TMP/install-manager.sh" "$MAX_SCRIPT" 2>/dev/null &&
	[ "$(head -n 1 "$TMP/install-manager.sh")" = "#!/bin/sh" ] && sh -n "$TMP/install-manager.sh" 2>/dev/null; then
	log "fetched install-manager.sh (kept for offline --uninstall)"
else
	rm -f "$TMP/install-manager.sh"
	warn "cannot download $BASE/install-manager.sh: offline --uninstall will not be available"
fi
if [ -n "$DRY_RUN" ]; then
	exit 0
fi

# ── ติดตั้ง (ตั้งแต่ตรงนี้แตะเครื่อง) ───────────────────────────

cd /
CHANGED= # มีอะไรเปลี่ยน = ต้อง restart

if ! id -u "$RUN_USER" >/dev/null 2>&1; then
	log "creating user $RUN_USER"
	useradd --system --user-group --home-dir /var/lib/edgeconnector --no-create-home \
		--shell /usr/sbin/nologin "$RUN_USER"
fi
mkdir -p /opt/edgeconnector /var/lib/edgeconnector "$ETC" /usr/local/lib/edgeconnector
# SelfDir และ DATA เป็นของ edgeconnector · root chown เฉพาะตอนเพิ่งสร้าง (โฟลเดอร์แม่เป็นของ root จึงไม่มีใครสลับได้)
if [ ! -d "$SELF" ]; then
	mkdir -m 0755 "$SELF"
	chown -h "$RUN_USER:$RUN_USER" "$SELF"
fi
if [ ! -d "$DATA" ]; then
	mkdir -m 0700 "$DATA"
	chown -h "$RUN_USER:$RUN_USER" "$DATA"
fi
check_manager_dir "$SELF"
check_manager_dir "$DATA"

# version ที่ถอยกลับไปได้ถ้าตัวใหม่ไม่ขึ้น: มี update/ (manager.update ที่ยังไม่ยืนยัน) = update/previous (อ่านเป็น user ของ manager)
# ไม่งั้น = ที่ current ชี้ (readlink อ่านแค่ตัว link ไม่ตามไป)
installed() { valid_version "$1" && [ -f "$SELF/versions/$1/bin/manager" ]; }
PREVIOUS=$(self_op previous 2>/dev/null || true)
if ! installed "$PREVIOUS"; then
	PREVIOUS=$(readlink "$SELF/current" 2>/dev/null || true)
	PREVIOUS=${PREVIOUS##*/}
	installed "$PREVIOUS" || PREVIOUS=
fi

self_op unpack "$VERSION" <"$TMP/manager.tar.gz" || die "cannot unpack manager $VERSION into $SELF/versions"

# manager.env: ไม่มี = สร้าง · มี = แทนเฉพาะบรรทัดของ option ที่ส่งมา · เก็บของเดิมไว้คืนถ้าตัวใหม่ไม่ขึ้น
if [ -f "$ENV_FILE" ]; then cp -p "$ENV_FILE" "$TMP/manager.env.bak"; fi
if [ -f "$CA_DEST" ]; then cp -p "$CA_DEST" "$TMP/ca.pem.bak"; fi
if [ -n "$CA_FILE" ]; then
	cp "$CA_FILE" "$TMP/ca.pem"
	install_file "$TMP/ca.pem" "$CA_DEST" 0644 && CHANGED=1
fi
if [ -f "$ENV_FILE" ]; then
	cp "$ENV_FILE" "$TMP/manager.env"
	[ -z "$SERVER" ] || set_env CC_ADDR "$SERVER"
	[ -z "$BASE_ARG" ] || set_env CC_RELEASE_URL "$BASE"
	[ -z "$KEYS_ARG" ] || set_env CC_TRUSTED_KEYS "$KEYS"
	[ -z "$CA_FILE" ] || set_env CC_CA "$CA_DEST"
	grep -q '^CC_SELF_DIR=' "$TMP/manager.env" || set_env CC_SELF_DIR "$SELF"
else
	{
		echo "CC_ADDR=$SERVER"
		echo "CC_DATA=$DATA"
		echo "CC_RELEASE_URL=$BASE"
		echo "CC_TRUSTED_KEYS=$KEYS"
		echo "CC_SELF_DIR=$SELF"
		[ -z "$CA_FILE" ] || echo "CC_CA=$CA_DEST"
	} >"$TMP/manager.env"
fi
install_file "$TMP/manager.env" "$ENV_FILE" 0600 && CHANGED=1 && log "wrote $ENV_FILE"

# enroll: ยังไม่ enroll หรือถูก revoke หรือสั่ง --reenroll
if [ -n "$TOKEN" ]; then
	if [ -n "$REENROLL" ]; then
		enroll -reenroll
		CHANGED=1
	elif [ ! -f "$DATA/manager/identity.json" ] || [ -f "$DATA/manager/revoked.json" ]; then
		enroll
		CHANGED=1
	else
		warn "this machine is already enrolled: --token is ignored (add --reenroll to enroll it again)"
	fi
fi

write_guard "$TMP/manager-guard"
install_file "$TMP/manager-guard" "$GUARD" 0755 && CHANGED=1
# ไม่เกี่ยวกับ service ที่รันอยู่ จึงไม่ตั้ง CHANGED
mkdir -p "$(dirname "$CLI")"
install_file "$TMP/edgeconnector" "$CLI" 0755 || true
if [ -f "$TMP/install-manager.sh" ]; then install_file "$TMP/install-manager.sh" "$SCRIPT_COPY" 0755 || true; fi
write_unit "$TMP/unit"
if install_file "$TMP/unit" "$UNIT_FILE" 0644; then
	CHANGED=1
	systemctl daemon-reload
fi
systemctl enable --quiet "$SERVICE"

if [ "$PREVIOUS" != "$VERSION" ]; then
	# ติดตั้งด้วยมือทับการอัปเดตที่ค้างอยู่: หยุด timer ของมัน (switch ลบ update/ ให้)
	systemctl stop "$CHECK_UNIT.timer" 2>/dev/null || true
	self_op switch "$VERSION" || die "cannot switch $SELF/current to $VERSION"
	CHANGED=1
	log "current -> versions/$VERSION"
fi
systemctl is-active --quiet "$SERVICE" || CHANGED=1

if [ -z "$CHANGED" ]; then
	log "manager $VERSION is already installed and running: nothing changed"
	exit 0
fi
systemctl restart "$SERVICE" || true
if wait_active; then
	log "manager $VERSION is running · check it with: sudo edgeconnector manager doctor"
	exit 0
fi
if [ -n "$PREVIOUS" ]; then
	warn "manager $VERSION did not start: going back to $PREVIOUS and the previous settings"
	restore_config
	[ "$PREVIOUS" = "$VERSION" ] || self_op switch "$PREVIOUS" || warn "could not switch $SELF/current back"
	systemctl restart "$SERVICE" || true
fi
die "manager $VERSION did not start: see journalctl -u $SERVICE"
