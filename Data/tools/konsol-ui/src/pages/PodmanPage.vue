<!-- Podman (DD-289; DD-211, K8): the base's container runtime on one page, read-only but for its one write, the
     removal of what nothing uses. Four summaries: the runtime, the containers (how many run, how many are
     unhealthy, whose they are), their CPU and memory against the server's, and what each kind takes on disk as
     `podman system df` counts it. Then every container (GET /api/konsol/konteynerler/liste) with its state, image,
     resources, uptime and published ports, filtered in the address (?suzgec=): an application's leads to its page,
     one Obhut does not manage says who does (Podman alone, an application's labels without a record, another
     manager). Then the images (one row per ID with every name), volumes, networks and the folders removed
     applications left, in tabs (?kaynak=): what nothing uses (GET …/gelismis/temizlik) carries "Kullanılmayan" and
     a tick; "Seçilenleri kaldır…" names every chosen item and asks for the typed word, then POST
     …/gelismis/temizlik starts one job, followed here and in İşlemler: its end says what went, or what stayed and
     why (each item is checked again right before it goes). A collection that could not be read says so instead of
     looking empty. "Yenile" reads both again and measures the folders anew. The applications are in Uygulamalar. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../components/icons";
import ConfirmWord from "../components/ui/ConfirmWord.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import Modal from "../components/ui/Modal.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import Tabs from "../components/ui/Tabs.vue";
import UsageBar from "../components/ui/UsageBar.vue";
import type { Tone } from "../components/ui/types";
import { readCleanup, readResources, startCleanup, type Container, type Resources, type StorageKind } from "../api/podman";
import { readJob } from "../api/konsol";
import { watchJob } from "./app/jobs";
import { apps, live, runningJobs, serverNow } from "../live";
import { appRoute } from "../router";
import { useQueryParam } from "../query";
import { openSurface } from "../ui";
import { UNKNOWN, bytes, clock, date, percent, uptime } from "../format";
import type { Islem, Temizlik, TemizlikIstegi } from "../api/sema";

// ---- the reads
const list = ref<Resources | null>(null);
const listError = ref("");
const loading = ref(false);
const readAt = ref(0);

