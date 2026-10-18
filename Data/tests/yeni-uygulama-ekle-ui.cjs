/* Konsol's Uygulama ekle, a full-window page (DD-279), and an application's Tanım edit (rebuild phase 5; K2, K3) in
   the committed build under Data/console/yeni, with the production CSP and fixture replies for every endpoint they
   read or post to (yeni-harness.cjs): the four sources (a pasted, uploaded or dropped file, an https address, an image
   name as a job with its log, an existing container), the inspector (the file beside the questions, its line marks,
   the question in hand lighting its line, refusals with their lines, every question kind by service, the answers
   checked again as they change), the install's plan (a refusal leading back to its question), the install job's log
   (a finished one staying, a failed one leading back to the question it names) and leaving with something entered;
   Tanım's editor and questions (a staying port's use left to Erişim, a stored secret kept or renewed, a
   new port), its plan's difference and apply job, and the refresh from an address source. Every request body is
   checked exactly; no secret value reaches an address, the browser's storage or a GET request. Fails on any console
   error, CSP violation, page error or layout finding. Never contacts a server.
   PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/yeni-uygulama-ekle-ui.cjs */
const assert = require("node:assert/strict");
const { isDeepStrictEqual } = require("node:util");
const { uygulama, servis, uygulamalar, ayrinti, soru, inceleme } = require("./yeni-harness.cjs").fixtures;

// ---- fixtures: documentation values only (RFC 5737 addresses, registry.example images, example.org); shapes as in api/sema.ts
const D = (c) => c.repeat(64);
const JOB = (n) => String(n).padStart(32, "0");
const ROOT_WARNING = "Bu konteyner root olarak başlıyor; kendi kullanıcısına geçmezse /srv'ye Dosyalar hesabının açamayacağı dosyalar yazabilir.";
const accessCell = (durum, adresler = []) => ({ durum, adresler, not: "", uyari: "" });
const NOTLAR_WEB = "uygulama:notlar:web:8080/tcp";
const NOTLAR_UDP = "uygulama:notlar:web:9000/udp";
const NOTLAR_ROW = { tur: "adres", ad: "notlar", tailscale_portu: null, internet: "" };
const accessRow = (id, satir) => ({ id, ad: "notlar · web", tur: "uygulama", aciklama: "", uygulama: "notlar", servis: "web", anahtar: id.split(":").slice(2).join(":"),
  calisiyor: true, yerel: accessCell("kapali"), tailscale: accessCell("acik", ["notlar.ev"]), wireguard: accessCell("kapali"), internet: accessCell("kapali"),
  satir, web: null, ayrinti: [] });

// The file every source ends in (a pasted Compose file with each kind of question).
const ORNEK_FILE = [
  "name: ornek",
  "services:",
  "  web:",
  "    image: registry.example/ornek/web:1.2",
  "    ports: [\"8080:8080\", \"9000/udp\", \"5432\"]",
  "    volumes: [\"veri:/data\", \"/srv/Belgeler:/belgeler:ro\"]",
  "    environment:",
  "      TZ: ${TZ:-Europe/Istanbul}",
  "      ADMIN_PASSWORD: ${ADMIN_PASSWORD}",
  "      API_TOKEN: \"\"",
  "  db:",
  "    image: registry.example/ornek/db:16",
  "    user: \"999:999\"",
  ""].join("\n");
const REFUSED_LINE = "    privileged: true";
const REFUSED_FILE = ORNEK_FILE.split("\n").toSpliced(4, 0, REFUSED_LINE).join("\n");
const ORNEK_INSPECTION = inceleme({ name: "ornek", services: [{ name: "web" }, { name: "db" }], questions: [
  soru.ad("ornek", { line: 1 }),
  soru.degisken("TZ", { line: 8, default: "Europe/Istanbul", why: "Dosya bu değeri dışarıdan (.env) bekliyor; varsayılanı: Europe/Istanbul." }),
  soru.degisken("ADMIN_PASSWORD", { line: 9, secret: true, generate: true }),
  soru.port("web", 8080, { line: 5, suggest: "ornek", host_port: 8080 }), soru.port("web", 9000, { line: 5, protocol: "udp" }),
  soru.port("web", 5432, { line: 5, guess: "raw",
    why: "Web dışı bir port gibi görünüyor (bilinen bir servis portu ya da aynı port UDP'de de açılıyor): ham port önerilir. Ham portlar kapalı gelir; Erişim'den açılır." }),
  soru.klasor("web", "/data", { line: 6 }),
  soru.klasor("web", "/belgeler", { line: 6, source: "/srv/Belgeler", source_kind: "absolute", read_only: true, suggest: "srv", folder: "belgeler", srv_path: "/srv/Belgeler" }),
  soru.gizli("web", "API_TOKEN", { line: 10 }),
  soru.baslangic("web", { line: 3 }),
  soru.baslangic("db", { line: 11, suggest: "direct", user: "999:999", direct_user: "999:999",
    why: "Dosya kullanıcıyı belirtiyor (999:999): doğrudan bu kullanıcıyla başlayabilir; bütün yetkiler kapalı, yeni yetki kazanılamaz." })],
notes: [{ line: 5, key: "ports", text: "Dosyadaki sunucu tarafı (8080) kullanılmaz; port Erişim'den açılır." }] });
const REFUSED_INSPECTION = inceleme({ name: "ornek", refusals: [{ line: 5, key: "privileged", text: "web: privileged kullanılamaz; konteynerler ayrıcalıklı çalışmaz." }],
  questions: [] });
// The drafts the other sources answer with: each is inspected like a file.
const ADRES = "https://files.example.org/ornek/compose.yaml";
const ADRES_FILE = "services:\n  pano:\n    image: registry.example/pano:3\n    ports: [\"3000\"]\n";
const ADRES_INSPECTION = inceleme({ name: "pano", questions: [soru.ad("pano"), soru.port("pano", 3000, { line: 4, suggest: "pano" }), soru.baslangic("pano")] });
const IMAGE = "registry.example/ornek:2";
const IMAGE_FILE = `# Taslak: ${IMAGE}\nservices:\n  ornek:\n    image: ${IMAGE}\n    ports: ["80"]\n`;
const IMAGE_INSPECTION = inceleme({ name: "ornek", questions: [soru.ad("ornek", { line: 3 }), soru.port("ornek", 80, { line: 5, suggest: "ornek" }), soru.baslangic("ornek", { line: 3 })] });
const CONTAINER_FILE = "services:\n  eski-redis:\n    image: registry.example/redis:7\n    volumes: [\"redis-veri:/data\"]\n";
const CONTAINER_INSPECTION = inceleme({ name: "eski-redis", questions: [soru.ad("eski-redis"), soru.klasor("eski-redis", "/data", { line: 4, source: "redis-veri", folder: "redis-veri" }),
  soru.baslangic("eski-redis")] });

// notlar, whose Tanım is edited: its stored file, answers and the inspection of its file (with a new port: 7000).
const NOTLAR_FILE = [
  "services:",
  "  web:",
  "    image: registry.example/notlar/web:2.4",
  "    ports: [\"8080\", \"9000/udp\"]",
  "    environment: { TZ: Europe/Istanbul, DB_PASSWORD: \"${DB_PASSWORD}\" }",
  "    volumes: [\"veri:/data\"]",
  ""].join("\n");
const NOTLAR_NEW = NOTLAR_FILE.replace('["8080", "9000/udp"]', '["8080", "9000/udp", "7000"]');
const notlarInspection = (withNew) => inceleme({ name: "notlar", questions: [
  soru.ad("notlar"), soru.degisken("TZ", { line: 5 }), soru.degisken("DB_PASSWORD", { line: 5, secret: true, generate: true }),
  soru.port("web", 8080, { line: 4, suggest: "notlar" }), soru.port("web", 9000, { line: 4, protocol: "udp" }),
  ...(withNew ? [soru.port("web", 7000, { line: 4, suggest: "notlar-7000" })] : []),
  soru.klasor("web", "/data", { line: 6 }), soru.baslangic("web")] });
const NOTLAR_ANSWERS = { name: "notlar", answers: { "var:DB_PASSWORD": { set: true }, "var:TZ": { value: "Europe/Istanbul" }, "mount:web:/data": { to: "app" },
  "start:web": { mode: "root" } } };
const PANO_FILE = "services:\n  web:\n    image: registry.example/pano:1\n    ports: [\"3000\"]\n";
const PANO_NEW = "services:\n  web:\n    image: registry.example/pano:2\n    ports: [\"3000\", \"3001\"]\n";
const panoInspection = (withNew) => inceleme({ name: "pano", questions: [soru.ad("pano"), soru.port("web", 3000, { line: 4, suggest: "pano" }),
  ...(withNew ? [soru.port("web", 3001, { line: 4, suggest: "pano-3001" })] : []), soru.baslangic("web")] });

