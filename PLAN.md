# PLAN: release สำหรับทดสอบ registry

เป้าหมาย: เลือกว่า "ควรปล่อย release อะไรลง registry นี้" เพื่อทดสอบทุกกรณีของ manager / UI / `cc-release` กับ registry จริง (GitHub raw)
เขียนจากการอ่านโค้ดใน repo edgeconnector: `release/`, `cmd/cc-release`, `connectormanager/plugins.go`, `connectormanager/selfupdate.go`, `internal/supervisor`, `worker`, `examples/hello-plugin`, `connectorserver/ui/pages.go`
(ตั้งแต่ 2026-11-25 manager แยกไปอยู่ repo `edgeconnector-manager` · release ของ manager ตั้งแต่ 1.3.0 build จาก repo นั้น)

> สถานะ (2026-11-25): **release ทั้งหมดของ branch `main` และ branch `negative`, `negative-bigindex` สร้างและ push แล้ว** · ยังไม่ได้ทดสอบกับ manager จริง (ตารางข้อ 7 ว่าง)
> - `main`: 41 release ผ่าน `verify` (รวม demo 1.0.0 = `stable` ของ demo) (ใช้ `lab-2026` กับ `lab-2027`) · manager **1.5.0** เป็น `stable` (เดิม 1.0.0 → 1.3.0 → 1.3.1 → 1.5.0) · manager 1.4.0 (auto update) ไม่เคยเป็น stable ข้ามไป 1.5.0 (+ stop/start, `--set`) · มี `install-manager.sh` (เขียนจาก repo edgeconnector-manager ตั้งแต่ 1.3.0) · ไฟล์ที่โหลดจาก raw มี sha256 ตรง manifest
> - `negative`: 10 ตัวที่เสียตามข้อ 3 · ลอง `Fetch` + `Extract` จริงแล้ว ได้ error ตามที่ตั้งใจทุกตัว · `verify` ล้ม (ตั้งใจ)
> - `negative-bigindex`: `index.json` 1.2 MB (เกินขีด 1 MB)
> - ข้อสังเกตจากการลอง: `t-nobin` ผ่านทั้ง `Fetch` และ `Extract` (แตกได้) แต่ไม่มี `bin/t-nobin` → manager ไม่รายงานว่า "ไม่มีไฟล์" ตรง ๆ จะเห็นเป็น plugin ไม่ healthy (ดู log จาก supervisor) ต่างจาก `manager.update` ที่ตรวจ `has no bin/manager` ให้
>
> **ตัดสินใจแล้ว (2026-11-24):** ทดสอบบน Linux อย่างเดียว (ไม่ทำ darwin) · มี branch `negative` · ทำกรณี version (`t-ver`) ·
> ไม่มี CRM จริง ใช้ `examples/center` (CRM จำลอง) วางบน Ubuntu VPS เครื่องเดียวกับ manager (ข้อ 4.1)
> **VPS:** `x86_64` → `linux_amd64` (ไม่ต้องทำ arm64 ยกเว้น `t-otherarch` กับ manager ที่ `manager-release` สร้างทั้งสอง arch ให้เอง)
> **โค้ดที่ต้อง merge ก่อน build release** (build จาก commit ที่สะอาดบน main เท่านั้น):
> PR #10 `feat(ui)` เรียง version แบบ semver · PR #11 `feat(hello-plugin)` เพิ่ม `startDelay` / `crashAfter` (ทำให้ `t-slow` / `t-crash` ทำได้)

---

## 0. ข้อจำกัดที่ต้องรู้ก่อนวางแผน