async function load(): Promise<void> {
  loading.value = true;
  try {
    list.value = await readResources();
    listError.value = "";
    readAt.value = Date.now() / 1000;
  } catch (err) {
    listError.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}

const cleanup = ref<Temizlik | null>(null);
const cleanupError = ref("");
const cleanupLoading = ref(false);

async function loadCleanup(fresh = false): Promise<void> {
  cleanupLoading.value = true;
  try {
    cleanup.value = await readCleanup(fresh);
    cleanupError.value = "";
  } catch (err) {
    cleanupError.value = err instanceof Error ? err.message : String(err);
  } finally {
    cleanupLoading.value = false;
  }
}

/** "Yenile": both reads again; the removed applications' folders are measured anew. */
function refresh(): void {
  void load();
  void loadCleanup(true);
}

const LABELS = { containers: "Konteynerler", images: "İmajlar", volumes: "Birimler", networks: "Ağlar" } as const;
function collectionError(key: keyof typeof LABELS): string {
  const l = list.value;
  if (!l) return "";
  if (!l.runtime.ok) return l.runtime.error || "Podman yanıt vermedi.";
  return l.errors[key] || (l[key] === null ? `${LABELS[key]} okunamadı.` : "");
}

// ---- the summaries
const runtime = computed(() => list.value?.runtime ?? null);
const containers = computed(() => list.value?.containers ?? []);
const running = computed(() => containers.value.filter((c) => c.state === "running"));
const unhealthy = computed(() => running.value.filter((c) => c.health === "unhealthy").length);
const stopped = computed(() => containers.value.length - running.value.length);
const owned = computed(() => containers.value.filter((c) => c.app));
const ownedApps = computed(() => new Set(owned.value.map((c) => c.app)).size);
const containerState = computed<{ text: string; tone: Tone; dot?: boolean }>(() => {
  if (unhealthy.value) return { text: `${unhealthy.value} sağlıksız`, tone: "warning", dot: true };
  if (stopped.value) return { text: `${stopped.value} durmuş`, tone: "neutral" };
  return containers.value.length ? { text: "Hepsi çalışıyor", tone: "ok", dot: true } : { text: "Yok", tone: "neutral" };
});
/** The split bar's three parts (running, unhealthy, stopped) as SVG widths: the CSP allows no style attribute. */
const split = computed(() => {
  const n = containers.value.length;
  if (!n) return [];
  const parts = [
    { cls: "seg-ok", count: running.value.length - unhealthy.value },
    { cls: "seg-warn", count: unhealthy.value },
    { cls: "seg-off", count: stopped.value },
  ];
  let x = 0;
  return parts.filter((p) => p.count).map((p) => {
    const part = { cls: p.cls, x: `${x}%`, width: `${(p.count / n) * 100}%` };
    x += (p.count / n) * 100;
    return part;
  });
});

const measured = computed(() => running.value.filter((c) => c.memory !== null));
const memory = computed(() => measured.value.reduce((n, c) => n + (c.memory ?? 0), 0));
const cpu = computed(() => (running.value.some((c) => c.cpu !== null) ? running.value.reduce((n, c) => n + (c.cpu ?? 0), 0) : null));
const hostMemory = computed(() => live.kaynaklar?.mem.total ?? null);
const memoryShare = computed(() => (hostMemory.value && measured.value.length ? (memory.value / hostMemory.value) * 100 : null));

const KIND_TEXT: Record<StorageKind["type"], { label: string; unit: string; cls: string }> = {
  images: { label: "İmajlar", unit: "imaj", cls: "seg-images" },
  containers: { label: "Konteynerler", unit: "konteyner", cls: "seg-containers" },
  volumes: { label: "Birimler", unit: "birim", cls: "seg-volumes" },
};
const storage = computed(() => list.value?.storage ?? null);
const storageParts = computed(() => {
  const total = (storage.value?.types ?? []).reduce((n, k) => n + k.size, 0);
  let x = 0;
  return (storage.value?.types ?? []).map((k) => {
    const width = total ? (k.size / total) * 100 : 0;
    const part = { ...k, ...KIND_TEXT[k.type], x: `${x}%`, width: `${width}%` };
    x += width;
    return part;
  });
});

// ---- the containers
type Filter = "tumu" | "calisan" | "durmus" | "disari";
const FILTERS: readonly { id: Filter; label: string }[] = [
  { id: "tumu", label: "Tümü" },
  { id: "calisan", label: "Çalışan" },
  { id: "durmus", label: "Durmuş" },
  { id: "disari", label: "Obhut dışı" },
];
const TESTS: Record<Filter, (c: Container) => boolean> = {
  tumu: () => true,
  calisan: (c) => c.state === "running",
  durmus: (c) => c.state !== "running",
  disari: (c) => !c.app,
};
const filter = useQueryParam<Filter>("suzgec", FILTERS.map((f) => f.id), "tumu");
const filterCount = (f: Filter) => containers.value.filter(TESTS[f]).length;

const MANAGER: Record<Temizlik["konteynerler"][number]["yonetici"], { pill: string; tone: Tone; text: string }> = {
  podman: { pill: "Obhut dışı", tone: "neutral", text: "Yalnız Podman; Uygulama ekle'de var olan konteyner olarak seçilebilir" },
  kayitsiz: { pill: "Kaydı yok", tone: "warning", text: "Bir uygulamanın etiketini taşıyor ama kaydı yok" },
  baska: { pill: "Obhut dışı", tone: "neutral", text: "Başka bir yönetici çalıştırıyor" },
};
const managers = computed(() => new Map((cleanup.value?.konteynerler ?? []).map((c) => [c.ad, MANAGER[c.yonetici]])));

function stateOf(c: Container): { tone: Tone; text: string; dot: boolean; note: string } {
  const restarts = c.restarts ? `${c.restarts} kez yeniden başladı` : "";
  if (c.state === "running") {
    if (c.health === "unhealthy") return { tone: "warning", text: "Sağlıksız", dot: true, note: restarts };
    if (c.health === "starting") return { tone: "neutral", text: "Başlıyor", dot: false, note: restarts };
    return { tone: "ok", text: "Çalışıyor", dot: true, note: restarts };
  }
  if (c.state === "paused") return { tone: "neutral", text: "Duraklatıldı", dot: false, note: restarts };
  if (c.state === "created") return { tone: "neutral", text: "Başlatılmadı", dot: false, note: "" };
  if (c.state === "exited" || c.state === "stopped") {
    return { tone: "neutral", text: "Durdu", dot: false, note: [`çıkış kodu ${c.exitCode}`, restarts].filter(Boolean).join(" · ") };
  }
  return { tone: "neutral", text: c.state || UNKNOWN, dot: false, note: restarts };
}

const shortId = (id: string) => id.replace(/^sha256:/, "").slice(0, 12);
// A digest-pinned name shows the digest's first 12 characters; the whole name stays the row's label.
const shortImage = (name: string) => name.replace(/@sha256:([0-9a-f]{12})[0-9a-f]+$/, "@sha256:$1…");
const portText = (p: Container["ports"][number]) => `${p.hostIp ? p.hostIp + ":" : ""}${p.hostPort} → ${p.containerPort}/${p.protocol}`;
const maxMemory = computed(() => Math.max(0, ...running.value.map((c) => c.memory ?? 0)));

const rows = computed(() =>
  [...containers.value]
    .sort((a, b) => Number(b.state === "running") - Number(a.state === "running") || (b.memory ?? -1) - (a.memory ?? -1) || a.name.localeCompare(b.name))
    .filter(TESTS[filter.value])
    .map((c) => {
      const service = c.app && c.name.startsWith(c.app + "_") ? c.name.slice(c.app.length + 1) : "";
      const on = c.state === "running";
      return {
        c, service, state: stateOf(c), manager: c.app ? null : managers.value.get(c.name) ?? null,
        uptime: on && c.started ? uptime(serverNow() - c.started) : UNKNOWN,
        bar: on && c.memory !== null && maxMemory.value ? (c.memory / maxMemory.value) * 100 : null,
      };
    }),
);

// ---- images, volumes, networks and the folders left behind; what nothing uses can be removed
type Kind = keyof Required<TemizlikIstegi>;
interface Item {
  kind: Kind;
  /** What the request names: an image's ID, a network's or volume's name, an application's folder name. */
  value: string;
  label: string;
  size: number | null;
}
const WHAT: Record<Kind, string> = { imajlar: "Kullanılmayan imaj", birimler: "Kullanılmayan birim", aglar: "Kullanılmayan ağ", klasorler: "Kaldırılmış uygulamanın klasörü" };
const bareId = (id: string) => id.replace(/^sha256:/, "");

interface ImageRow { id: string; names: string[]; size: number | null; created: number | null; usedBy: string[]; item: Item | null }
const imageRows = computed<ImageRow[]>(() => {
  const offered = new Map((cleanup.value?.imajlar ?? []).map((i) => [bareId(i.id), i]));
  const byId = new Map<string, ImageRow>();
  for (const i of list.value?.images ?? []) {
    const key = bareId(i.id) || i.name;
    const row = byId.get(key);
    if (row) {
      if (!row.names.includes(i.name)) row.names.push(i.name);
      for (const u of i.used_by) if (!row.usedBy.includes(u)) row.usedBy.push(u);
      continue;
    }
    byId.set(key, { id: i.id, names: [i.name], size: i.size, created: i.created, usedBy: [...i.used_by], item: null });
  }
  // An image the cleanup offers but the list did not name (the list could not be read) is still offered.
  for (const [key, i] of offered) {
    if (!byId.has(key)) byId.set(key, { id: i.id, names: i.etiketler.length ? i.etiketler : ["<etiketsiz>"], size: i.boyut, created: i.olusturuldu, usedBy: [], item: null });
  }
  return [...byId.entries()].map(([key, row]) => {
    const o = offered.get(key);
    return o ? { ...row, item: { kind: "imajlar", value: o.id, label: o.etiketler.length ? o.etiketler.join(", ") : `<etiketsiz> ${shortId(o.id)}`, size: o.boyut } } : row;
  });
});

interface VolumeRow { name: string; driver: string; usedBy: string[]; managed: boolean; item: Item | null }
const volumeRows = computed<VolumeRow[]>(() => {
  const offered = new Map((cleanup.value?.birimler ?? []).map((b) => [b.ad, b]));
  const out: VolumeRow[] = (list.value?.volumes ?? []).map((v) => ({ name: v.name, driver: v.driver, usedBy: v.used_by, managed: v.managed, item: null }));
  for (const b of offered.values()) if (!out.some((v) => v.name === b.ad)) out.push({ name: b.ad, driver: b.surucu, usedBy: [], managed: false, item: null });
  return out.map((v) => (offered.has(v.name) ? { ...v, item: { kind: "birimler", value: v.name, label: v.name, size: null } } : v));
});

interface NetworkRow { name: string; driver: string; subnets: string[]; usedBy: string[]; managed: boolean; internal: boolean; item: Item | null }
const networkRows = computed<NetworkRow[]>(() => {
  const offered = new Map((cleanup.value?.aglar ?? []).map((n) => [n.ad, n]));
  const out: NetworkRow[] = (list.value?.networks ?? []).map((n) => ({ ...n, usedBy: n.used_by, item: null }));
  for (const n of offered.values()) if (!out.some((x) => x.name === n.ad)) out.push({ name: n.ad, driver: n.surucu, subnets: [], usedBy: [], managed: false, internal: false, item: null });
  return out.map((n) => (offered.has(n.name) ? { ...n, item: { kind: "aglar", value: n.name, label: n.name, size: null } } : n));
});

const folderRows = computed(() =>
  (cleanup.value?.klasorler ?? []).map((k) => ({ ...k, item: { kind: "klasorler" as const, value: k.ad, label: k.yol, size: k.boyut } })),
);

const offeredItems = computed<Record<Kind, Item[]>>(() => ({
  imajlar: imageRows.value.flatMap((r) => (r.item ? [r.item] : [])),
  birimler: volumeRows.value.flatMap((r) => (r.item ? [r.item] : [])),
  aglar: networkRows.value.flatMap((r) => (r.item ? [r.item] : [])),
  klasorler: folderRows.value.map((r) => r.item),
}));
const offeredTotal = computed(() => Object.values(offeredItems.value).reduce((n, items) => n + items.length, 0));

const hint = (n: number, unused: number) => (unused ? `${n} · ${unused} kullanılmayan` : `${n}`);
const TABS = computed(() => [
  { id: "imajlar", label: "İmajlar", hint: collectionError("images") && !imageRows.value.length ? "okunamadı" : hint(imageRows.value.length, offeredItems.value.imajlar.length) },
  { id: "birimler", label: "Birimler", hint: collectionError("volumes") && !volumeRows.value.length ? "okunamadı" : hint(volumeRows.value.length, offeredItems.value.birimler.length) },
  { id: "aglar", label: "Ağlar", hint: collectionError("networks") && !networkRows.value.length ? "okunamadı" : hint(networkRows.value.length, offeredItems.value.aglar.length) },
  { id: "klasorler", label: "Kalan klasörler", hint: cleanup.value ? `${folderRows.value.length}` : "" },
]);

/** Who uses it: an application's name links to its page, a container's stays text. */
const appNames = computed(() => new Set((apps.value ?? []).map((a) => a.ad)));

const keyOf = (i: Item) => `${i.kind}:${i.value}`;
const selected = ref<string[]>([]);
const isSelected = (i: Item) => selected.value.includes(keyOf(i));
function toggle(i: Item): void {
  const key = keyOf(i);
  selected.value = isSelected(i) ? selected.value.filter((k) => k !== key) : [...selected.value, key];
}
const allOf = (kind: Kind) => offeredItems.value[kind].length > 0 && offeredItems.value[kind].every(isSelected);
function toggleAll(kind: Kind): void {
  const keys = offeredItems.value[kind].map(keyOf);
  selected.value = allOf(kind) ? selected.value.filter((k) => !keys.includes(k)) : [...new Set([...selected.value, ...keys])];
}
// A new read keeps only the ticks of items still offered.
watch(offeredItems, (now) => {
  const offered = new Set(Object.values(now).flatMap((items) => items.map(keyOf)));
  selected.value = selected.value.filter((k) => offered.has(k));
});
const KINDS: readonly Kind[] = ["imajlar", "birimler", "aglar", "klasorler"];
const chosen = computed(() => KINDS.flatMap((k) => offeredItems.value[k].filter(isSelected).map((i) => ({ ...i, what: WHAT[k] }))));
const chosenSize = computed(() => chosen.value.reduce((n, i) => n + (i.size ?? 0), 0));

// ---- the job
const askOpen = ref(false);
const word = ref(false);
const sending = ref(false);
const sendError = ref("");
const jobId = ref("");
const step = ref("");
const result = ref<{ tone: Tone; text: string } | null>(null);
let stopWatch: (() => void) | null = null;

// A cleanup that runs already (started here or in another tab) holds the ticks and the button.
const busy = computed(() => Boolean(jobId.value) || runningJobs.value.some((j) => j.tur === "konteyner"));

function ask(): void {
  if (!chosen.value.length || busy.value) return;
  sendError.value = "";
  askOpen.value = true;
}

const WORDS: Record<string, string> = { imaj: "imaj", ag: "ağ", birim: "birim", klasor: "klasör" };
async function ended(job: Islem | null, id: string): Promise<void> {
  jobId.value = "";
  step.value = "";
  stopWatch = null;
  if (job?.durum === "hata") {
    result.value = { tone: "warning", text: `Kaldırma tamamlanamadı: ${job.adim || "sunucu bir neden bildirmedi"}` };
  } else {
    let text = "Kaldırma bitti.";
    try {
      const removed = (await readJob(id)).result?.kaldirilan;
      if (Array.isArray(removed)) {
        // An image goes by its ID: its first 12 characters, as the list shows it.
        const names = removed.map((r) => (r && typeof r === "object" ? `${WORDS[String(r.tur)] ?? r.tur} ${r.tur === "imaj" ? shortId(String(r.ad)) : String(r.ad)}` : "")).filter(Boolean);
        text = `Kaldırıldı: ${names.length} öge${names.length ? ` (${names.join(", ")})` : ""}.`;
      }
    } catch {
      // the record may be gone; the drawer said how it ended
    }
    result.value = { tone: "ok", text };
  }
  void loadCleanup();
  void load();
}

async function confirm(): Promise<void> {
  if (!word.value || sending.value || !chosen.value.length) return;
  sending.value = true;
  sendError.value = "";
  const request: TemizlikIstegi = {};
  for (const i of chosen.value) (request[i.kind] ??= []).push(i.value);
  try {
    const job = await startCleanup(request);
    askOpen.value = false;
    selected.value = [];
    jobId.value = job.is;
    result.value = null;
    step.value = "Başlatılıyor";
    stopWatch = watchJob(job.is, (j) => void ended(j, job.is), (j) => (step.value = j.adim || step.value), "konteyner");
  } catch (err) {
    sendError.value = err instanceof Error ? err.message : String(err);
    void loadCleanup();
  } finally {
    sending.value = false;
  }
}

onMounted(() => {
  void load();
  void loadCleanup();
});
onBeforeUnmount(() => stopWatch?.());
</script>

<template>
  <div class="page-body podman-page" data-testid="podman">
    <div class="podman-tools">
      <span v-if="readAt" class="meter-note" data-testid="podman-read">Son okuma {{ clock(readAt) }}</span>
      <button type="button" class="btn btn-secondary btn-sm" :disabled="loading || cleanupLoading" data-testid="podman-refresh" @click="refresh">
        <Icon name="refresh" :size="16" />Yenile
      </button>
    </div>
    <p v-if="listError" class="form-error" role="alert" data-testid="podman-error">{{ list ? `Son okuma başarısız: ${listError}` : listError }}</p>

    <div class="summary-grid podman-summary">
      <section class="card summary-card stat-card" aria-labelledby="pd-ortam" data-testid="podman-runtime">
        <div class="card-head">
          <h2 id="pd-ortam" class="card-title">Çalışma ortamı</h2>
          <div v-if="runtime" class="card-actions">
            <StatusPill :tone="runtime.ok ? 'ok' : 'danger'" :dot="runtime.ok">{{ runtime.ok ? "Çalışıyor" : "Yanıt vermiyor" }}</StatusPill>
          </div>
        </div>
        <template v-if="runtime?.ok">
          <p class="stat-big" data-testid="podman-version">Podman {{ runtime.version || UNKNOWN }}</p>
          <dl class="summary-rows">
            <dt>Kip</dt><dd>rootful · systemd (Quadlet)</dd>
            <dt>Ağ</dt><dd>uygulama başına köprü</dd>
          </dl>
        </template>
        <p v-else-if="runtime" class="notice notice-danger" role="alert" data-testid="podman-runtime-error">
          <Icon name="xcircle" class="notice-icon" /><span>{{ runtime.error || "Podman yanıt vermedi." }}</span>
        </p>
        <p v-else-if="!listError" class="meter-note" role="status">Okunuyor…</p>
      </section>

      <section class="card summary-card stat-card" aria-labelledby="pd-konteyner" data-testid="podman-containers">
        <div class="card-head">
          <h2 id="pd-konteyner" class="card-title">Konteynerler</h2>
          <div v-if="list" class="card-actions"><StatusPill :tone="containerState.tone" :dot="containerState.dot">{{ containerState.text }}</StatusPill></div>
        </div>
        <template v-if="list && !collectionError('containers')">
          <p class="stat-big">{{ running.length }} <span class="stat-of">/ {{ containers.length }} çalışıyor</span></p>
          <svg v-if="split.length" class="stat-split" width="100%" height="6" aria-hidden="true" focusable="false">
            <rect v-for="p in split" :key="p.cls" :class="p.cls" :x="p.x" :width="p.width" height="6" />
          </svg>
          <dl class="summary-rows">
            <dt>Obhut'un</dt><dd>{{ owned.length }} · {{ ownedApps }} uygulama</dd>
            <dt>Obhut dışı</dt><dd>{{ containers.length - owned.length }}</dd>
          </dl>
        </template>
        <p v-else-if="list" class="meter-note">{{ collectionError("containers") }}</p>
      </section>

      <section class="card summary-card stat-card" aria-labelledby="pd-kaynak" data-testid="podman-usage">
        <div class="card-head">
          <h2 id="pd-kaynak" class="card-title">İşlemci ve bellek</h2>
          <div v-if="list" class="card-actions"><StatusPill tone="neutral">{{ running.length }} konteyner</StatusPill></div>
        </div>
        <template v-if="list">
          <p class="stat-big">{{ measured.length ? bytes(memory) : UNKNOWN }} <span class="stat-of">bellek</span></p>
          <UsageBar :value="memoryShare" />
          <dl class="summary-rows">
            <dt>Bellek payı</dt><dd>{{ memoryShare === null ? UNKNOWN : percent(memoryShare) }}</dd>
            <dt>İşlemci</dt><dd>{{ percent(cpu) }}</dd>
          </dl>
        </template>
      </section>

      <section class="card summary-card stat-card" aria-labelledby="pd-depo" data-testid="podman-storage">
        <div class="card-head">
          <h2 id="pd-depo" class="card-title">Depolama</h2>
          <div v-if="cleanup" class="card-actions">
            <StatusPill :tone="offeredTotal ? 'warning' : 'neutral'">{{ offeredTotal ? `${offeredTotal} kullanılmayan` : "Kullanılmayan yok" }}</StatusPill>
          </div>
        </div>
        <template v-if="list">
          <p class="stat-big">{{ bytes(storage?.size) }}</p>
          <svg v-if="storageParts.length" class="stat-split" width="100%" height="6" aria-hidden="true" focusable="false">
            <rect v-for="p in storageParts" :key="p.type" :class="p.cls" :x="p.x" :width="p.width" height="6" />
          </svg>
          <dl v-if="storageParts.length" class="summary-rows">
            <template v-for="p in storageParts" :key="p.type">
              <dt><span class="stat-key" :class="p.cls" aria-hidden="true"></span>{{ p.label }}</dt>
              <dd :data-tur="p.type">{{ bytes(p.size) }} · {{ p.count }} {{ p.unit }}</dd>
            </template>
          </dl>
        </template>
      </section>
    </div>

    <section class="card podman-card" aria-labelledby="pd-liste" data-testid="containers">
      <div class="card-head">
        <h2 id="pd-liste" class="card-title">Konteynerler</h2>
        <div class="card-actions"><span class="meter-note">Önce çalışanlar, belleğe göre</span></div>
      </div>
      <p v-if="list?.errors.stats" class="notice notice-warning" role="note" data-testid="stats-error"><Icon name="alert" class="notice-icon" /><span>{{ list.errors.stats }}</span></p>
      <p v-if="collectionError('containers')" class="notice notice-warning" role="alert" data-testid="containers-error">
        <Icon name="alert" class="notice-icon" /><span>{{ collectionError("containers") }}</span>
      </p>
      <template v-else-if="list">
        <div v-if="containers.length" class="filters" role="group" aria-label="Süzgeç">
          <button v-for="f in FILTERS" :key="f.id" type="button" class="filter-chip" :data-suzgec="f.id" :aria-pressed="filter === f.id" @click="filter = f.id">
            {{ f.label }} <span class="filter-count">{{ filterCount(f.id) }}</span>
          </button>
        </div>
        <div v-if="rows.length" class="table-wrap">
          <table class="data-table resource-table container-table">
            <thead>
              <tr><th scope="col">Konteyner</th><th scope="col">Durum</th><th scope="col">İmaj</th><th scope="col">İşlemci</th><th scope="col">Bellek</th><th scope="col">Çalışma</th><th scope="col">Portlar</th></tr>
            </thead>
            <tbody>
              <tr v-for="r in rows" :key="r.c.name" :data-konteyner="r.c.name">
                <th scope="row" class="col-main">
                  <span class="cell-stack">
                    <strong class="mono wrap">{{ r.c.name }}</strong>
                    <span v-if="r.c.app" class="cell-note"><RouterLink :to="appRoute(r.c.app)">{{ r.c.app }}</RouterLink><template v-if="r.service"> · servis {{ r.service }}</template></span>
                    <StatusPill v-if="!r.c.app" :tone="r.manager?.tone ?? 'neutral'">{{ r.manager?.pill ?? "Obhut dışı" }}</StatusPill>
                    <span v-if="r.manager" class="cell-note">{{ r.manager.text }}</span>
                  </span>
                </th>
                <td data-label="Durum">
                  <StatusPill :tone="r.state.tone" :dot="r.state.dot">{{ r.state.text }}</StatusPill>
                  <span v-if="r.state.note" class="cell-note">{{ r.state.note }}</span>
                </td>
                <td data-label="İmaj" class="mono wrap"><span aria-hidden="true">{{ shortImage(r.c.image) || UNKNOWN }}</span><span class="sr-only">{{ r.c.image }}</span></td>
                <td data-label="İşlemci" class="nowrap num">{{ r.c.state === "running" ? percent(r.c.cpu) : UNKNOWN }}</td>
                <td data-label="Bellek" class="nowrap">
                  <span v-if="r.c.state === 'running' && r.c.memory !== null" class="bar-cell"><span class="num">{{ bytes(r.c.memory) }}</span><UsageBar :value="r.bar" /></span>
                  <span v-else>{{ UNKNOWN }}</span>
                </td>
                <td data-label="Çalışma" class="nowrap">{{ r.uptime }}</td>
                <td data-label="Portlar" class="mono wrap">
                  <template v-if="r.c.ports.length"><span v-for="(p, i) in r.c.ports" :key="i" class="port-line">{{ portText(p) }}</span></template>
                  <span v-else class="muted">yok</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <EmptyState v-else-if="!containers.length" title="Konteyner yok" text="Bir uygulama kurulunca burada görünür." icon="box" />
        <p v-else class="card-text">Bu süzgece uyan konteyner yok.</p>
      </template>
      <p v-else-if="!listError" class="meter-note" role="status">Okunuyor…</p>
      <p class="meter-note">
        Salt okunur. Bir uygulamanın konteynerleri kendi sayfasında başlatılır ve durdurulur (<RouterLink to="/uygulamalar">Uygulamalar</RouterLink>); Obhut dışı
        konteynerleri Obhut başlatmaz, durdurmaz, kaldırmaz.
      </p>
    </section>

    <section class="card podman-card" aria-labelledby="pd-kaynaklar" :aria-busy="busy" data-testid="cleanup">
      <div class="card-head">
        <h2 id="pd-kaynaklar" class="card-title">İmajlar, birimler, ağlar</h2>
        <div class="card-actions"><span class="meter-note">Kullanılmayanlar seçilip kaldırılır</span></div>
      </div>
      <p v-if="cleanupError" class="form-error" role="alert" data-testid="cleanup-error">{{ cleanupError }}</p>
      <p v-for="(h, i) in cleanup?.hatalar ?? []" :key="i" class="notice notice-warning" data-testid="cleanup-warning"><Icon name="alert" class="notice-icon" /><span>{{ h }}</span></p>

      <Tabs v-if="list || cleanup" :tabs="TABS" label="Podman kaynakları" param="kaynak">
        <template #default="{ active }">
          <!-- images -->
          <div v-if="active === 'imajlar'" class="resource-pane" data-testid="images">
            <p v-if="collectionError('images')" class="notice notice-warning" role="alert" data-testid="images-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("images") }}</span></p>
            <label v-if="offeredItems.imajlar.length" class="check-row pick-all">
              <input type="checkbox" :checked="allOf('imajlar')" :indeterminate="!allOf('imajlar') && offeredItems.imajlar.some(isSelected)" :disabled="busy" data-hepsi="imajlar" @change="toggleAll('imajlar')" />
              <span>Kullanılmayanların hepsi ({{ offeredItems.imajlar.length }})</span>
            </label>
            <div v-if="imageRows.length" class="table-wrap">
              <table class="data-table resource-table pick-table">
                <thead>
                  <tr><th scope="col">İmaj</th><th scope="col">Kimlik</th><th scope="col">Boyut</th><th scope="col">Oluşturma</th><th scope="col">Kullanan</th></tr>
                </thead>
                <tbody>
                  <tr v-for="r in imageRows" :key="r.id + r.names[0]" :data-imaj="r.names[0]" :class="{ 'is-picked': r.item && isSelected(r.item) }">
                    <th scope="row" class="col-main">
                      <span class="pick-row">
                        <input v-if="r.item" type="checkbox" :checked="isSelected(r.item)" :disabled="busy" :aria-label="`Kaldırmak için seç: ${r.item.label}`" :data-oge="r.item.value" @change="toggle(r.item)" />
                        <span v-else-if="offeredItems.imajlar.length" class="pick-gap" aria-hidden="true"></span>
                        <span class="cell-stack">
                          <strong v-for="n in r.names" :key="n" class="mono wrap"><span aria-hidden="true">{{ shortImage(n) }}</span><span class="sr-only">{{ n }}</span></strong>
                          <StatusPill v-if="r.item" tone="warning">Kullanılmayan</StatusPill>
                        </span>
                      </span>
                    </th>
                    <td data-label="Kimlik" class="mono">{{ shortId(r.id) || UNKNOWN }}</td>
                    <td data-label="Boyut" class="nowrap num">{{ bytes(r.size) }}</td>
                    <td data-label="Oluşturma" class="nowrap">{{ date(r.created) }}</td>
                    <td data-label="Kullanan">
                      <span v-if="!r.usedBy.length" class="muted">{{ UNKNOWN }}</span>
                      <span v-else class="used-by">
                        <template v-for="(u, k) in r.usedBy" :key="u"><template v-if="k">, </template><RouterLink v-if="appNames.has(u)" :to="appRoute(u)">{{ u }}</RouterLink><span v-else>{{ u }}</span></template>
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <EmptyState v-else-if="!collectionError('images')" title="İmaj yok" text="Bir uygulama kurulunca burada görünür." icon="box" />
          </div>

          <!-- volumes -->
          <div v-else-if="active === 'birimler'" class="resource-pane" data-testid="volumes">
            <p class="meter-note">Birim (volume), Podman'ın konteynerden bağımsız sakladığı adlı veri alanıdır: konteyner kaldırılınca kalır. Uygulamaların verileri kendi klasörlerindedir (Dosyalar → Depolama).</p>
            <p v-if="collectionError('volumes')" class="notice notice-warning" role="alert" data-testid="volumes-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("volumes") }}</span></p>
            <label v-if="offeredItems.birimler.length" class="check-row pick-all">
              <input type="checkbox" :checked="allOf('birimler')" :indeterminate="!allOf('birimler') && offeredItems.birimler.some(isSelected)" :disabled="busy" data-hepsi="birimler" @change="toggleAll('birimler')" />
              <span>Kullanılmayanların hepsi ({{ offeredItems.birimler.length }})</span>
            </label>
            <div v-if="volumeRows.length" class="table-wrap">
              <table class="data-table resource-table pick-table">
                <thead>
                  <tr><th scope="col">Birim</th><th scope="col">Sürücü</th><th scope="col">Kullanan</th></tr>
                </thead>
                <tbody>
                  <tr v-for="v in volumeRows" :key="v.name" :data-birim="v.name" :class="{ 'is-picked': v.item && isSelected(v.item) }">
                    <th scope="row" class="col-main">
                      <span class="pick-row">
                        <input v-if="v.item" type="checkbox" :checked="isSelected(v.item)" :disabled="busy" :aria-label="`Kaldırmak için seç: ${v.name}`" :data-oge="v.name" @change="toggle(v.item)" />
                        <span v-else-if="offeredItems.birimler.length" class="pick-gap" aria-hidden="true"></span>
                        <span class="cell-stack">
                          <strong class="mono wrap">{{ v.name }}</strong>
                          <span class="badges">
                            <StatusPill :tone="v.managed ? 'ok' : 'neutral'">{{ v.managed ? "Obhut" : "Dışarıda" }}</StatusPill>
                            <StatusPill v-if="v.item" tone="warning">Kullanılmayan</StatusPill>
                          </span>
                        </span>
                      </span>
                    </th>
                    <td data-label="Sürücü">{{ v.driver || UNKNOWN }}</td>
                    <td data-label="Kullanan">{{ v.usedBy.length ? v.usedBy.join(", ") : UNKNOWN }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <EmptyState v-else-if="!collectionError('volumes')" title="Birim yok" text="Bir konteyner adlı bir birim kullanınca burada görünür." icon="box" />
          </div>

          <!-- networks -->
          <div v-else-if="active === 'aglar'" class="resource-pane" data-testid="networks">
            <p class="meter-note">Her uygulama kendi köprüsündedir (ksl-…); portları Erişim → Adresler'de seçilen erişime göre açılır. Podman'ın varsayılan ağı ve bir uygulamanınki kaldırılamaz.</p>
            <p v-if="collectionError('networks')" class="notice notice-warning" role="alert" data-testid="networks-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("networks") }}</span></p>
            <label v-if="offeredItems.aglar.length" class="check-row pick-all">
              <input type="checkbox" :checked="allOf('aglar')" :indeterminate="!allOf('aglar') && offeredItems.aglar.some(isSelected)" :disabled="busy" data-hepsi="aglar" @change="toggleAll('aglar')" />
              <span>Kullanılmayanların hepsi ({{ offeredItems.aglar.length }})</span>
            </label>
            <div v-if="networkRows.length" class="table-wrap">
              <table class="data-table resource-table pick-table">
                <thead>
                  <tr><th scope="col">Ağ</th><th scope="col">Sürücü</th><th scope="col">Alt ağ</th><th scope="col">Kullanan</th></tr>
                </thead>
                <tbody>
                  <tr v-for="net in networkRows" :key="net.name" :data-ag="net.name" :class="{ 'is-picked': net.item && isSelected(net.item) }">
                    <th scope="row" class="col-main">
                      <span class="pick-row">
                        <input v-if="net.item" type="checkbox" :checked="isSelected(net.item)" :disabled="busy" :aria-label="`Kaldırmak için seç: ${net.name}`" :data-oge="net.name" @change="toggle(net.item)" />
                        <span v-else-if="offeredItems.aglar.length" class="pick-gap" aria-hidden="true"></span>
                        <span class="cell-stack">
                          <strong class="mono wrap">{{ net.name }}</strong>
                          <span class="badges">
                            <StatusPill :tone="net.managed ? 'ok' : 'neutral'">{{ net.managed ? "Obhut" : "Sistem" }}</StatusPill>
                            <StatusPill v-if="net.internal" tone="accent">İç ağ</StatusPill>
                            <StatusPill v-if="net.item" tone="warning">Kullanılmayan</StatusPill>
                          </span>
                        </span>
                      </span>
                    </th>
                    <td data-label="Sürücü">{{ net.driver || UNKNOWN }}</td>
                    <td data-label="Alt ağ" class="mono wrap">{{ net.subnets.join(", ") || UNKNOWN }}</td>
                    <td data-label="Kullanan">{{ net.usedBy.length ? net.usedBy.join(", ") : UNKNOWN }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <EmptyState v-else-if="!collectionError('networks')" title="Ağ yok" icon="globe" />
          </div>

          <!-- the folders removed applications left -->
          <div v-else-if="active === 'klasorler'" class="resource-pane" data-testid="folders">
            <p class="meter-note">Kaldırılmış uygulamalardan kalan veri klasörleri: kaldırılırken "Verileri sakla" seçilmişse burada kalır; aynı adla yeniden eklenen uygulama onları geri bağlar.</p>
            <label v-if="folderRows.length" class="check-row pick-all">
              <input type="checkbox" :checked="allOf('klasorler')" :indeterminate="!allOf('klasorler') && offeredItems.klasorler.some(isSelected)" :disabled="busy" data-hepsi="klasorler" @change="toggleAll('klasorler')" />
              <span>Hepsi ({{ folderRows.length }})</span>
            </label>
            <div v-if="folderRows.length" class="table-wrap">
              <table class="data-table resource-table pick-table">
                <thead>
                  <tr><th scope="col">Klasör</th><th scope="col">Uygulama</th><th scope="col">Boyut</th></tr>
                </thead>
                <tbody>
                  <tr v-for="k in folderRows" :key="k.ad" :data-klasor="k.ad" :class="{ 'is-picked': isSelected(k.item) }">
                    <th scope="row" class="col-main">
                      <span class="pick-row">
                        <input type="checkbox" :checked="isSelected(k.item)" :disabled="busy" :aria-label="`Kaldırmak için seç: ${k.yol}`" :data-oge="k.ad" @change="toggle(k.item)" />
                        <span class="cell-stack">
                          <strong class="mono wrap">{{ k.yol }}</strong>
                          <StatusPill tone="warning">Kullanılmayan</StatusPill>
                        </span>
                      </span>
                    </th>
                    <td data-label="Uygulama">{{ k.ad }} kaldırılmış</td>
                    <td data-label="Boyut" :class="k.boyut === null ? 'muted' : 'nowrap num'">{{ k.boyut === null ? k.neden || "ölçülemedi" : bytes(k.boyut) }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <EmptyState v-else-if="cleanup" title="Kalan klasör yok" text="Kaldırılmış bir uygulamadan klasör kalmamış." icon="check" />
          </div>
        </template>
      </Tabs>
      <p v-else-if="!listError && !cleanupError" class="meter-note" role="status">Okunuyor…</p>

      <p v-if="busy" class="cleanup-run" role="status" data-testid="cleanup-running">
        <span class="spinner" aria-hidden="true"></span><span>Kaldırma sürüyor<template v-if="step"> · {{ step }}</template></span>
        <button type="button" class="btn btn-secondary btn-sm" data-testid="cleanup-jobs" @click="openSurface('drawer')"><Icon name="pulse" :size="16" />İşlemleri göster</button>
      </p>
      <p v-if="result" class="notice" :class="'notice-' + result.tone" role="status" data-testid="cleanup-result">
        <Icon :name="result.tone === 'ok' ? 'check' : 'alert'" class="notice-icon" /><span>{{ result.text }}</span>
      </p>
      <div v-if="cleanup" class="cleanup-bar">
        <span class="meter-note" data-testid="cleanup-chosen">{{
          !offeredTotal ? "Kullanılmayan imaj, birim, ağ ya da klasör yok." : chosen.length ? `${chosen.length} öge seçili${chosenSize ? ` · ${bytes(chosenSize)}` : ""}` : "Kaldırılacakları seçin; seçim sekmeler arasında korunur."
        }}</span>
        <button v-if="offeredTotal" type="button" class="btn btn-danger" :disabled="!chosen.length || busy" data-testid="cleanup-start" @click="ask"><Icon name="trash" :size="16" />Seçilenleri kaldır…</button>
      </div>
      <p class="meter-note">Bir uygulamanın ya da konteynerin kullandığı öge seçilemez; her öge kaldırılmadan hemen önce yeniden denetlenir.</p>
    </section>

    <Modal :open="askOpen" title="Seçilenler kaldırılsın mı?" :description="`${chosen.length} öge kalıcı olarak kaldırılır.`" @close="askOpen = false">
      <ul class="modal-list cleanup-list" data-testid="cleanup-dialog-list">
        <li v-for="i in chosen" :key="i.kind + ':' + i.value">
          <Icon name="trash" :size="18" />
          <span class="cell-stack"><strong class="mono wrap">{{ i.label }}</strong><span class="cell-note">{{ i.what }}<template v-if="i.size !== null"> · {{ bytes(i.size) }}</template></span></span>
        </li>
      </ul>
      <p class="meter-note">Geri alınamaz. O arada kullanılmaya başlayan bir öge kalır; işin sonunda neyin neden kaldığı söylenir.</p>
      <ConfirmWord v-model:confirmed="word" word="temizle" />
      <p v-if="sendError" class="form-error" role="alert" data-testid="cleanup-dialog-error">{{ sendError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" @click="askOpen = false">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!word || sending" data-testid="cleanup-go" @click="confirm">{{ sending ? "Başlatılıyor…" : "Kaldır" }}</button>
      </template>
    </Modal>
  </div>
</template>