const PLAN = {
  ad: "ornek", veri: "/var/lib/master-stack/uygulamalar/ornek", ag: "ksl-ornek", pod: null,
  birimler: ["konsol-ornek.network", "konsol-ornek_db.container", "konsol-ornek_web.container"],
  servisler: [
    { ad: "web", baslangic: "root", kullanici: null, imaj: "registry.example/ornek/web:1.2", gizliler: ["ornek-admin-password", "ornek-api-token"],
      baglamalar: [{ hedef: "/data", tur: "app", yol: "/var/lib/master-stack/uygulamalar/ornek/veri", salt_okunur: false },
        { hedef: "/belgeler", tur: "srv", yol: "/srv/Belgeler", salt_okunur: true }] },
    { ad: "db", baslangic: "direct", kullanici: "999:999", imaj: "registry.example/ornek/db:16", gizliler: [], baglamalar: [] }],
  erisim: [
    { id: "uygulama:ornek:web:8080/tcp", anahtar: "web:8080/tcp", servis: "web", port: 8080, protokol: "tcp", satir: { tur: "adres", ad: "ornek", tailscale_portu: null, internet: "" },
      adres: "http://ornek.ev" },
    { id: "uygulama:ornek:web:9000/udp", anahtar: "web:9000/udp", servis: "web", port: 9000, protokol: "udp", satir: { tur: "ham", kapsam: "kapali", port: 9000 }, adres: null },
    { id: "uygulama:ornek:web:5432/tcp", anahtar: "web:5432/tcp", servis: "web", port: 5432, protokol: "tcp", satir: { tur: "ham", kapsam: "kapali", port: 5432 }, adres: null }],
  klasorler: ["/var/lib/master-stack/uygulamalar/ornek/veri"],
  gizliler: [{ ad: "ornek-admin-password", servisler: ["web"] }, { ad: "ornek-api-token", servisler: ["web"] }],
  uyarilar: [{ servis: "web", metin: ROOT_WARNING }],
  imajlar: ["registry.example/ornek/web:1.2", "registry.example/ornek/db:16"],
};
const FARK = {
  birimler: [{ ad: "konsol-notlar_web.container", degisim: "degisir" }], ortam: ["web"],
  portlar: [{ anahtar: "web:7000/tcp", degisim: "eklenir", yerel_port: null }, { anahtar: "web:8080/tcp", degisim: "kalir", yerel_port: 62001 },
    { anahtar: "web:9000/udp", degisim: "kalir", yerel_port: null }],
  klasorler: { eklenen: [], birakilan: [] }, gizliler: { yeni: [], yenilenen: ["notlar-db-password"], korunan: [], kaldirilan: [] },
  baslangic: [{ servis: "web", once: "root", sonra: "direct" }], uyarilar: [{ servis: "web", metin: ROOT_WARNING }], yeniden_baslar: true,
};
const NO_FARK = { birimler: [], ortam: [], portlar: [{ anahtar: "web:8080/tcp", degisim: "kalir", yerel_port: 62001 }], klasorler: { eklenen: [], birakilan: [] },
  gizliler: { yeni: [], yenilenen: [], korunan: ["notlar-db-password"], kaldirilan: [] }, baslangic: [], uyarilar: [], yeniden_baslar: false };

function apps() {
  return [
    uygulama("notlar", { servisler: [servis("web", { imaj: "registry.example/notlar/web:2.4" })], revizyon: "rev-notlar-3" }),
    uygulama("pano", { servisler: [servis("web", { imaj: "registry.example/pano:1" })], koken: "adres", revizyon: "rev-pano-1" }),
  ];
}
const VERI = "/var/lib/master-stack/uygulamalar/";
function details() {
  const items = Object.fromEntries(data.uygulamalar.items.map((a) => [a.ad, a]));
  const out = {};
  if (items.notlar) {
    out.notlar = ayrinti(items.notlar, { metin: NOTLAR_FILE, yanitlar: NOTLAR_ANSWERS, gizliler: [{ ad: "notlar-db-password", servisler: ["web"] }],
      koken: { tur: "dosya", adres: null, imaj: null, konteyner: null, alindi: 1791700000, sha256: D("e") } }, {
      web: { baslangic: "root", gizliler: ["notlar-db-password"],
        portlar: [{ port: 8080, protokol: "tcp", id: NOTLAR_WEB, erisim: NOTLAR_ROW, kullanim: "caddy", tailscale_adi: "notlar", yerel_port: 62001 },
          { port: 9000, protokol: "udp", id: NOTLAR_UDP, erisim: { tur: "ham", kapsam: "kapali", port: 9000 }, kullanim: "raw", tailscale_adi: null, yerel_port: null }],
        baglamalar: [{ hedef: "/data", tur: "app", yol: VERI + "notlar/veri", salt_okunur: false }] } });
  }
  if (items.pano) {
    out.pano = ayrinti(items.pano, { metin: PANO_FILE, yanitlar: { name: "pano", answers: { "start:web": { mode: "root" } } },
      koken: { tur: "adres", adres: "https://files.example.org/pano/compose.yaml", imaj: null, konteyner: null, alindi: 1791710000, sha256: D("f") } }, {
      web: { baslangic: "root", portlar: [{ port: 3000, protokol: "tcp", id: "uygulama:pano:web:3000/tcp", erisim: { tur: "adres", ad: "pano", tailscale_portu: null, internet: "" },
        kullanim: "caddy", tailscale_adi: "pano", yerel_port: 62002 }] } });
  }
  if (items.ornek) out.ornek = ayrinti(items.ornek);
  return out;
}

const data = {
  kaynaklar: { host: "sunucu", version: "2026.08.06-v2-244", surum: "1.0.0", domain: "ev", os: "Debian GNU/Linux 13 (trixie)", kernel: "6.12.0", uptime: 432000,
    cores: 4, read_at: 1791845000, sampled_at: 1791845000, cpu: 2.0, mem: { total: 8375186227, used: 696254464 },
    net: { wan: "203.0.113.10", wan6: "", iface: "eth0", tailscale: "100.64.0.2", tailscale6: "" }, root: "/srv", disk: { total: 269186688614, free: 255550000000 } },
  saglik: { status: "ok", read_at: 1791844900, checks: [{ id: "tailscale", name: "Tailscale", status: "ok", detail: "çalışıyor" }] },
  guncelleme: { kurulu: "2026.08.06-v2-244", kurulu_surum: "1.0.0", son: "2026.08.06-v2-244", son_surum: "1.0.0", commit: "0".repeat(40), yeni: false,
    denetlendi: 1791845000, hata: "", is: { durum: "tamam", hedef: "", mesaj: "", bitis: 0, asama: "" }, baslatilabilir: true },
  bekleyen: { bekleyen: null },
  etkinlik: { items: [] },
  erisim: { read_at: 1791845000, alan: "ev", revizyon: "rev-1", hizmetler: [accessRow(NOTLAR_WEB, NOTLAR_ROW)], hatalar: [], uyarilar: [],
    ozet: { tailscale: { ipv4: "100.64.0.2", ipv6: "", durum: "bagli", anahtar_bitis: null, ad: "sunucu", surum: "1.80.0", adresler: ["100.64.0.2"], cikis_dugumu: true },
      internet: { ipv4: "203.0.113.10", ipv6: "", acik: [] }, wireguard: { kurulu: true, durduruldu: false, not: "", aglar: [] }, sertifikalar: [] } },
  uygulamalar: uygulamalar(apps(), { kaynaklar: [{ ad: "eski-redis", imaj: "registry.example/redis:7", durum: "running" }] }),
};

let expectedFailures = [];
const h = require("./yeni-harness.cjs").create({ name: "konsol-yeni-uygulama-ekle-ui", url: process.env.KONSOL_URL || "http://127.0.0.1:8770", data,
  expected: () => expectedFailures });
const { base, push, waitFor, newPage, noHorizontalScroll, styleAttributes, shot } = h;

// ---- the inspector: an inspection by the file's text; with answers, the errors by question or a definition
function inspectionOf(text) {
  if (text.includes("privileged")) return REFUSED_INSPECTION;
  if (text === ORNEK_FILE) return ORNEK_INSPECTION;
  if (text === ADRES_FILE) return ADRES_INSPECTION;
  if (text === IMAGE_FILE) return IMAGE_INSPECTION;
  if (text === CONTAINER_FILE) return CONTAINER_INSPECTION;
  if (text === NOTLAR_FILE || text === NOTLAR_NEW) return notlarInspection(text === NOTLAR_NEW);
  if (text === PANO_FILE || text === PANO_NEW) return panoInspection(text === PANO_NEW);
  return inceleme({ format: null, name: "", refusals: [{ line: 1, key: "dosya", text: "Dosya Compose ya da Kubernetes değil." }] });
}
function check(inspection, answers) {
  const errors = {};
  for (const q of inspection.questions) if (q.kind !== "name" && !(q.id in answers.answers)) errors[q.id] = "Yanıt gerekli.";
  if (answers.answers["var:TZ"]?.value === "Mars/Olympus") errors["var:TZ"] = "Bu değer kabul edilmedi.";
  return errors;
}
h.handlers["/api/konsol/uygulamalar/denetle"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const inspection = inspectionOf(body.metin);
  if (!body.yanitlar) return { body: { inceleme: inspection } };
  const errors = check(inspection, body.yanitlar);
  return { body: Object.keys(errors).length ? { inceleme: inspection, hatalar: errors } : { inceleme: inspection, tanim: { name: body.yanitlar.name } } };
};
// The drafts: an address and a container at once; an image is a job whose record ends in the draft.
let imageReads = 0;
h.handlers["/api/konsol/uygulamalar/kaynak"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  if (body.tur === "adres") {
    if (body.adres !== ADRES) return { status: 502, body: { error: "Adres indirilemedi: bağlantı kurulamadı." } };
    return { body: { metin: ADRES_FILE, kaynak: body } };
  }
  if (body.tur === "imaj") return { body: { is: JOB(50) } };
  return { body: { metin: CONTAINER_FILE, kaynak: body } };
};
const L = (t, tur, ileti) => ({ t: 1791845200 + t, tur, ileti });
const IMAGE_LOG = [L(0, "adim", "Doğrulanıyor"), L(1, "adim", `İmaj indiriliyor: ${IMAGE}`)];
// An install's records, read in turn (the last one stays): set by each scenario.
let installReads = [];
h.handlers["/api/konsol/konteynerler/islem"] = ({ method, query }) => {
  if (method !== "GET") return undefined;
  if (query.get("id") === JOB(1)) return { body: installReads.length > 1 ? installReads.shift() : installReads[0] };
  if (query.get("id") !== JOB(50)) return undefined;
  imageReads += 1;
  return imageReads < 3 ? { body: { id: JOB(50), action: "uygulama-taslak", name: IMAGE, state: "running", step: `İmaj indiriliyor: ${IMAGE}`, gunluk: IMAGE_LOG } }
    : { body: { id: JOB(50), action: "uygulama-taslak", name: IMAGE, state: "done", step: "", gunluk: IMAGE_LOG, result: { metin: IMAGE_FILE, kaynak: { tur: "imaj", imaj: IMAGE } } } };
};
const installJob = (name, o) => ({ id: JOB(1), action: "uygulama-kur", name, state: "running", step: "", created_at: 1791845200, updated_at: 1791845200, gunluk: [], ...o });
const OK_LOG = [L(0, "adim", "Doğrulanıyor"), L(0, "adim", "Dosya denetleniyor"), L(1, "adim", "İmaj indiriliyor: registry.example/ornek/web:1.2"),
  L(3, "bilgi", "İmaj sabitlendi: registry.example/ornek/web@sha256:" + D("d")), L(4, "adim", "Başlatılıyor: konsol-ornek_web.service"),
  L(5, "adim", "Hazır olması bekleniyor"), L(6, "bilgi", "web çalışıyor."), L(6, "bilgi", "db çalışıyor."), L(7, "adim", "Adresler yayımlanıyor"), L(8, "tamam", "Tamamlandı")];