| ข้อจำกัด | ผลต่อแผน |
|---|---|
| release แก้ทับไม่ได้ (`Publish` ปฏิเสธถ้ามีโฟลเดอร์อยู่แล้ว) และ repo เป็น git | version ที่ push แล้วถือว่า "ใช้ไปแล้ว" · ลบจาก git history ได้ยาก → **ลองใน registry ในเครื่องก่อน push เฉพาะตัวที่ผ่านแล้ว** |
| archive ของ hello-plugin ~5 MB ต่อ platform (manager ~5 MB) | 2 platform (linux amd64 + arm64) ≈ 10 MB ต่อ 1 version · ปล่อย 10 version = 100 MB ใน git ถาวร → hello 1.0.0 ปล่อย linux ทั้งสอง arch ส่วน version อื่นของ hello ปล่อยเฉพาะ arch ของ VPS · fixture ที่เป็น shell script ไม่กี่ byte จึงปล่อยทั้งสอง arch ได้ · build ด้วย `make … PLATFORMS="linux/amd64 linux/arm64"` (ค่าจาก command line ทับ `PLATFORMS` ใน Makefile ได้) |
| `cc-release verify` ล้มถ้ามี release ที่ลายเซ็น/sha ผิด | release ที่ตั้งใจให้เสีย **ห้ามอยู่ใน branch `main`** (ไม่งั้น verify ก่อน push ไม่ผ่านตลอดไป) → ใช้ branch แยก (ข้อ 3) |
| cache ของ raw.githubusercontent ~5 นาที (index.json, channels/*.json) | หลัง push รอก่อนทดสอบ หรือทดสอบใน registry ในเครื่องที่ไม่มี cache |
| `CC_RELEASE_URL` ใส่ branch ใน path (`.../edgeconnector-registry/<branch>`) | เปลี่ยน branch = เปลี่ยน registry โดยไม่ต้องแก้โค้ด · ใช้ได้กับ branch ทดสอบ |
| `cc-release package` สร้าง tar เองเสมอ (ปลอดภัยเสมอ) | archive อันตราย (symlink, `../`) ต้องสร้างด้วย Go โปรแกรมทิ้ง ไม่ใช่ `cc-release` |
| unit test ฝั่ง release/manager ครอบคลุมกรณีเสียเกือบหมดแล้ว (`fetch_test.go`, `publish_test.go`, `selfupdate_test.go`, `manager_test.go`) | registry จริงใช้พิสูจน์ **ทางจริงที่ unit test จำลองไม่ได้**: HTTPS, GitHub raw, URL ที่มี `+`, cache, systemd + manager-guard, ข้าม platform จริง |

---

## 1. Key ที่ต้องมี

| key | ใช้ทำอะไร | เก็บ |
|---|---|---|
| `lab-2026` | key หลัก เซ็นทุกอย่างที่ควรติดตั้งได้ | `~/cc-keys/lab-2026.key` (ยังไม่ได้สร้าง) |
| `lab-2027` | key ที่สอง ทดสอบการหมุน key (ข้อ T-KEY) · manager ที่เชื่อแค่ `lab-2026` ต้องปฏิเสธของที่เซ็นด้วยตัวนี้ | `~/cc-keys/lab-2027.key` |

สร้าง (รันจากรากโปรเจกต์ edgeconnector · ไม่ทับไฟล์ที่มีอยู่ · `.key` เป็นความลับ ห้ามอยู่ใน repo ใด ๆ):

```bash
go run ./cmd/cc-release keygen -dir ~/cc-keys -id lab-2026
go run ./cmd/cc-release keygen -dir ~/cc-keys -id lab-2027
```

แต่ละคำสั่งพิมพ์บรรทัด `lab-2026=<base64>` (ค่า public ที่ใช้เป็น `CC_TRUSTED_KEYS` และ `verify -pubkey` เปิดเผยได้)

`verify` ต้องใส่ทั้งสอง: `-pubkey lab-2026=<b64>,lab-2027=<b64>` ไม่งั้นตัวที่เซ็นด้วย lab-2027 จะถูกรายงานว่าเสีย
ไม่ใช้ `release-2026` (เป็น key ของ ORIG ที่จะเลิกใช้)

---

## 2. รายการ release ที่ควรทำ (branch `main` · ทุกตัว verify ผ่าน)

ชื่อ plugin ที่เป็น fixture ใช้ขึ้นต้น `t-` เพื่อแยกจาก `hello` ที่เป็นตัวอย่างจริงในหน้า UI

### 2.1 `hello` — ตัวอย่างจริง (build ด้วย `make plugin-release PLATFORMS="linux/amd64 linux/arm64"` สำหรับ 1.0.0 · ตัวอื่นเฉพาะ arch ของ VPS)

| version | เนื้อหา | channel | กรณีที่ทดสอบ |
|---|---|---|---|
| `1.0.0` | hello-plugin ปกติ (`-X main.version=1.0.0`) · **linux amd64 + arm64** | `stable` | ติดตั้งครั้งแรก healthy · Request `version`/`config` · identity ถูกสร้าง (`plg_<hash>`, scopes ⊆ manager) |
| `1.1.0` | ปกติ อีก version | `beta` | อัปเกรด 1.0.0 → 1.1.0: `Previous=1.0.0` · identity เดิมถูกใช้ต่อ (ไม่ register ซ้ำ) · `plugin.rollback` กลับ 1.0.0 โดยไม่แตะ registry · ติดตั้ง version เดิมซ้ำตอน running = `Already` |
| `1.2.0` | **พัง**: build ด้วย `-X main.broken=true` (มีในโค้ดอยู่แล้ว) | – | อัปเกรดจาก 1.1.0 → ไม่ healthy → manager ถอยกลับ 1.1.0 เอง · error บอกว่า "rolled back to 1.1.0" · `Current` ยัง 1.1.0 |
| `1.3.0` | ปกติ แต่ **เซ็นด้วย `lab-2027`** | – | T-KEY: manager เชื่อ lab-2026 อย่างเดียว = ปฏิเสธ (`ErrUnknownKey`) · เชื่อทั้งสอง = ติดตั้งได้ (หมุน key) |

ข้อสังเกต: 1.2.0 ต้องลองสองแบบ คือ (ก) ติดตั้งทับ 1.1.0 → ถอยกลับ, (ข) ติดตั้งบนเครื่องที่ **ยังไม่เคยมี hello** → error และไม่ทิ้งโฟลเดอร์ `plugins/hello` ว่างค้าง (โค้ดมีลบให้ ควรเห็นกับตาจริง)

### 2.1b `demo` — plugin ตัวอย่างที่ใช้ข้อความครบ 5 ชนิด (ต้นฉบับ: `edgeconnector-plugin/plugins/demo`)

hello ใช้ทดสอบเคสที่ผิดพลาด (อัปเกรด, rollback, ตัวพัง, key) และหยุดออก version ใหม่ · ทดสอบเคสปกติแบบครบวงให้ใช้ demo · ใช้คู่กับ center ตัวอย่างของ edgeconnector-sandbox (มี Call `dnc.check`, รับ Event `job.done`, ส่ง Notify ได้)

| version | เนื้อหา | channel | กรณีที่ทดสอบ |
|---|---|---|---|
| `1.0.0` | demo จาก edgeconnector-plugin 962f451 · **linux amd64 + arm64** | `stable` | ติดตั้งพร้อม config + scope `dnc:read` · Request `version` / `greet` · Request `dnc.check` → Call ขึ้น center · Command `job.run` → Event `job.done` · job ซ้ำ = `already` · Notify `announce` เห็นใน `plugin.logs` · ถอด scope แล้ว `dnc.check` บอกว่าขาด `dnc:read` |

### 2.2 fixture แบบ shell script (ไม่ต้อง build Go · ไฟล์เล็กมาก · **ไม่ต้องแก้โค้ดใดเลย**)

`cc-release package -binary` รับไฟล์ regular อะไรก็ได้ จึงใส่ shell script เป็น "plugin" ได้ · ปล่อยทั้ง linux_amd64 และ linux_arm64 ได้เพราะไฟล์เล็ก

| ชื่อ | script | กรณีที่ทดสอบ |
|---|---|---|
| `t-hang` | `#!/bin/sh` → `sleep 3600` (ไม่เปิด health socket) | ติดตั้งแล้วไม่ healthy ภายใน `start_timeout_sec` → ล้ม + หยุด process · ใส่ `start_timeout_sec: 3` เพื่อไม่ต้องรอ 30 วิ · ดู log ใน `plugin.logs` |
| `t-exit` | `#!/bin/sh` → `echo boom >&2; exit 1` | ตายทันที · supervisor เปิดใหม่ซ้ำ (RestartDelay 1 วิ) · ติดตั้งต้องล้ม (ยังไม่ได้ยืนยันว่า `WaitHealthy` คืน error เร็วตอน process ตาย หรือรอจนหมด `start_timeout_sec` → จดผลจริงในข้อ 7) · `Restarts` เพิ่ม |
| `t-noterm` | `#!/bin/sh` → `trap '' TERM; while :; do sleep 1; done` | **ไม่ยอมตาย** ตอน SIGTERM → `Stop(10s)` ต้อง SIGKILL หลังครบเวลา · ใช้ลอง `plugin.remove` / stop ว่าไม่ค้าง (ตัวนี้ไม่ healthy จึงต้องมองจากฝั่ง remove/stop) |

หมายเหตุ: เป็น shell script จึงรันได้แค่ unix · ไม่เป็นปัญหาเพราะทดสอบบน Linux

### 2.3 hello-plugin ที่พังแบบมี health (เพิ่ม flag แล้วใน PR #11 · รอ merge)

shell script ทำ "healthy แล้วค่อยพังทีหลัง" ไม่ได้ (ต้องเปิด unix socket ตอบ `/health`) จึงเพิ่ม ldflags ใน `examples/hello-plugin/main.go` แบบเดียวกับ `broken` (ค่าเวลาเป็นรูปแบบ `time.ParseDuration`):

| ldflag | พฤติกรรม | ใช้ทำ fixture |
|---|---|---|
| `-X main.startDelay=8s` | `time.Sleep` ใน setup ก่อน connect → healthy ช้า | `t-slow`: ใส่ `start_timeout_sec: 3` = ล้ม + ถอยกลับ · ใส่ 20 = ผ่าน (พิสูจน์ว่า timeout ต่อ plugin ทำงานจริง ไม่ใช่ค่า default 30 วิ) |
| `-X main.crashAfter=5s` | healthy แล้ว `os.Exit(1)` หลัง 5 วิ | `t-crash`: ติดตั้งผ่าน แล้ว supervisor เปิดใหม่เป็นระยะ · `host.status` เห็น `Restarts` เพิ่ม · plugin ไม่ถูกถอยกลับ (ถอยกลับเฉพาะตอนติดตั้ง) |

build เป็น plugin ชื่อ `t-slow` / `t-crash` ด้วย `make plugin-release NAME=t-slow PLUGIN_PKG=./examples/hello-plugin …` (ชื่อ plugin ไม่ต้องตรงกับชื่อโฟลเดอร์ใน `examples/`) · `crashAfter` ต้องนานกว่าเวลาเริ่มจริง (แนะนำ 5s ขึ้นไป) ไม่งั้นตายก่อน healthy เหมือน `broken`

### 2.3b `t-auto` — ไว้ทดสอบอัปเดต plugin อัตโนมัติ (manager 1.4.0)

hello-plugin ธรรมดา 2 version บน **linux amd64 + arm64** (build จาก `fixtures/catalog.txt` ของ edgeconnector-plugin) · `stable` ชี้ 1.1.0 ถาวร จึงไม่ต้องย้าย `stable` ของ hello เพื่อทดสอบ

| version | channel | ทดสอบ |
|---|---|---|
| `1.0.0` | – | ติดตั้งด้วยมือเป็นจุดเริ่ม · เปิด `plugin.auto_update t-auto on` + ตารางของเครื่อง → รอบถัดไปต้องอัปเดตขึ้น 1.1.0 เอง |
| `1.1.0` | `stable` | เป้าหมายของรอบ · ติดตั้ง 1.1.0 อยู่แล้ว = รอบไม่ทำอะไร (ไม่มี Event) · ถอยด้วยมือเป็น 1.0.0 ขณะสวิตช์เปิด = `skip_version` 1.1.0 รอบถัดไปไม่ขึ้น |

### 2.4 ชื่อและ version ที่เป็นกรณีขอบ

| ปล่อยอะไร | กรณีที่ทดสอบ |
|---|---|
| `t-ver` เวอร์ชัน `2.0.0-rc.1+build.5` | `+` ใน URL path ผ่าน GitHub raw ได้จริงไหม · `ValidVersion` ยอม `+`, `.`, `-` · UI แสดงถูก · ติดตั้งผ่าน manager ได้ |
| `t-ver` เวอร์ชัน `1.9.0`, `1.10.0`, `1.10.0-rc.1` | UI เรียงแบบ semver (PR #10): `1.9.0` → `1.10.0-rc.1` → `1.10.0` · เปิดหน้า manager ใน UI เทียบกับลำดับนี้ |
| `t-ver` เวอร์ชัน `v1` | version ที่ไม่ใช่ semver ใช้ได้ (ตามที่ regex ยอม) |
| `a` (ชื่อ 1 ตัวอักษร) และชื่อยาว 63 ตัว (`t-` + `x` ให้ครบ 63) | ขอบของ `nameRe` (`{0,62}`) · ต่อ URL/สร้างโฟลเดอร์/socket path ได้ · **ระวัง**: socket `<run>/<name>.sock` ยาวเกิน ~104 ตัวบน macOS ได้ ถ้า `-run-dir` ยาว → ใช้ shell script ไฟล์เล็ก |

### 2.5 ครอบคลุม platform (Linux อย่างเดียว)

| ปล่อยอะไร | กรณีที่ทดสอบ |
|---|---|
| `t-otherarch` 1.0.0 (shell script) เฉพาะ arch ที่ **ไม่ใช่** ของ VPS (VPS amd64 → ปล่อย `linux_arm64`) | ติดตั้งบน VPS = `ErrNotPublished` ("not published: … for linux/amd64") ไม่ใช่ error แปลก ๆ · UI: `ForHost=false` แสดงต่างจาก release ที่ลงได้ |
| `hello` 1.0.0 linux amd64 + arm64 | ตรงข้าม: ลงได้ทั้งสอง arch |
| (ไม่ปล่อย) `t-nonexistent` | ติดตั้งชื่อ/version ที่ไม่มีเลย = 404 → `ErrNotPublished` · ไม่ต้องมีไฟล์ใน registry |

### 2.6 channel

| channel | ชี้ไป | ทดสอบ |
|---|---|---|
| `hello/channels/stable.json` | 1.0.0 | UI แสดงป้าย stable ที่ version นั้น |
| `t-auto/channels/stable.json` | 1.1.0 | เป้าหมายของรอบ auto update (ข้อ 2.3b) |
| `hello/channels/beta.json` | 1.1.0 | หลาย channel คนละ version · `promote` ใหม่ = ย้ายป้ายได้ (channel เป็นของที่แก้ได้ ต่างจาก release) |
| – | – | สั่งติดตั้ง version ชื่อ `stable` ผ่าน CRM = ต้องล้ม "not published" (manager/CRM **ไม่แปลง channel เป็น version** · `install-manager.sh` เท่านั้นที่อ่าน channel) |

### 2.7 `manager` — ตัวจริงของ manager (ต้อง Linux + systemd ถึงจะลองครบ)

ปล่อยด้วย `make manager-release` (ได้ `install-manager.sh` ที่ราก registry ด้วย) · มีแค่ `linux_amd64` + `linux_arm64` ตามที่ target กำหนด
1.0.0 – 1.2.1 build จาก repo edgeconnector (ก่อนแยก) · ตั้งแต่ 1.3.0 build จาก repo `edgeconnector-manager`

| version | เนื้อหา | ทดสอบ |
|---|---|---|
| `1.0.0` | manager จริง · เคยเป็น `stable` (ถึง 2026-11-25) | `curl … install-manager.sh \| sh -s -- --version 1.0.0` ติดตั้งครั้งแรกจริง (token, server, base-url) · manager-guard ถูกฝังใน script · systemd รัน `current/bin/manager` |
| `1.1.0` | manager จริง อีก version | `manager.update` 1.0.0 → 1.1.0: โหลด+ตรวจลายเซ็น → เขียน `update/` → สลับ `current` → ตัวใหม่ต่อ CRM ได้และ ack `host.status` → ลบ `update/` = สำเร็จ · `Already` ถ้าสั่ง version เดียวกันซ้ำ |
| `1.2.0-bad-exit` | **shell script** `#!/bin/sh` → `exit 1` ใส่เป็น `bin/manager` | ตัวใหม่ crash วน → manager-guard นับ `attempts` แล้วถอยกลับ `previous` · ได้ `update-failed` ใน `host.status` |
| `1.2.1-bad-hang` | **shell script** `sleep 3600` | ตัวใหม่ค้าง ไม่ต่อ CRM → ไม่ถึง `UpdateDeadline` (2 นาที) ก็ถูก guard/systemd timer ถอยกลับ · ตรวจว่าเครื่องกลับมาออนไลน์เอง |
| `1.2.2-bad-exit` · `1.2.3-bad-hang` | สคริปต์เดียวกับ 1.2.0 / 1.2.1 แต่มี **linux amd64 + arm64** (สร้างเมื่อ 2026-11-27 เพื่อทดสอบถอยกลับบน VM arm64) · **ห้าม promote** | เหมือนสองแถวบน · ทดสอบบนเครื่องไหนก็ได้ |
| `1.3.0` | manager จาก repo `edgeconnector-manager` (0df8d6c) · ใช้คำว่า center แทน CRM ใน log, CLI และ error · เคยเป็น `stable` | ติดตั้งด้วย `install-manager.sh` แบบไม่ใส่ `--version` (ได้ตาม stable) · `manager.update` 1.1.0 → 1.3.0 · CLI `sudo edgeconnector manager status` / `doctor` แสดง `center` · ลองใน sandbox แล้ว (container, arm64): enroll, ติดตั้ง hello 1.0.0, `manager status` / `plugin ls` ถูกต้อง |
| `1.3.1` | แก้บั๊ก supervisor (edgeconnector-manager 9b8afc3): ฆ่าทั้ง process group ของ plugin · plugin ที่เปิด process ลูก (เช่น `t-hang`) ไม่ทำให้ `plugin.install` ค้างนานเป็นชั่วโมงอีก · promote → `stable` | ติดตั้งด้วย `install-manager.sh` (ได้ตาม stable) · `manager.update` 1.3.0 → 1.3.1 · S-1 `t-hang` ต้องล้มภายในไม่กี่วินาที ไม่มี `sleep` เหลือ |
| `1.4.0` | อัปเดต plugin อัตโนมัติตามวันและเวลา (edgeconnector-manager 92f869a): Command `manager.auto_update` / `plugin.auto_update`, Event `auto_update`, CLI `manager auto-update` / `plugin auto-update` · ขึ้นอย่างเดียวตาม channel `stable` ของ plugin · `install-manager.sh` เหมือน 1.3.1 ทุกบรรทัด · ไม่ได้ promote (ข้ามไป 1.5.0 ซึ่งรวมของ 1.4.0 ทั้งหมด) · ทดสอบ M-6 | `manager.update` 1.3.1 → 1.4.0 · M-6: ติดตั้ง `t-auto` 1.0.0 (ข้อ 2.3b) · ตั้ง `manager.auto_update` ให้ถึงเวลาในอีก 2 นาที + `plugin.auto_update t-auto on` → รอบอัปเดตขึ้น 1.1.0 (`stable`) เอง และได้ Event `auto_update` done · ปิดตารางแล้วไม่มีรอบ · `sudo edgeconnector manager auto-update` / `plugin ls` คอลัมน์ AUTO |
| `1.5.0` | ทุกอย่างของ 1.4.0 + หยุด/เปิด plugin (`plugin.stop` / `plugin.start`, `stopped` ใน `host.status`, CLI `plugin stop\|start`, `plugin ls` แยก stopped/crashed) + บรรทัด `machine` ใน `manager status` + `install-manager.sh --set KEY=VALUE` + รอบ auto update ข้าม plugin ที่หยุดไว้ (edgeconnector-manager 68ad849) · `install-manager.sh` เพิ่มเฉพาะ `--set` · promote → `stable` (M-7 ผ่านบน VM จริง 2026-11-27) | `manager.update` 1.3.1 → 1.5.0 · M-6 (auto update กับ `t-auto` ตามแถว 1.4.0) · M-7: `plugin.stop` แล้ว `kill -9` manager แล้วเปิดใหม่ → plugin ต้องยังหยุดอยู่ · `plugin.start` เปิดกลับ · restart ของตัวที่หยุด = failed `plugin is stopped; start it instead` · สวิตช์ Auto เปิดอยู่แต่ plugin หยุด → รอบอัปเดตไม่แตะ · `install-manager.sh --set CC_FOO=1` เขียนลง `manager.env` และ `--set CC_TOKEN=x` ถูกปฏิเสธ |

ข้อควรระวัง: version `1.2.x` ของ manager ที่เป็น script **อย่า promote เป็น `stable`** ไม่งั้นเครื่องที่ติดตั้งใหม่จะได้ตัวพัง · ลอง `--version` เท่านั้น
manager ที่ build ด้วย `-X main.version=…` ต้องตรงกับ `MANAGER_VERSION` (make ทำให้เอง) ไม่งั้น `Already` ตัดสินผิด

---

## 3. branch `negative` — release ที่ตั้งใจให้เสีย (ไม่ merge เข้า main)

ใช้ `CC_RELEASE_URL=https://raw.githubusercontent.com/MaiWittawat/edgeconnector-registry/negative` · `cc-release verify` บน branch นี้ **ต้องล้ม** (นั่นคือเป้าหมาย)
ส่วนใหญ่ unit test ครอบคลุมแล้ว ทำที่นี่เพื่อลองผ่าน HTTPS จริงและดูข้อความ error ที่ CRM/UI แสดง · ทำทีหลังสุด

สร้างด้วยโปรแกรม Go ทิ้ง (เก็บไว้ใน scratchpad ไม่ใส่ repo) ที่เรียก `release.Manifest.Sign` + แก้ไฟล์หลังเซ็น · ใช้ shell script เล็ก ๆ เป็น binary เพื่อให้ repo ไม่โต

| plugin / version | ความเสียหาย | manager ต้องตอบ |
|---|---|---|
| `t-badsha` 1.0.0 | แก้ byte ใน archive หลังเซ็น | `ErrBadChecksum` · dest ไม่ถูกสร้าง · ไม่มีไฟล์ชั่วคราวค้าง |
| `t-badsig` 1.0.0 | manifest ลายเซ็นผิด (แก้ `sha256` ใน manifest) | `ErrBadSignature` ก่อนโหลด archive (ดูจาก access log: ไม่มี request ไป archive) |
| `t-mismatch` 1.0.0 | ใส่ manifest ของ `1.0.1` ไว้ในโฟลเดอร์ `1.0.0` | "manifest is for t-mismatch 1.0.1" |
| `t-size` 1.0.0 | `size` ใน manifest ไม่ตรงไฟล์จริง | ปฏิเสธ (size mismatch) |
| `t-nokeyid` 1.0.0 | manifest ไม่มี `keyId`/`sha256` | "manifest is incomplete" |
| `t-colon` 1.0.0 | `name`/`version` ใน manifest มี `:` | ปฏิเสธ (กันลายเซ็นใช้แทนกันได้) |
| `t-traversal` 1.0.0 | tar มี entry `../evil` | `Extract` ปฏิเสธ (unsafe path) · ไม่มีไฟล์หลุดออกนอก `versions/` |
| `t-symlink` 1.0.0 | tar มี symlink | `Extract` ปฏิเสธ (unsupported entry) |
| `t-nobin` 1.0.0 | tar ปกติ แต่ไม่มี `bin/t-nobin` | ติดตั้งล้มอย่างอ่านรู้เรื่อง ไม่ใช่ panic · (manager: สำหรับ plugin `startProcess` ไม่เจอไฟล์ → ไม่ healthy) |
| `t-notgz` 1.0.0 | archive ไม่ใช่ gzip (เซ็นถูกต้อง) | `Extract` error · ไม่ทิ้ง `.tmp` |
| `t-index-huge` | `index.json` ใหญ่ >1 MB | UI: `ReleaseErr` แสดงข้อความ ไม่ล่มทั้งหน้า |

ไม่ปล่อยใน git (ใหญ่เกินไป): archive >200 MB และ manifest >64 KB → ทดสอบกับ `python3 -m http.server`/server ทิ้งในเครื่องแทน (unit test มี `TestGetLimit` และ `TestIndexTooLarge` อยู่แล้ว ข้ามได้)

---

## 4. ขั้นตอนทำงาน (ทำทีละขั้น ขั้นหน้าต้องผ่านก่อน)

1. **keygen**: คำสั่งอยู่ในข้อ 1 · จดบรรทัด `id=<base64>` ทั้งสอง (`.key` เป็นของลับ · `.pub` และ base64 เปิดเผยได้)
2. **registry ในเครื่อง**: ทำใน `/tmp` ไม่ใช่ repo นี้ (`data/try-registry` ตาม README ของโปรเจกต์) · build + เซ็น fixture ข้อ 2 ทั้งหมด · `cc-release verify` ต้องผ่านทุกตัว · ดูขนาดรวม
3. **ลองกับ manager จริง** บน VPS ตามข้อ 4.1 โดยชี้ `CC_RELEASE_URL` ที่ registry ในเครื่อง (`python3 -m http.server 8000 --bind 127.0.0.1 -d <registry>` บน VPS เอง) · ไล่ตารางข้อ 2.1–2.6 ทีละแถวและจดผลลงในไฟล์นี้ (ข้อ 7)
4. **push เฉพาะที่ผ่าน** เข้า `main` · ลำดับ: `hello` 1.0.0 → promote stable → ตรวจ raw URL ด้วย curl จริง → ค่อยตัวอื่น (commit ละ 1 release เพื่อ revert/อ้างอิงง่าย)
5. **ลองกับ registry จริง** (HTTPS, cache 5 นาที, `+` ใน URL) โดยตั้ง `CC_RELEASE_URL` ชี้ GitHub raw
6. **manager** (ข้อ 2.7): ทำบน VPS (Ubuntu + systemd) ทีหลัง plugin
7. **branch `negative`** (ข้อ 3) ทำสุดท้าย

### 4.1 CRM จำลองบน VPS (ไม่มี CRM จริง)

ใช้ `examples/center` เป็น CRM จำลอง วางบน VPS **เครื่องเดียวกับ manager** · ไม่ต้องแก้โค้ดและไม่ต้องเปิดพอร์ตให้ใคร เพราะ dev cert ของ center ใช้ได้กับ `127.0.0.1` อยู่แล้ว
(checklist เต็มของโปรเจกต์อยู่ที่ README ของ edgeconnector หัวข้อ "ทดสอบกับ registry บน GitHub" · เปลี่ยนชื่อ key จาก `release-2026` เป็น `lab-2026`)

```bash
# บนเครื่องพัฒนา: build center สำหรับ linux/amd64 (VPS เป็น x86_64) แล้วส่งขึ้น VPS
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /tmp/center ./examples/center
scp /tmp/center <user>@<vps>:~/center

# บน VPS: ผูกกับ 127.0.0.1 ทั้ง gRPC และ admin (admin HTTP ไม่มีรหัสผ่านที่ /admin/ จึงห้ามเปิดออกนอกเครื่อง)
mkdir -p ~/center-data && cd ~/center-data
~/center -data ~/center-data -addr 127.0.0.1:7443 -admin 127.0.0.1:8080 -ui-password '<รหัส>' \
  -release-url http://127.0.0.1:8000 -manager-server-addr 127.0.0.1:7443
# ค้างไว้ใน tmux/screen (หรือทำ systemd unit ถ้าจะใช้นาน)

# เปิด UI จากเครื่องพัฒนาผ่าน SSH tunnel (ไม่เปิดพอร์ต 8080 ให้ภายนอก)
ssh -L 8080:127.0.0.1:8080 <user>@<vps>      # แล้วเปิด http://localhost:8080/ui/

# ติดตั้ง manager บน VPS: คำสั่ง curl จากหน้า Add manager ต่อท้ายด้วย CA ของ center
#   --ca-cert-file ~/center-data/certs/ca.pem
```

ข้อควรระวัง:
- `-release-url` ใช้ได้ทั้ง `http://127.0.0.1:8000` (registry ในเครื่อง ลองได้เร็ว ไม่มี cache) และ GitHub raw (`https://raw.githubusercontent.com/MaiWittawat/edgeconnector-registry/main` ลองของจริง) · manager ต้องตั้ง `CC_RELEASE_URL` ให้ชี้ที่เดียวกับที่ต้องการลอง (คำสั่ง curl ใส่ `--base-url` ให้ตาม `-release-url` ของ center)
- ข้อมูล center (token, connector) อยู่ใน `~/center-data/store.json` · ลบแล้วเริ่มใหม่ได้ แต่ manager ที่ enroll ไว้จะใช้ไม่ได้ ต้อง `--reenroll`
- ถ้า VPS มี firewall/ufw อยู่แล้วไม่ต้องแก้อะไร เพราะไม่มีพอร์ตไหนฟังนอก 127.0.0.1

---

## 5. สิ่งที่ "ไม่ต้องทำ" (ซ้ำกับ unit test หรือไม่ได้ประโยชน์)

- ปล่อย `hello` หลายสิบ version เพื่อดู UI → ใช้ `index.json` ที่สร้างเองใน registry ในเครื่องแทน (`maxReleaseRows` ตัดแถวเกิน; ไม่ต้องมีไฟล์จริง)
- ทดสอบ redirect เปลี่ยน scheme (https→http) กับ GitHub raw → GitHub ไม่ทำแบบนั้น · `TestFetchRejectsSchemeDowngradeRedirect` ครอบคลุมแล้ว
- release ของชื่อ `manager` แบบ plugin → ชื่อสงวน ถูกปฏิเสธตั้งแต่ก่อนแตะ network (`TestInstallReservedName`)
- ลองกับ Windows → โปรเจกต์ไม่มี target windows

---

## 6. การตัดสินใจ

**ตัดสินใจแล้ว**
- platform: Linux อย่างเดียว · VPS เป็น `x86_64` = `linux_amd64`
- เพิ่ม `startDelay` / `crashAfter` ใน hello-plugin: ทำแล้ว (PR #11)
- การเรียง version ใน UI: เรียงแบบ semver (PR #10)
- มีเครื่อง Linux: Ubuntu VPS + CRM จำลองบนเครื่องเดียวกัน (ข้อ 4.1)
- branch `negative`: ทำ (ข้อ 3)
- กรณี version (`t-ver` ข้อ 2.4): ทำ

**ยังค้าง:** ไม่มี · ต้อง merge PR #10, #11 ก่อน แล้วเริ่มข้อ 4 ได้

---

## 7. บันทึกผลทดสอบ (กรอกเมื่อทำแต่ละข้อ)

| รหัส | release | ผล | วันที่ | หมายเหตุ |
|---|---|---|---|---|
| H-1 | hello 1.0.0 ติดตั้งครั้งแรก | – | – | |
| H-2 | hello 1.1.0 อัปเกรด + rollback | – | – | |
| H-3 | hello 1.2.0 พัง (ทับ 1.1.0 / เครื่องใหม่) | – | – | |
| T-KEY | hello 1.3.0 ลายเซ็น lab-2027 | – | – | |
| SC-1 | scope: manager token มี `dnc:read` แล้วติดตั้ง hello ด้วย `scopes:["admin"]` ต้องล้ม (เกินเพดาน) · ด้วย `["dnc:read"]` ผ่าน · ลดของ manager ใน UI แล้ว scope ของ plugin ถูกตัด (ใช้ hello 1.0.0 ไม่ต้องมี release เพิ่ม) | – | – | |
| S-1 | t-hang / t-exit / t-noterm | – | – | |
| V-1 | t-ver (`+`, `1.10.0`, `v1`) | – | – | |
| P-1 | t-otherarch บน VPS (arch ไม่ตรง) | – | – | |
| C-1 | channel stable/beta | – | – | |
| M-1 | manager 1.0.0 install-manager.sh | – | – | |
| M-2 | manager 1.1.0 self-update | – | – | |
| M-3 | manager ถอยกลับเอง: `1.2.0-bad-exit` / `1.2.1-bad-hang` (amd64) · `1.2.2-bad-exit` / `1.2.3-bad-hang` (amd64 + arm64) | ผ่านครบทั้ง 3 ชั้นบน VM arm64 (manager 1.5.0) | 2026-11-27 | VM multipass Debian arm64 + center บน VPS · **ชั้น 1 (ตัวใหม่ไม่ถึง center ใน 2 นาที):** สั่งอัปเดต 1.5.0 → 1.3.1 ตอน center ปิด → ครบ 2 นาที log `manager 1.3.1 did not reach the center within 2m0s; rolled back to 1.5.0` · manager 1.5.0 ขึ้นกลับ · UI ขึ้นแถบ "The last manager update failed ... rolled back to 1.5.0" เมื่อ center กลับมา (manager รายงาน `manager_update_error` ขึ้นเอง) · **ชั้น 2 (manager-guard, crash วน):** `1.2.2-bad-exit` (`boom`, exit 1) เปิดแล้วดับ 3 ครั้ง → ครั้งที่ 4 `manager-guard: manager 1.2.2-bad-exit failed to start 3 times; rolled back to 1.5.0` · รวม 12 วินาที · **ชั้น 3 (timer 180 วินาที, ค้าง):** `1.2.3-bad-hang` → เห็น timer `edgeconnector-manager-update-check` → 181 วินาทีต่อมา `manager-guard: manager 1.2.3-bad-hang did not reach the center within 180 seconds; rolled back to 1.5.0` (log อยู่ใน unit `edgeconnector-manager-update-check` ไม่ใช่ `edgeconnector-manager`) · `current` กลับ `versions/1.5.0` ไม่มีโฟลเดอร์ `update/` timer ไม่ค้าง · ทดสอบแล้วว่าคำสั่งอัปเดตที่ค้างใน center ระหว่าง manager ออฟไลน์ถูกส่งตามหลังเมื่อ manager กลับมา (เริ่มรอบถอยกลับใหม่เอง = ถูกต้องตาม at-least-once) · **ยังไม่ได้ทดสอบ:** manager 1.5.0 บน x86_64 จริง |
| M-4 | manager 1.3.0 (stable) | ผ่านบางส่วน | 2026-11-25 | ลองใน sandbox (Docker, linux/arm64, ก่อน push จาก registry ในเครื่อง): image อ่าน stable ได้ 1.3.0 และตรวจลายเซ็นผ่าน · enroll · ติดตั้ง hello 1.0.0 จาก GitHub · `manager status` แสดง `center connected` · `plugin ls` healthy · ยังไม่ได้ลองบน VPS (systemd, install-manager.sh, self-update) |
| D-1 | demo 1.0.0 (stable) ครบ 5 ชนิด | ผ่านใน sandbox | 2026-11-25 | Docker linux/arm64 · ติดตั้งจากสำเนาของ registry นี้ก่อน push (อ่าน `stable` ได้ 1.0.0) · `version`, `dnc.check` = `clean`, `job.run` → Event `job.done` · รอบก่อนปล่อย (build เดียวกัน) ลอง `greet`, job ซ้ำ = `already`, Notify, ถอด scope ครบแล้ว · ยังไม่ได้ลองบน VPS (amd64) |
| M-6 | manager 1.4.0 / 1.5.0 auto update กับ `t-auto` | ผ่านใน sandbox (1.5.0) · บน VM จริงยังไม่ได้ลอง | 2026-11-27 | Docker, center ตัวอย่างจาก pkg main (UI ใหม่ + JSON API), manager 1.5.0 ล็อกด้วย `MANAGER_VERSION`: ติดตั้ง `t-auto` 1.0.0 → เปิดสวิตช์ plugin + ตารางเครื่อง (`PUT …/auto-update`, `next_run` ตรง) → ถึงเวลา 03:00 UTC `t-auto` ขึ้น 1.1.0 เอง · Event `auto_update` `{t-auto, 1.0.0 → 1.1.0, done}` ถึง center และขึ้นในหน้า Activity · ยังไม่ได้ทดสอบ: 1.4.0 แยก, ถอยด้วยมือแล้วเห็น `skip_version` ในรอบถัดไปบน VPS, โหลด registry ล่ม |
| M-7 | manager 1.5.0 stop/start + `--set` | ผ่านบน VM จริง (systemd) | 2026-11-27 | VM multipass Debian arm64 + center บน VPS (cert จริง) · `manager.update` 1.3.1 → 1.5.0 จาก UI ใหม่ผ่าน (`manager status` มีบรรทัด `machine` และ `updates`) · `install-manager.sh --version 1.5.0 --set CC_FOO=1` เขียนลง `manager.env` และบรรทัดอื่น (`GODEBUG`) ยังอยู่ · `--set CC_TOKEN=x` ถูกปฏิเสธ "the token is never written to disk" · `--set cc_foo=1` ถูกปฏิเสธเรื่องรูปแบบ key · `plugin.stop` → `kill -9` manager → systemd เปิดใหม่ (MainPID เปลี่ยน, NRestarts=1) → plugin ยังหยุด ไม่มี process · `plugin.start` เปิดกลับเป็น healthy · sandbox (Docker): restart ตอนหยุดถูกปฏิเสธ, rollback ตอนหยุดไม่เปิด, รอบ auto update ข้ามตัวที่หยุด · **ยังไม่ได้ทดสอบ:** manager 1.5.0 บน x86_64 จริง (ทดสอบรันบน arm64 เท่านั้น) · ถอยกลับของ manager ทดสอบแล้วที่ M-3 |
| M-5 | manager 1.3.1 กับ `t-hang` | ผ่านใน sandbox | 2026-11-25 | Docker linux/arm64 ก่อน push: `t-hang` (`start_timeout_sec` 3) ล้มใน 5 วินาที (1.3.0 ค้าง `pending` เป็นชั่วโมง) · ไม่มี `sleep 3600` เหลือ · คำสั่งถัดไป (ติดตั้ง demo) ทำได้ทันที · **เจอ:** ติดตั้งครั้งแรกที่ start ไม่ขึ้นทิ้งโฟลเดอร์ `plugins/t-hang` ไว้ (โค้ดลบให้เฉพาะตอนโหลดไม่ผ่าน) → H-3 แบบ (ข) จะเห็นแบบเดียวกัน · ยังไม่ได้ลองบน VPS |
| N-1 | branch negative | – | – | |