const PANO_ERROR = "Kurulum başarısız (Hazır olması bekleniyor): pano başladıktan hemen sonra durdu (günlüğü: journalctl -u konsol-pano_pano.service). " +
  "Doğrudan başlatma bu imajda çalışmayabilir (imaj root başlayıp kendi kullanıcısına geçiyor olabilir); Root olarak başlatmayı deneyin. Yapılan her şey geri alındı.";
const FAIL_LOG = [L(0, "adim", "Doğrulanıyor"), L(2, "adim", "Başlatılıyor: konsol-pano_pano.service"), L(3, "adim", "Hazır olması bekleniyor"),
  L(4, "cikti", "preinit: fatal: /run belongs to uid 0 instead of 1000"), L(4, "cikti", "child failed with exit code 100"),
  L(4, "hata", "pano başladıktan hemen sonra durdu (günlüğü: journalctl -u konsol-pano_pano.service)."), L(5, "adim", "Geri alınıyor"),
  L(16, "bilgi", "Yapılan her şey geri alındı.")];
// The install's plan (every check before the first write) and the install.
h.handlers["/api/konsol/uygulamalar/kur"] = ({ method, body }) => {
  if (method !== "POST") return undefined;
  const inspection = inspectionOf(body.metin);
  if (!body.plan) return { status: 202, body: { is: JOB(1), eylem: "kur", ad: body.yanitlar.name } };
  const errors = check(inspection, body.yanitlar);
  if (body.yanitlar.answers["mount:web:/belgeler"]?.path === "/srv/Filmler") {
    errors["mount:web:/belgeler"] = "Klasör yok: /srv/Filmler";
    errors.podman = "Bu dosya Podman 5 gerekir; bu sunucuda 4.9.";
  }
  return { body: Object.keys(errors).length ? { inceleme: inspection, hatalar: errors } : { inceleme: inspection, tanim: { name: body.yanitlar.name }, ozet: PLAN } };
};
// The files backend's folders under /srv (the folder picker).
h.handlers["/api/list"] = ({ method, query }) => {
  if (method !== "GET") return undefined;
  const path = query.get("path") || "";
  const names = path === "" ? ["Belgeler", "Filmler", ".gizli"] : path === "Belgeler" ? ["arsiv"] : [];
  return { body: { path, entries: names.map((name) => ({ name, type: "dir" })) } };
};
// One application's detail; Tanım's plan and apply; the refresh from an address.
const tanimReplies = [];
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)$/, ({ method }, m) => {
  if (method !== "GET") return undefined;
  const d = details()[m[1]];
  return d ? { body: d } : { status: 404, body: { error: "Uygulama bulunamadı." } };
}]);
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/([a-z][a-z0-9-]*)\/tanim$/, ({ method, body }, m) => {
  if (method !== "POST") return undefined;
  const inspection = inspectionOf(body.metin);
  if (!body.plan) return { body: { is: JOB(70), eylem: "tanim", ad: m[1] } };
  const queued = tanimReplies.shift();
  if (queued) return queued;
  if (body.yanitlar.answers["var:TZ"]?.value === "Mars/Olympus") return { body: { inceleme: inspection, hatalar: { "var:TZ": "Bu değer kabul edilmedi." } } };
  return { body: { inceleme: inspection, fark: body.metin === NOTLAR_NEW ? FARK : NO_FARK } };
}]);
let panoSource = PANO_NEW;
h.dynamic.push([/^\/api\/konsol\/uygulamalar\/pano\/yenile$/, ({ method }) => (method === "POST"
  ? { body: { metin: panoSource, yanitlar: { name: "pano", answers: { "port:web:3000/tcp": { use: "caddy", tailscale_name: "pano" }, "start:web": { mode: "root" } } },
    yeni_sorular: panoSource === PANO_NEW ? ["port:web:3001/tcp"] : [] } } : undefined)]);

// ---- helpers
const url = (hash) => new URL("/" + hash, base).href;
const active = (page) => page.evaluate(() => {
  const e = document.activeElement;
  return e ? (e.getAttribute("aria-label") || e.textContent || "").trim().replace(/\s+/g, " ") : "";
});
const postsTo = (path) => h.requests.filter((r) => r.method === "POST" && r.path === path).map((r) => r.body);
const lastPost = (path) => postsTo(path).at(-1);
const DENETLE = "/api/konsol/uygulamalar/denetle";
const KAYNAK = "/api/konsol/uygulamalar/kaynak";
const KUR = "/api/konsol/uygulamalar/kur";
const job = (o) => ({ tur: "uygulama", id: JOB(1), ad: "ornek · Kurulum", durum: "calisiyor", adim: "", bitis: null, ...o });
async function noStyles(page, where) {
  assert.deepEqual(await styleAttributes(page), [], "no style attributes: " + where);
}
/** No secret value in the address, the browser's storage or any GET request's address. */
async function noSecrets(page, secrets, where) {
  const stored = await page.evaluate(() => JSON.stringify([location.href, history.state, { ...localStorage }, { ...sessionStorage }]));
  const gets = h.requests.filter((r) => r.method === "GET").map((r) => r.path + r.query).join("\n");
  for (const s of secrets) {
    assert(!stored.includes(s), `${where}: a secret in the address or storage`);
    assert(!gets.includes(s), `${where}: a secret in a GET request`);
  }
}
const marksOf = (scope) => scope.locator(".code-line[data-satir]").evaluateAll((els) => els.map((e) => [Number(e.dataset.satir), e.querySelector(".code-mark").textContent,
  [...e.classList].find((c) => c.startsWith("code-line-")).slice(10)]));
const questionIds = (scope) => scope.locator("[data-soru]").evaluateAll((els) => els.map((e) => e.dataset.soru));

(async () => {
  h.checkBuild();
  await h.start();
  try {
    let page;
    // ================= Kaynak: a full-window page of its own; four sources; an upload and a drop read here
    page = await newPage();
    await page.goto(url("#/uygulama-ekle"));
    const flow = page.getByTestId("add-flow");
    await flow.waitFor();
    assert.equal(await page.locator(".sidebar, .mobile-top, .page-head, .bottom-bar").count(), 0, "the shell gives the page the whole window");
    assert.equal(await flow.locator("h1").innerText(), "Uygulama ekle");
    assert.equal(await page.title(), "Uygulama ekle · Konsol");
    assert.equal(await flow.locator(".add-back").getAttribute("href"), "#/uygulamalar");
    assert.deepEqual(await flow.locator(".flow-steps li").allInnerTexts(), ["1\nKaynak", "2\nDenetçi", "3\nPlan", "4\nKurulum"]);
    // A settings change waiting for its confirmation stays in sight, above the page's own head.
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    push("bekleyen", { bekleyen: { id: "p1", phase: "awaiting", seconds: 45 } });
    const banner = page.locator(".pending");
    await banner.getByTestId("pending-title").waitFor();
    assert(await banner.evaluate((e) => e.getBoundingClientRect().bottom <= document.querySelector(".add-head").getBoundingClientRect().top), "above the head");
    await shot(page, "1440-light-ekle-bekleyen.png");
    push("bekleyen", { bekleyen: null });
    await banner.waitFor({ state: "detached" });
    const sources = flow.locator(".src-card");
    assert.deepEqual(await sources.evaluateAll((els) => els.map((e) => [e.dataset.kaynak, e.querySelector("strong").textContent, e.querySelector(".src-text span").textContent])), [
      ["dosya", "Dosya", "Compose ya da Kubernetes YAML: yapıştır, yükle ya da sürükle"], ["adres", "Adresten", "https ile bir Compose ya da Kubernetes dosyası"],
      ["imaj", "İmaj adından", "Obhut taslak bir dosya üretir"], ["konteyner", "Var olan konteyner", "Elle başlatılmış bir konteyner yönetime alınır"]]);
    assert.match(await flow.locator(".add-hint").innerText(), /^Uygulamanın nereden geldiğini seçin\./);
    const next = flow.locator('[data-eylem="ileri"]');
    assert.equal(await next.innerText(), "Devam");
    assert(await next.isDisabled(), "nothing chosen yet");
    await shot(page, "1440-light-ekle-kaynak.png");
    await flow.getByRole("radio", { name: /Dosya/ }).check();
    assert.equal(await next.innerText(), "Denetle");
    assert(await next.isDisabled(), "no file yet");
    // An upload is read here: too large, not UTF-8; a file dropped on the editor is read the same way.
    const input = flow.getByTestId("file-input");
    const pasteBox = flow.getByTestId("paste").getByRole("textbox", { name: "Kurulum dosyası" });
    await input.setInputFiles({ name: "buyuk.yaml", mimeType: "text/yaml", buffer: Buffer.alloc(300 * 1024, 0x61) });
    await flow.getByTestId("source-error").filter({ hasText: "buyuk.yaml çok büyük (en çok 256 KiB)." }).waitFor();
    await input.setInputFiles({ name: "ikili.yaml", mimeType: "text/yaml", buffer: Buffer.from([0x73, 0x65, 0xff, 0xfe, 0x0a]) });
    await flow.getByTestId("source-error").filter({ hasText: "ikili.yaml UTF-8 bir metin dosyası değil." }).waitFor();
    await flow.getByTestId("paste").evaluate((zone, text) => {
      const dt = new DataTransfer();
      dt.items.add(new File([text], "compose.yaml", { type: "text/yaml" }));
      zone.dispatchEvent(new DragEvent("dragover", { dataTransfer: dt, bubbles: true, cancelable: true }));
      zone.dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
    }, REFUSED_FILE);
    await waitFor(async () => (await pasteBox.inputValue()) === REFUSED_FILE, "the dropped file's text, read in the browser");
    assert.match(await flow.locator("#kurulum-dosyasi-ipucu").innerText(), /^compose\.yaml okundu\./);
    assert.equal(await flow.getByTestId("source-error").count(), 0);
    assert.equal(h.requests.filter((r) => r.method === "POST").length, 0, "nothing sent while reading");
    await shot(page, "1440-light-ekle-dosya.png");
    // Leaving with a file in the form asks first (inside Konsol too); "Devam et" keeps everything.
    await flow.getByRole("button", { name: "Vazgeç" }).click();
    const leave = page.getByRole("dialog", { name: "Uygulama ekleme bırakılsın mı?" });
    await leave.waitFor();
    assert.equal(await leave.getByTestId("close-confirm").innerText(), "Girdikleriniz silinir; uygulama kurulmaz.");
    await leave.getByRole("button", { name: "Devam et" }).click();
    await leave.waitFor({ state: "detached" });
    assert.equal(new URL(page.url()).hash, "#/uygulama-ekle", "still here");
    assert.equal(await pasteBox.inputValue(), REFUSED_FILE, "kept");

    // ================= Denetçi: the file beside the questions; a refused line stops the flow; correcting it goes on
    await next.click();
    await page.waitForFunction(() => document.querySelector("[data-testid=add-flow]")?.dataset.adim === "2");
    await flow.getByTestId("refusals").waitFor();
    assert.deepEqual(postsTo(DENETLE)[0], { metin: REFUSED_FILE }, "the first read: the file only");
    assert.equal(await flow.getByTestId("format").innerText(), "Compose");
    assert.equal(await flow.locator(".add-file .add-pane-head .wrap").innerText(), "compose.yaml (yüklenen dosya)");
    assert.equal(await flow.getByTestId("refusals").locator("li").innerText(), "Satır 5 web: privileged kullanılamaz; konteynerler ayrıcalıklı çalışmaz.");
    assert.deepEqual(await marksOf(flow), [[5, "durduruyor", "refuse"]], "the refused line marked beside it");
    assert.equal(await flow.getByTestId("questions").count(), 0, "no questions while a line stops it");
    assert.equal(await flow.getByTestId("flow-status").innerText(), "1 satır kurulumu durduruyor");
    assert(await flow.locator('[data-eylem="plan"]').isDisabled());
    // On a wide screen the page fills the window; its panes scroll on their own.
    assert(await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight + 1), "no page scroll at 1440");
    await shot(page, "1440-light-ekle-durduran.png");
    // "Satır 5" shows the line in the editor (the caret at its start).
    await flow.getByTestId("refusals").getByRole("button", { name: "Satır 5" }).click();
    const editor = flow.locator(".add-file").getByRole("textbox", { name: "Kurulum dosyası" });
    assert.equal(await editor.evaluate((t) => t === document.activeElement && t.value.slice(0, t.selectionStart).split("\n").length), 5);
    await editor.fill(ORNEK_FILE);
    await flow.getByTestId("questions").waitFor();
    await waitFor(() => lastPost(DENETLE)?.yanitlar, "checked again with the answers");
    assert(postsTo(DENETLE).some((b) => b.metin === ORNEK_FILE), "the corrected file read again");
    assert.equal(await flow.getByTestId("refusals").count(), 0);
    // The marks beside the lines: the questions' words, a note.
    assert.deepEqual(await marksOf(flow), [[1, "ad", "question"], [3, "başlatma", "question"], [5, "port · not", "question"], [6, "klasör", "question"],
      [8, "değişken", "question"], [9, "gizli değer", "question"], [10, "gizli değer", "question"], [11, "başlatma", "question"]]);
    assert.deepEqual(await flow.getByTestId("notes").locator("li").allInnerTexts(), ["Satır 5 Dosyadaki sunucu tarafı (8080) kullanılmaz; port Erişim'den açılır."]);
    // Every question, the file's variables first, then each service's under its name.
    assert.equal(await flow.getByTestId("app-name").inputValue(), "ornek", "the inspector's name");
    assert.deepEqual(await flow.locator(".q-group").evaluateAll((els) => els.map((e) => [e.dataset.grup, e.textContent])),
      [["", "Dosyanın değişkenleri"], ["web", "web"], ["db", "db"]]);
    assert.deepEqual(await questionIds(flow), ["var:TZ", "var:ADMIN_PASSWORD", "port:web:8080/tcp", "port:web:9000/udp", "port:web:5432/tcp", "mount:web:/data",
      "mount:web:/belgeler", "secret:web:API_TOKEN", "start:web", "start:db"]);
    const q = (id) => flow.locator(`[data-soru="${id}"]`);
    assert.deepEqual(await flow.locator("[data-soru] .q-title").allInnerTexts(), ["Değişken ${TZ}", "Gizli değer ${ADMIN_PASSWORD}", "8080/TCP · web", "9000/UDP · web",
      "5432/TCP · web", "Klasör /data · web", "Klasör /belgeler · web", "Gizli değer API_TOKEN · web", "web · nasıl başlasın?", "db · nasıl başlasın?"]);
    assert.equal(await flow.locator("[data-soru] .q-title").first().evaluate((e) => e.tagName), "H4", "below its group's heading");
    assert.equal(await flow.getByTestId("flow-status").innerText(), "4 soru yanıt bekliyor");
    assert.equal(await flow.getByTestId("answered").innerText(), "6/10 yanıtlandı");
    assert.deepEqual(await flow.locator(".q-need").evaluateAll((els) => els.map((e) => e.dataset.soru)),
      ["var:ADMIN_PASSWORD", "port:web:8080/tcp", "port:web:5432/tcp", "secret:web:API_TOKEN"], "the waiting ones stand out");
    // "Bekleyene git" takes the first waiting question; the question in hand lights its line in the file.
    await flow.locator('[data-eylem="bekleyene-git"]').click();
    assert(await q("var:ADMIN_PASSWORD").evaluate((e) => e.contains(document.activeElement)), "the first waiting question has the focus");
    const currentLine = () => flow.locator(".add-file .code-line").evaluateAll((els) => els.findIndex((e) => e.classList.contains("code-line-current")) + 1);
    assert.equal(await currentLine(), 9, "its line lit");
    await q("start:web").getByRole("radio", { name: /Root olarak/ }).focus();
    assert.equal(await currentLine(), 3);
    // A click on a marked line of the file shows its question (here: line 11, db's start).
    await editor.evaluate((t) => {
      t.setSelectionRange(t.value.split("\n").slice(0, 10).join("\n").length + 3, t.value.split("\n").slice(0, 10).join("\n").length + 3);
      t.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    });
    assert.equal(await currentLine(), 11);
    // The answers already given are checked; a waiting question's "Yanıt gerekli." is not shown.
    const SEEDED = { metin: ORNEK_FILE, yanitlar: { name: "ornek", answers: {
      "var:TZ": { value: "Europe/Istanbul" }, "port:web:9000/udp": { use: "raw" }, "mount:web:/data": { to: "app" },
      "mount:web:/belgeler": { to: "srv", path: "/srv/Belgeler", read_only: true }, "start:web": { mode: "root" }, "start:db": { mode: "direct" } } } };
    await waitFor(() => isDeepStrictEqual(lastPost(DENETLE), SEEDED), "the answers given so far (the file's defaults and suggestions) checked");
    assert.equal(await flow.getByTestId("q-error").count(), 0);
    // A port: nothing chosen (A1), the inspector's guess beside it.
    assert.equal(await q("port:web:8080/tcp").getByTestId("q-guess").innerText(), "Denetçinin tahmini: web arayüzü");
    assert.equal(await q("port:web:8080/tcp").locator("input[type=radio]:checked").count(), 0, "no port is chosen for the operator");
    assert.equal(await q("port:web:5432/tcp").getByTestId("q-guess").innerText(), "Denetçinin tahmini: web değil (bilinen bir servis portu)");
    assert.equal(await q("port:web:9000/udp").locator("input").count(), 0, "a UDP port is a raw port, closed");
    assert.match(await q("port:web:9000/udp").innerText(), /Ham port · kapalı gelir/);
    // A start mode: the suggestion marked, a word when the choice differs (A4).
    assert(await q("start:web").getByRole("radio", { name: /Root olarak/ }).isChecked());
    assert.equal(await q("start:web").locator('[data-secim="root"] .pill').innerText(), "Önerilen");
    assert.match(await q("start:web").locator('[data-secim="root"]').innerText(), /8 yetki açık · gerekirse kendi kullanıcısına geçer/);
    assert(await q("start:db").getByRole("radio", { name: /Doğrudan · 999:999/ }).isChecked());
    await q("start:db").getByRole("radio", { name: /Root olarak/ }).check();
    assert.equal(await q("start:db").getByTestId("q-start-note").innerText(), "Dosya kullanıcıyı belirtiyor; root başlangıcı gereksiz yetki bırakır.");
    await q("start:db").getByRole("radio", { name: /Doğrudan/ }).check();
    await q("start:db").getByTestId("q-start-note").waitFor({ state: "detached" });
    // The mounts: the application's folder, or a folder under /srv with the picker.
    assert(await q("mount:web:/data").getByRole("radio", { name: /Uygulamanın klasörü/ }).isChecked());
    assert.equal(await q("mount:web:/data").locator('[data-secim="app"] .choice-sub').innerText(), "veri");
    assert(await q("mount:web:/belgeler").getByRole("radio", { name: /\/srv altından bir klasör/ }).isChecked(), "the file's own /srv folder suggested");
    assert.equal(await q("mount:web:/belgeler").getByTestId("share-folder-value").inputValue(), "/srv/Belgeler");
    assert(await q("mount:web:/belgeler").getByTestId("q-readonly").isChecked(), "read-only as in the file");
    assert.equal(await q("mount:web:/belgeler").getByRole("button", { name: "Klasör /belgeler · web: klasör seç" }).count(), 1);
    // A variable with the file's default; a server error shows under it, and goes with a valid value.
    assert.equal(await q("var:TZ").getByTestId("q-value").inputValue(), "Europe/Istanbul");
    await q("var:TZ").getByTestId("q-value").fill("Mars/Olympus");
    await q("var:TZ").getByTestId("q-error").filter({ hasText: "Bu değer kabul edilmedi." }).waitFor();
    assert.equal(lastPost(DENETLE).yanitlar.answers["var:TZ"].value, "Mars/Olympus");
    await q("var:TZ").getByTestId("q-value").fill("Europe/Istanbul");
    await q("var:TZ").getByTestId("q-error").waitFor({ state: "detached" });
    await shot(page, "1440-light-ekle-denetci.png");
    // The ports answered: an address with the suggested Tailscale name; a name another row holds is refused at once.
    await q("port:web:8080/tcp").getByRole("radio", { name: /Adres/ }).check();
    const tsName = q("port:web:8080/tcp").getByTestId("q-name");
    assert.equal(await tsName.inputValue(), "ornek", "the inspector's suggestion");
    assert.equal(await q("port:web:8080/tcp").locator(".input-suffix").innerText(), ".ev");
    await tsName.fill("notlar");
    await q("port:web:8080/tcp").getByTestId("q-error").filter({ hasText: "notlar adı başka bir satırda kullanılıyor." }).waitFor();
    await tsName.fill("ornek");
    await q("port:web:5432/tcp").getByRole("radio", { name: /Adres/ }).check();
    assert.match(await q("port:web:5432/tcp").innerText(), /Web arayüzü değilse adres çalışmaz/);
    assert.equal(await q("port:web:5432/tcp").getByTestId("q-name").inputValue(), "", "no suggestion for a non-web port");
    await q("port:web:5432/tcp").getByRole("radio", { name: /Ham port/ }).check();
    // The secrets: a hidden value, "Rastgele üret" only where the inspector allows it, "Göster".
    const adminInput = q("var:ADMIN_PASSWORD").getByTestId("q-secret");
    assert.equal(await adminInput.getAttribute("type"), "password");
    assert.equal(await q("secret:web:API_TOKEN").locator('[data-eylem="uret"]').count(), 0, "a token is not generated");
    await q("var:ADMIN_PASSWORD").locator('[data-eylem="uret"]').click();
    const adminSecret = await adminInput.inputValue();
    assert.match(adminSecret, /^[A-Za-z0-9]{32}$/, "32 random letters and digits");
    await q("var:ADMIN_PASSWORD").getByRole("button", { name: "Değeri göster" }).click();
    assert.equal(await adminInput.getAttribute("type"), "text");
    await q("var:ADMIN_PASSWORD").getByRole("button", { name: "Değeri gizle" }).click();
    const tokenSecret = "jeton-degeri-4711";
    await q("secret:web:API_TOKEN").getByTestId("q-secret").fill(tokenSecret);
    await flow.getByTestId("flow-status").filter({ hasText: "Bütün sorular yanıtlandı" }).waitFor();
    assert.equal(await flow.getByTestId("answered").innerText(), "10/10 yanıtlandı");
    assert.equal(await flow.locator('[data-eylem="bekleyene-git"]').count(), 0, "nothing waits");
    await page.waitForFunction(() => !document.querySelector('[data-eylem="plan"]').disabled);
    const ANSWERS = { name: "ornek", answers: {
      "var:TZ": { value: "Europe/Istanbul" }, "var:ADMIN_PASSWORD": { value: adminSecret }, "port:web:8080/tcp": { use: "caddy", tailscale_name: "ornek" },
      "port:web:9000/udp": { use: "raw" }, "port:web:5432/tcp": { use: "raw" }, "mount:web:/data": { to: "app" },
      "mount:web:/belgeler": { to: "srv", path: "/srv/Belgeler", read_only: true }, "secret:web:API_TOKEN": { value: tokenSecret },
      "start:web": { mode: "root" }, "start:db": { mode: "direct" } } };
    await waitFor(() => isDeepStrictEqual(lastPost(DENETLE), { metin: ORNEK_FILE, yanitlar: ANSWERS }), "every answer checked");
    await noSecrets(page, [adminSecret, tokenSecret], "Denetçi");
    // Another /srv folder from the picker (hidden folders are never offered).
    await q("mount:web:/belgeler").getByTestId("share-folder-toggle").click();
    const panel = q("mount:web:/belgeler").getByTestId("share-folder-panel");
    await panel.locator("[data-klasor]").first().waitFor();
    assert.deepEqual(await panel.locator("[data-klasor]").evaluateAll((els) => els.map((e) => e.dataset.klasor)), ["Belgeler", "Filmler"]);
    await panel.getByRole("button", { name: "Filmler seç" }).click();
    assert.equal(await q("mount:web:/belgeler").getByTestId("share-folder-value").inputValue(), "/srv/Filmler");
    await waitFor(() => lastPost(DENETLE).yanitlar.answers["mount:web:/belgeler"].path === "/srv/Filmler", "the folder checked");
    await shot(page, "1440-light-ekle-yanitlar.png");

    // ================= Plan: a refusal leads back to its question; then what the install creates, in its order
    await page.waitForFunction(() => !document.querySelector('[data-eylem="plan"]').disabled);
    await flow.locator('[data-eylem="plan"]').click();
    const problems = flow.getByTestId("plan-problems");
    await problems.waitFor();
    const filmler = { ...ANSWERS, answers: { ...ANSWERS.answers, "mount:web:/belgeler": { to: "srv", path: "/srv/Filmler", read_only: true } } };
    assert.deepEqual(lastPost(KUR), { metin: ORNEK_FILE, yanitlar: filmler, kaynak: { tur: "dosya" }, plan: true });
    assert.deepEqual(await problems.locator("li").evaluateAll((els) => els.map((e) => [e.dataset.hata, e.querySelector("span").textContent, Boolean(e.querySelector("button"))])), [
      ["mount:web:/belgeler", "Klasör /belgeler · web: Klasör yok: /srv/Filmler", true], ["podman", "Podman: Bu dosya Podman 5 gerekir; bu sunucuda 4.9.", false]]);
    assert(await flow.locator('[data-eylem="kur"]').isDisabled(), "nothing to install while the plan refuses");
    assert.equal(await flow.getByTestId("flow-status").innerText(), "Kurulum yapılamaz");
    assert.deepEqual(await flow.locator(".flow-steps li").evaluateAll((els) => els.map((e) => e.getAttribute("aria-current"))), [null, null, "step", null]);
    await shot(page, "1440-light-ekle-plan-engel.png");
    await problems.getByRole("button", { name: "Soruya git" }).click();
    await page.waitForFunction(() => document.querySelector("[data-testid=add-flow]")?.dataset.adim === "2");
    assert.equal(await q("mount:web:/belgeler").getByTestId("q-error").innerText(), "Klasör yok: /srv/Filmler", "the refusal beside its question");
    assert(await q("mount:web:/belgeler").evaluate((e) => e.contains(document.activeElement)), "the question has the focus");
    assert(await flow.locator('[data-eylem="plan"]').isDisabled(), "not again before the answer changes");
    await q("mount:web:/belgeler").getByTestId("share-folder-toggle").click();
    await q("mount:web:/belgeler").locator('[data-klasor="Belgeler"]').waitFor();
    await q("mount:web:/belgeler").getByRole("button", { name: "Belgeler seç" }).click();
    await q("mount:web:/belgeler").getByTestId("q-error").waitFor({ state: "detached" });
    await page.waitForFunction(() => !document.querySelector('[data-eylem="plan"]').disabled);
    await flow.locator('[data-eylem="plan"]').click();
    const boxes = flow.getByTestId("plan-boxes");
    await boxes.waitFor();
    assert.deepEqual(lastPost(KUR), { metin: ORNEK_FILE, yanitlar: ANSWERS, kaynak: { tur: "dosya" }, plan: true });
    assert.deepEqual(await boxes.locator("[data-kutu]").evaluateAll((els) => els.map((e) => [e.querySelector("dt").textContent, [...e.querySelectorAll("dd")].map((d) => d.textContent)])), [
      ["Uygulama", ["ornek · 2 servis", "ksl-ornek"]], ["Adresler", ["http://ornek.ev"]], ["Ham portlar", ["web · 9000/UDP · kapalı", "web · 5432/TCP · kapalı"]],
      ["Klasörler", ["/var/lib/master-stack/uygulamalar/ornek/veri", "/srv/Belgeler · salt okunur"]],
      ["Gizli değerler", ["2 · Podman secret", "ornek-admin-password", "ornek-api-token"]], ["Başlatma", ["web: root olarak", "db: doğrudan 999:999"]],
      ["İmajlar", ["registry.example/ornek/web:1.2", "registry.example/ornek/db:16"]]]);
    assert.deepEqual(await flow.getByTestId("plan-units").locator("li").allInnerTexts(), PLAN.birimler);
    assert.equal(await flow.getByTestId("plan-warnings").locator("li").innerText(), "web: " + ROOT_WARNING);
    assert.equal(await flow.locator(".add-order li").count(), 7, "the install's order beside the plan");
    assert.equal(await flow.getByTestId("flow-status").innerText(), "Bütün denetimler geçti");
    assert(await flow.locator('[data-eylem="kur"]').isEnabled());
    await shot(page, "1440-light-ekle-plan.png");

    // ================= Kurulum: the job's log as it grows; a finished install stays until the operator moves on
    installReads = [installJob("ornek", { step: "Doğrulanıyor", gunluk: OK_LOG.slice(0, 2) }), installJob("ornek", { step: "Başlatılıyor: konsol-ornek_web.service", gunluk: OK_LOG.slice(0, 5) })];
    await flow.locator('[data-eylem="kur"]').click();
    await waitFor(() => postsTo(KUR).length === 3, "install posted");
    assert.deepEqual(lastPost(KUR), { metin: ORNEK_FILE, yanitlar: ANSWERS, kaynak: { tur: "dosya" } }, "the same body, without plan");
    await page.waitForFunction(() => document.querySelector("[data-testid=add-flow]")?.dataset.adim === "4");
    const status = flow.getByTestId("install-status");
    await status.filter({ hasText: "Başlatılıyor: konsol-ornek_web.service" }).waitFor();
    assert.equal(await status.getAttribute("data-durum"), "calisiyor");
    assert.equal(await flow.locator(".add-result .add-pane-title").innerText(), "ornek");
    const log = flow.getByTestId("job-log");
    assert.deepEqual(await log.locator("li").evaluateAll((els) => els.map((e) => [e.dataset.tur, e.querySelector(".job-text").textContent])),
      OK_LOG.slice(0, 5).map((l) => [l.tur, l.ileti]));
    assert.match(await log.locator("li").first().locator(".job-time").innerText(), /^\d\d:\d\d:\d\d$/);
    assert.equal(await flow.getByTestId("flow-status").innerText(), "Ayrılırsanız kurulum sürer; İşlemler'den izlenir.");
    assert.deepEqual(await flow.locator(".add-bar button").allInnerTexts(), ["Uygulamalar'a dön"], "no way back while it runs");
    await noSecrets(page, [adminSecret, tokenSecret], "install");
    await shot(page, "1440-light-ekle-kuruluyor.png");
    data.uygulamalar = uygulamalar([...apps(), uygulama("ornek", { servisler: [servis("web"), servis("db")] })]);
    installReads = [installJob("ornek", { state: "done", step: "Tamamlandı", gunluk: OK_LOG, finished_at: 1791845208, result: { ok: true, ad: "ornek" } })];
    await status.filter({ hasText: "ornek kuruldu" }).waitFor();
    assert.equal(await status.getAttribute("data-durum"), "tamam");
    assert.equal(await log.locator("li").count(), OK_LOG.length);
    assert.equal(await log.locator("li").last().getAttribute("data-tur"), "tamam");
    assert.equal(await flow.getByTestId("install-elapsed").innerText(), "8 sn");
    assert.deepEqual(await flow.locator(".flow-steps li").evaluateAll((els) => els.map((e) => e.classList.contains("flow-step-done"))), [true, true, true, true]);
    await page.waitForTimeout(1200);
    assert.equal(new URL(page.url()).hash, "#/uygulama-ekle", "a finished install stays on its log");
    await flow.locator('[data-eylem="kopyala"]').click();
    await log.locator("..").locator('[role="status"]').filter({ hasText: /Kopyala(ndı|namadı)/ }).waitFor();
    await shot(page, "1440-light-ekle-kuruldu.png");
    await flow.locator('[data-eylem="uygulamaya-git"]').click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar/ornek");
    await page.locator("main h1").filter({ hasText: "ornek" }).waitFor();
    assert.equal(await page.locator(".sidebar").count(), 1, "the shell is back");
    await noSecrets(page, [adminSecret, tokenSecret], "the new application's page");
    await page.context().close();
    data.uygulamalar = uygulamalar(apps(), { kaynaklar: [{ ad: "eski-redis", imaj: "registry.example/redis:7", durum: "running" }] });

    // ================= a failed install: why, the container's own lines, back to the question it names; leaving asks
    page = await newPage();
    await page.goto(url("#/uygulamalar"));
    await page.locator('.apps-toolbar [data-eylem="ekle"]').click();
    await page.waitForURL((u) => u.hash === "#/uygulama-ekle");
    const flow2 = page.getByTestId("add-flow");
    await flow2.getByRole("radio", { name: /Dosya/ }).check();
    await flow2.getByTestId("paste").getByRole("textbox").fill(ADRES_FILE);
    await flow2.locator('[data-eylem="ileri"]').click();
    const q2 = (id) => flow2.locator(`[data-soru="${id}"]`);
    await q2("port:pano:3000/tcp").getByRole("radio", { name: /Ham port/ }).check();
    await q2("start:pano").getByRole("radio", { name: /Doğrudan/ }).check();
    await page.waitForFunction(() => !document.querySelector('[data-eylem="plan"]').disabled);
    await flow2.locator('[data-eylem="plan"]').click();
    await flow2.getByTestId("plan-boxes").waitFor();
    installReads = [installJob("pano", { step: "Hazır olması bekleniyor", gunluk: FAIL_LOG.slice(0, 3) }),
      installJob("pano", { state: "failed", step: "Başarısız", error: PANO_ERROR, failed_step: "Hazır olması bekleniyor", soru: "start:pano", status: 502,
        gunluk: FAIL_LOG, finished_at: 1791845216 })];
    await flow2.locator('[data-eylem="kur"]').click();
    await waitFor(() => !lastPost(KUR).plan, "install posted");
    const status2 = flow2.getByTestId("install-status");
    await status2.filter({ hasText: "Kurulum yapılamadı" }).waitFor();
    assert.equal(await status2.getAttribute("data-durum"), "hata");
    assert.equal(await status2.getAttribute("role"), "alert");
    assert.equal(await flow2.getByTestId("install-error").innerText(), PANO_ERROR, "the job's own words, once");
    assert.equal(await flow2.getByTestId("install-blame").innerText(), "İlgili soru: pano · nasıl başlasın?");
    const log2 = flow2.getByTestId("job-log");
    assert.deepEqual(await log2.locator("li").evaluateAll((els) => els.map((e) => e.dataset.tur)), FAIL_LOG.map((l) => l.tur));
    assert.equal(await log2.locator('li[data-tur="cikti"] .job-text').first().textContent(), "Konteyner: preinit: fatal: /run belongs to uid 0 instead of 1000",
      "a container's own line, named for a screen reader");
    assert.equal(await flow2.getByTestId("flow-status").innerText(), "Yanıtlarınız duruyor; düzeltip yeniden kurabilirsiniz.");
    assert.equal(await flow2.getByTestId("install-elapsed").innerText(), "16 sn");
    await shot(page, "1440-light-ekle-hata.png");
    // Back to the start question with every answer kept; root this time.
    await flow2.getByRole("button", { name: "Başlatma sorusuna dön" }).click();
    await page.waitForFunction(() => document.querySelector("[data-testid=add-flow]")?.dataset.adim === "2");
    assert(await q2("start:pano").evaluate((e) => e.contains(document.activeElement)), "the question the job names has the focus");
    assert(await q2("port:pano:3000/tcp").getByRole("radio", { name: /Ham port/ }).isChecked(), "the answers stay");
    await q2("start:pano").getByRole("radio", { name: /Root olarak/ }).check();
    await page.waitForFunction(() => !document.querySelector('[data-eylem="plan"]').disabled);
    await flow2.locator('[data-eylem="plan"]').click();
    await flow2.getByTestId("plan-boxes").waitFor();
    assert.deepEqual(lastPost(KUR).yanitlar.answers["start:pano"], { mode: "root" });
    // Leaving after a failure asks; "Bırak" leaves, and the page starts afresh.
    await flow2.getByRole("button", { name: "Kapat" }).first().click();
    const leave2 = page.getByRole("dialog", { name: "Uygulama ekleme bırakılsın mı?" });
    await leave2.getByRole("button", { name: "Bırak" }).click();
    await page.waitForURL((u) => u.hash === "#/uygulamalar");
    await page.locator('.apps-toolbar [data-eylem="ekle"]').click();
    await flow2.waitFor();
    assert.equal(await flow2.locator("input[type=radio]:checked").count(), 0, "a fresh start: nothing kept");
    await page.context().close();

    // ================= Adresten: https only; a server error in its words; the draft inspected; its kaynak in the plan
    page = await newPage();
    await page.goto(url("#/uygulama-ekle"));
    const flow3 = page.getByTestId("add-flow");
    await flow3.getByRole("radio", { name: /Adresten/ }).check();
    const urlField = flow3.getByTestId("src-url");
    assert.equal(await urlField.getAttribute("placeholder"), "https://depo.example.org/compose.yaml");
    await urlField.fill("http://files.example.org/ornek/compose.yaml");
    await flow3.locator('[data-eylem="ileri"]').click();
    await flow3.getByTestId("source-error").filter({ hasText: "Adres https ile başlamalı." }).waitFor();
    assert.equal(postsTo(KAYNAK).length, 0, "refused before asking the server");
    expectedFailures = [KAYNAK];
    await urlField.fill("https://bos.example.org/compose.yaml");
    assert.equal(await flow3.locator('[data-eylem="ileri"]').innerText(), "İndir ve denetle");
    await flow3.locator('[data-eylem="ileri"]').click();
    await flow3.getByTestId("source-error").filter({ hasText: "Adres indirilemedi: bağlantı kurulamadı." }).waitFor();
    expectedFailures = [];
    await urlField.fill(ADRES);
    await urlField.press("Enter");
    await flow3.getByTestId("questions").waitFor();
    assert.deepEqual(lastPost(KAYNAK), { tur: "adres", adres: ADRES });
    assert.equal(await flow3.locator(".add-file .add-pane-head .wrap").innerText(), ADRES);
    assert.equal(await flow3.locator(".add-file").getByRole("textbox", { name: "Kurulum dosyası" }).inputValue(), ADRES_FILE);
    await flow3.locator('[data-soru="port:pano:3000/tcp"]').getByRole("radio", { name: /Adres/ }).check();
    await page.waitForFunction(() => !document.querySelector('[data-eylem="plan"]').disabled);
    await flow3.locator('[data-eylem="plan"]').click();
    await flow3.getByTestId("plan-boxes").waitFor();
    assert.deepEqual(lastPost(KUR), { metin: ADRES_FILE, yanitlar: { name: "pano", answers: { "port:pano:3000/tcp": { use: "caddy", tailscale_name: "pano" },
      "start:pano": { mode: "root" } } }, kaynak: { tur: "adres", adres: ADRES }, plan: true }, "the source travels with the file");
    // Geri goes back step by step.
    await flow3.getByRole("button", { name: "Geri" }).click();
    await flow3.getByTestId("questions").waitFor();
    await flow3.getByRole("button", { name: "Geri" }).click();
    await page.waitForFunction(() => document.querySelector("[data-testid=add-flow]")?.dataset.adim === "1");
    assert.equal(await urlField.inputValue(), ADRES, "the address is kept while the page is open");
    await page.context().close();

    // ================= İmaj adından: a job; its log here; its result is the draft
    page = await newPage();
    await page.goto(url("#/uygulama-ekle"));
    const flow4 = page.getByTestId("add-flow");
    await flow4.getByRole("radio", { name: /İmaj adından/ }).check();
    await flow4.getByTestId("src-image").fill(IMAGE);
    assert.equal(await flow4.locator('[data-eylem="ileri"]').innerText(), "Taslak üret");
    imageReads = 0;
    await flow4.locator('[data-eylem="ileri"]').click();
    await flow4.getByTestId("draft-progress").getByTestId("job-log").locator("li").filter({ hasText: `İmaj indiriliyor: ${IMAGE}` }).waitFor();
    assert.deepEqual(lastPost(KAYNAK), { tur: "imaj", imaj: IMAGE });
    assert.equal(await flow4.locator('[data-eylem="ileri"]').innerText(), "Taslak üretiliyor…");
    assert(await flow4.getByTestId("src-image").isDisabled());
    await shot(page, "1440-light-ekle-imaj.png");
    await flow4.getByTestId("questions").waitFor({ timeout: 8000 });
    assert(imageReads >= 3, "the job's record read until it ended");
    assert.equal(await flow4.locator(".add-file .add-pane-head .wrap").innerText(), `İmaj adından taslak · ${IMAGE}`);
    assert.equal(await flow4.locator(".add-file").getByRole("textbox", { name: "Kurulum dosyası" }).inputValue(), IMAGE_FILE);
    await page.context().close();

    // ================= Var olan konteyner: the standalone containers; the draft from one
    page = await newPage();
    await page.goto(url("#/uygulama-ekle"));
    const flow5 = page.getByTestId("add-flow");
    await flow5.getByRole("radio", { name: /Var olan konteyner/ }).check();
    const containers = flow5.getByTestId("src-containers");
    await containers.waitFor();
    assert.equal(await containers.locator(".choice-item").innerText(), "eski-redis\nrunning\nregistry.example/redis:7");
    assert(await flow5.locator('[data-eylem="ileri"]').isDisabled());
    await containers.getByRole("radio", { name: /eski-redis/ }).check();
    assert.equal(await flow5.locator('[data-eylem="ileri"]').innerText(), "Dosyaya çevir");
    await shot(page, "1440-light-ekle-konteyner.png");
    await flow5.locator('[data-eylem="ileri"]').click();
    await flow5.getByTestId("questions").waitFor();
    assert.deepEqual(lastPost(KAYNAK), { tur: "konteyner", konteyner: "eski-redis" });
    assert.equal(await flow5.locator(".add-file .add-pane-head .wrap").innerText(), "eski-redis konteynerinden taslak");
    await page.context().close();
    // No standalone container: it says so.
    data.uygulamalar = uygulamalar(apps());
    page = await newPage();
    await page.goto(url("#/uygulama-ekle"));
    await page.getByTestId("add-flow").getByRole("radio", { name: /Var olan konteyner/ }).check();
    await page.getByTestId("src-containers-empty").filter({ hasText: "Elle başlatılmış, Obhut'un yönetmediği bir konteyner yok." }).waitFor();
    await page.context().close();

    // ================= Tanım: edit the file and the answers; the plan's difference; apply as a job
    const TANIM = "/api/konsol/uygulamalar/notlar/tanim";
    page = await newPage();
    await page.goto(url("#/uygulamalar/notlar?sekme=tanim"));
    const definition = page.locator(".definition-tab");
    await definition.getByTestId("source").waitFor();
    await definition.locator('[data-eylem="duzenle"]').click();
    const edit = definition.getByTestId("definition-edit");
    await edit.getByTestId("edit-answers").waitFor();
    assert.equal(await edit.getByRole("textbox", { name: "Kurulum dosyası" }).inputValue(), NOTLAR_FILE);
    const eq = (id) => edit.locator(`[data-soru="${id}"]`);
    assert.deepEqual(await questionIds(edit), ["var:TZ", "var:DB_PASSWORD", "port:web:8080/tcp", "port:web:9000/udp", "mount:web:/data", "start:web"]);
    // A port that stays: its use is its row's, changed in Erişim → Adresler.
    assert.equal(await eq("port:web:8080/tcp").getByTestId("q-stay").innerText(), "Adres · notlar.ev");
    assert.equal(await eq("port:web:8080/tcp").getByTestId("q-stay-link").getAttribute("href"), "#/erisim?sekme=adresler&satir=uygulama%3Anotlar%3Aweb%3A8080%2Ftcp");
    assert.equal(await eq("port:web:8080/tcp").locator("input").count(), 0, "not editable here");
    assert.equal(await eq("port:web:9000/udp").getByTestId("q-stay").innerText(), "Ham port · Kapalı");
    // A stored secret is "Kayıtlı" and kept; the other answers as stored.
    assert.equal(await eq("var:DB_PASSWORD").getByTestId("q-kept").locator(".pill").innerText(), "Kayıtlı");
    assert.equal(await eq("var:DB_PASSWORD").getByTestId("q-secret").count(), 0, "no value is shown or asked for");
    assert.equal(await eq("var:TZ").getByTestId("q-value").inputValue(), "Europe/Istanbul");
    assert(await eq("start:web").getByRole("radio", { name: /Root olarak/ }).isChecked());
    assert.equal(await edit.getByTestId("edit-status").innerText(), "Bütün sorular yanıtlandı");
    await shot(page, "1440-light-tanim-duzenle.png", true);
    // Nothing changed: the plan says so and Uygula waits.
    await edit.locator('[data-eylem="incele"]').click();
    const diffSheet = page.getByRole("dialog", { name: "notlar · Tanım değişikliği" });
    await diffSheet.getByTestId("diff-none").waitFor();
    assert.deepEqual(lastPost(TANIM), { metin: NOTLAR_FILE, yanitlar: { name: "notlar", answers: { "var:TZ": { value: "Europe/Istanbul" }, "var:DB_PASSWORD": { keep: true },
      "mount:web:/data": { to: "app" }, "start:web": { mode: "root" } } }, revizyon: "rev-notlar-3", plan: true }, "a kept secret, no staying port's answer");
    assert(await diffSheet.locator('[data-eylem="uygula"]').isDisabled());
    await diffSheet.getByRole("button", { name: "Vazgeç" }).click();
    await diffSheet.waitFor({ state: "detached" });
    // A new port in the file is asked for (A1); a renewed secret; another start mode.
    await edit.getByRole("textbox", { name: "Kurulum dosyası" }).fill(NOTLAR_NEW);
    await eq("port:web:7000/tcp").waitFor();
    assert.deepEqual(postsTo(DENETLE).at(-1), { metin: NOTLAR_NEW }, "the edited file inspected (its text only)");
    assert.equal(await eq("port:web:7000/tcp").locator("input[type=radio]:checked").count(), 0);
    assert.equal(await edit.getByTestId("edit-status").innerText(), "1 soru yanıt bekliyor");
    assert(await edit.locator('[data-eylem="incele"]').isDisabled());
    await eq("port:web:7000/tcp").getByRole("radio", { name: /Ham port/ }).check();
    await eq("var:DB_PASSWORD").locator('[data-eylem="yenile"]').click();
    await eq("var:DB_PASSWORD").locator('[data-eylem="uret"]').click();
    const renewed = await eq("var:DB_PASSWORD").getByTestId("q-secret").inputValue();
    assert.match(renewed, /^[A-Za-z0-9]{32}$/);
    await eq("start:web").getByRole("radio", { name: /Doğrudan/ }).check();
    // A refusal of the plan goes to its question.
    await eq("var:TZ").getByTestId("q-value").fill("Mars/Olympus");
    await edit.locator('[data-eylem="incele"]').click();
    await edit.getByTestId("plan-problems").waitFor();
    assert.equal(await edit.getByTestId("plan-problems").locator("li span").innerText(), "Değişken ${TZ}: Bu değer kabul edilmedi.");
    assert.equal(await eq("var:TZ").getByTestId("q-error").innerText(), "Bu değer kabul edilmedi.");
    await edit.getByTestId("plan-problems").getByRole("button", { name: "Soruya git" }).click();
    assert(await eq("var:TZ").getByTestId("q-value").evaluate((e) => e === document.activeElement), "the question has the focus");
    await eq("var:TZ").getByTestId("q-value").fill("Europe/Istanbul");
    await eq("var:TZ").getByTestId("q-error").waitFor({ state: "detached" });
    await noSecrets(page, [renewed], "Tanım");
    await edit.locator('[data-eylem="incele"]').click();
    await diffSheet.getByTestId("diff").waitFor();
    const EDIT_BODY = { metin: NOTLAR_NEW, yanitlar: { name: "notlar", answers: { "var:TZ": { value: "Europe/Istanbul" }, "var:DB_PASSWORD": { value: renewed },
      "port:web:7000/tcp": { use: "raw" }, "mount:web:/data": { to: "app" }, "start:web": { mode: "direct" } } }, revizyon: "rev-notlar-3" };
    assert.deepEqual(lastPost(TANIM), { ...EDIT_BODY, plan: true });
    assert.deepEqual(await diffSheet.locator("[data-fark]").evaluateAll((els) => els.map((e) => [e.dataset.fark, e.innerText.replace(/\s+/g, " ").trim()])), [
      ["birimler", "Birimler Değişir konsol-notlar_web.container"], ["ortam", "Ortam değişkenleri Değişir web"],
      ["portlar", "Portlar Eklenir 7000/TCP · web 2 port aynı kalır; kullanımları Erişim'dedir."], ["gizliler", "Gizli değerler Yenilenir notlar-db-password"],
      ["baslangic", "Başlatma Değişir web root olarak → doğrudan"]]);
    assert.equal(await diffSheet.getByTestId("diff-warnings").innerText(), "web: " + ROOT_WARNING);
    assert.equal(await diffSheet.getByTestId("diff-restart").innerText(), "Uygulama yeniden başlar; açılmazsa önceki tanıma dönülür.");
    await shot(page, "1440-light-tanim-fark.png");
    await diffSheet.locator('[data-eylem="uygula"]').click();
    await diffSheet.waitFor({ state: "detached" });
    assert.deepEqual(lastPost(TANIM), { ...EDIT_BODY, plan: false }, "the same body, applied");
    await page.getByTestId("action-note").filter({ hasText: "Tanım uygulanıyor; ilerlemesi İşlemler'de görünür." }).waitFor();
    await waitFor(() => h.stream.clients.size === 1, "event stream");
    push("islemler", { items: [job({ id: JOB(70), ad: "notlar · Tanım değişikliği", adim: "Birimler yazılıyor" })] });
    await page.waitForTimeout(150);
    const detailReads = h.requests.filter((r) => r.method === "GET" && r.path === "/api/konsol/uygulamalar/notlar").length;
    push("islemler", { items: [job({ id: JOB(70), ad: "notlar · Tanım değişikliği", durum: "tamam", bitis: 1791845400 })] });
    await definition.getByTestId("source").waitFor();
    assert.equal(await page.getByTestId("definition-edit").count(), 0, "back to the definition as it is");
    await page.getByTestId("action-note").filter({ hasText: "notlar: tanım uygulandı." }).waitFor();
    await waitFor(() => h.requests.filter((r) => r.method === "GET" && r.path === "/api/konsol/uygulamalar/notlar").length > detailReads, "read again");
    await noSecrets(page, [renewed], "after the apply");
    await page.context().close();

    // ================= Kaynaktan yenile: the address's new text, its new question marked; unchanged says so
    page = await newPage();
    await page.goto(url("#/uygulamalar/pano?sekme=tanim"));
    const panoDef = page.locator(".definition-tab");
    await panoDef.locator('[data-eylem="kaynaktan-yenile"]').click();
    const panoEdit = panoDef.getByTestId("definition-edit");
    await panoEdit.getByTestId("edit-answers").waitFor();
    assert.deepEqual(postsTo("/api/konsol/uygulamalar/pano/yenile"), [{}]);
    assert.equal(await panoEdit.getByRole("textbox", { name: "Kurulum dosyası" }).inputValue(), PANO_NEW);
    assert.match(await panoEdit.getByTestId("refreshed").innerText(), /Kaynaktan yeni metin alındı: https:\/\/files\.example\.org\/pano\/compose\.yaml\. 1 yeni soru var; işaretli\./);
    assert.equal(await panoEdit.locator('[data-soru="port:web:3001/tcp"] .q-meta .pill').innerText(), "Yeni");
    assert.equal(await panoEdit.locator('[data-soru="port:web:3000/tcp"] .q-meta .pill').count(), 0);
    assert.equal(await panoEdit.locator('[data-soru="port:web:3000/tcp"]').getByTestId("q-stay").innerText(), "Adres · pano.ev");
    await shot(page, "1440-light-tanim-yenile.png", true);
    await panoEdit.locator('[data-eylem="vazgec"]').click();
    panoSource = PANO_FILE;
    await panoDef.locator('[data-eylem="kaynaktan-yenile"]').click();
    await panoDef.getByTestId("definition-note").filter({ hasText: "Kaynakta değişiklik yok; dosya son okumadan beri aynı." }).waitFor();
    assert.equal(await page.getByTestId("definition-edit").count(), 0);
    panoSource = PANO_NEW;
    await page.context().close();

    // ================= 1440, 390 and 320 in both themes: each step of the page, the edit
    data.uygulamalar = uygulamalar(apps(), { kaynaklar: [{ ad: "eski-redis", imaj: "registry.example/redis:7", durum: "running" }] });
    for (const colorScheme of ["light", "dark"]) {
      for (const [width, height] of [[1440, 900], [390, 844], [320, 640]]) {
        const phone = width < 768;
        page = await newPage({ colorScheme, viewport: { width, height }, ...(phone ? { isMobile: true, hasTouch: true, reducedMotion: "reduce" } : {}) });
        await page.goto(url("#/uygulama-ekle"));
        const s = page.getByTestId("add-flow");
        await s.waitFor();
        await s.getByRole("radio", { name: /Dosya/ }).check({ force: true });
        await s.getByTestId("paste").getByRole("textbox").fill(ORNEK_FILE);
        assert(await noHorizontalScroll(page), `${width} ${colorScheme} kaynak`);
        await shot(page, `${width}-${colorScheme}-ekle-kaynak.png`);
        await s.locator('[data-eylem="ileri"]').click();
        await s.getByTestId("questions").waitFor();
        // On a phone one pane at a time: the questions first, the file a tap away.
        assert.equal(await s.locator(".add-switch").isVisible(), phone, "the pane switch only on a phone");
        await s.locator('[data-soru="port:web:8080/tcp"]').getByRole("radio", { name: /Adres/ }).check({ force: true });
        await s.locator('[data-soru="port:web:5432/tcp"]').getByRole("radio", { name: /Ham port/ }).check({ force: true });
        await s.locator('[data-soru="var:ADMIN_PASSWORD"] [data-eylem="uret"]').click();
        await s.locator('[data-soru="secret:web:API_TOKEN"]').getByTestId("q-secret").fill("jeton");
        await noStyles(page, `${width} ${colorScheme} denetçi`);
        assert(await noHorizontalScroll(page), `${width} ${colorScheme} denetçi`);
        await shot(page, `${width}-${colorScheme}-ekle-denetci.png`);
        if (phone) {
          assert(!(await s.locator(".add-file").isVisible()), "the file waits behind its switch");
          await s.locator('[data-bolme-sec="dosya"]').click();
          await s.locator(".add-file").getByRole("textbox", { name: "Kurulum dosyası" }).waitFor();
          assert(!(await s.getByTestId("questions").isVisible()));
          assert(await noHorizontalScroll(page), `${width} ${colorScheme} dosya`);
          await shot(page, `${width}-${colorScheme}-ekle-dosya-bolme.png`);
          await s.locator('[data-bolme-sec="sorular"]').click();
        }
        await page.waitForFunction(() => !document.querySelector('[data-eylem="plan"]').disabled);
        await s.locator('[data-eylem="plan"]').click();
        await s.getByTestId("plan-boxes").waitFor();
        assert(await noHorizontalScroll(page), `${width} ${colorScheme} plan`);
        await shot(page, `${width}-${colorScheme}-ekle-plan.png`);
        // The bar of actions stays in sight at the bottom of the window.
        const bar = await s.locator(".add-bar").boundingBox();
        assert(Math.abs(bar.y + bar.height - height) <= 1 && Math.abs(bar.width - width) <= 1, `${width}: the bar at the window's bottom`);
        installReads = [installJob("ornek", { state: "failed", step: "Başarısız", error: PANO_ERROR, soru: "start:web", gunluk: FAIL_LOG, finished_at: 1791845216 })];
        await s.locator('[data-eylem="kur"]').click();
        await s.getByTestId("install-status").filter({ hasText: "Kurulum yapılamadı" }).waitFor();
        assert(await noHorizontalScroll(page), `${width} ${colorScheme} kurulum`);
        await shot(page, `${width}-${colorScheme}-ekle-kurulum.png`);
        installReads = [installJob("ornek", { state: "done", step: "Tamamlandı", gunluk: OK_LOG, finished_at: 1791845208 })];
        await s.getByRole("button", { name: "Başlatma sorusuna dön" }).click();
        await s.getByTestId("questions").waitFor();
        await s.locator('[data-eylem="plan"]').click();
        await s.getByTestId("plan-boxes").waitFor();
        await s.locator('[data-eylem="kur"]').click();
        await s.getByTestId("install-status").filter({ hasText: "ornek kuruldu" }).waitFor();
        await shot(page, `${width}-${colorScheme}-ekle-kuruldu.png`);
        await page.goto(url("#/uygulamalar/notlar?sekme=tanim"));
        await page.locator('.definition-tab [data-eylem="duzenle"]').click();
        await page.getByTestId("edit-answers").waitFor();
        await page.getByTestId("definition-edit").getByRole("textbox", { name: "Kurulum dosyası" }).fill(NOTLAR_NEW);
        await page.locator('[data-soru="port:web:7000/tcp"]').waitFor();
        await noStyles(page, `${width} ${colorScheme} tanım`);
        assert(await noHorizontalScroll(page), `${width} ${colorScheme} tanım`);
        await shot(page, `${width}-${colorScheme}-tanim-duzenle.png`, true);
        await page.locator('[data-soru="port:web:7000/tcp"]').getByRole("radio", { name: /Ham port/ }).check({ force: true });
        await page.locator('[data-eylem="incele"]').click();
        await page.getByRole("dialog", { name: "notlar · Tanım değişikliği" }).getByTestId("diff").waitFor();
        await shot(page, `${width}-${colorScheme}-tanim-fark.png`);
        await page.context().close();
      }
    }

    assert.deepEqual(h.errors, []);
    console.log("PASS: Konsol's Uygulama ekle (a full-window page, #/uygulama-ekle) and Tanım under the production CSP — the shell giving " +
      "the page the window, the four sources (a pasted file, an upload and a drop read in the browser with their size and UTF-8 checks, an https " +
      "address with its refusal and a server error, an image name as a job with its log, an existing container and none), leaving with input " +
      "asking first, Denetçi (the file beside the questions with no page scroll at 1440, a refused line stopping the flow and corrected in the " +
      "editor, the marks, notes, the questions grouped by service, Bekleyene git, the question in hand lighting its line and a click on a line " +
      "showing its question, every question kind: name, TCP ports with nothing chosen and the guess, a UDP port, a variable with its default and " +
      "a server error, a generated and a typed secret, Göster, the app folder and a /srv folder from the picker, start modes with the suggestion " +
      "and a word; answers checked again, waiting ones left out, a taken Tailscale name refused at once), Plan (exact body, a refusal mapped back " +
      "to its question and a part, what the install creates and its order), Kurulum (exact body without plan, the job's log as it grows, a " +
      "finished install staying until Uygulamaya git, a failed one with its words, the container's lines and the way back to the question it " +
      "names with every answer kept), Tanım (staying ports read-only with their link, a kept and a renewed secret, a new port asked for, a plan " +
      "refusal mapped to its question, the difference, apply as a job and the view again), Kaynaktan yenile (new text, the new question marked; " +
      "unchanged), no secret in an address, storage or GET request, 1440/390/320 in light and dark with the phone's pane switch and the bar at the " +
      "window's bottom. Screenshots: " + h.shots);
  } finally {
    await h.stop();
  }
})().catch((err) => {
  console.error(err);
  console.error("Screenshots: " + h.shots);
  process.exit(1);
});
