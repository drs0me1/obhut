<!-- Gelişmiş → Podman (DD-211; K8): the base's container runtime, read-only, and its only write, the cleanup.
     Temizlik (GET /api/konsol/gelismis/temizlik): what nothing uses — images (by ID, with their tags), networks
     (never Podman's default or an application's), volumes and the data folders of removed applications with their
     sizes ("Yenile" measures them again) — each ticked to go; "Temizle…" names every chosen item and asks for the
     typed word, then POST …/temizlik starts one job, followed here and in İşlemler: its end says what went, or
     what stayed and why (each item is checked again right before it goes). The containers Obhut does not manage
     are listed read-only. Below, the inventory (GET /api/konsol/konteynerler/liste) in sub-tabs in the address
     (?kaynak=imajlar|birimler|aglar): images (name, id, size, age, who uses it), volumes and bridge networks. A
     collection that could not be read says so instead of looking empty. The applications are in Uygulamalar. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Tabs from "../../components/ui/Tabs.vue";
import type { Tone } from "../../components/ui/types";
import { readCleanup, readResources, startCleanup, type Resources } from "../../api/gelismis";
import { readJob } from "../../api/konsol";
import { watchJob } from "../app/jobs";
import { apps, runningJobs } from "../../live";
import { appRoute } from "../../router";
import { openSurface } from "../../ui";
import { UNKNOWN, bytes, clock, date } from "../../format";
import type { Islem, Temizlik, TemizlikIstegi } from "../../api/sema";

// ---- the inventory
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

const LABELS = { images: "İmajlar", volumes: "Birimler", networks: "Ağlar" } as const;
function collectionError(key: keyof typeof LABELS): string {
  const l = list.value;
  if (!l) return "";
  if (!l.runtime.ok) return l.runtime.error || "Podman yanıt vermedi.";
  return l.errors[key] || (l[key] === null ? `${LABELS[key]} okunamadı.` : "");
}
const count = (key: keyof typeof LABELS) => (collectionError(key) ? "okunamadı" : list.value?.[key] ? `${list.value[key]!.length}` : "");
const TABS = computed(() => [
  { id: "imajlar", label: "İmajlar", hint: count("images") },
  { id: "birimler", label: "Birimler", hint: count("volumes") },
  { id: "aglar", label: "Ağlar", hint: count("networks") },
]);

const shortId = (id: string) => id.replace(/^sha256:/, "").slice(0, 12);
// A digest-pinned name shows the digest's first 12 characters; the whole name stays the row's label.
const shortImage = (name: string) => name.replace(/@sha256:([0-9a-f]{12})[0-9a-f]+$/, "@sha256:$1…");
/** Who uses it: an application's name links to its page, a container's stays text. */
const appNames = computed(() => new Set((apps.value ?? []).map((a) => a.ad)));

// ---- the cleanup: what nothing uses
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

type Kind = keyof Required<TemizlikIstegi>;
interface Item {
  kind: Kind;
  /** What the request names: an image's ID, a network's or volume's name, an application's folder name. */
  value: string;
  label: string;
  detail: string;
  size: number | null;
}
const GROUPS: readonly { kind: Kind; title: string; what: string }[] = [
  { kind: "imajlar", title: "Kullanılmayan imajlar", what: "Kullanılmayan imaj" },
  { kind: "aglar", title: "Kullanılmayan ağlar", what: "Kullanılmayan ağ" },
  { kind: "birimler", title: "Kullanılmayan birimler", what: "Kullanılmayan birim" },
  { kind: "klasorler", title: "Kaldırılmış uygulamaların klasörleri", what: "Kaldırılmış uygulamanın klasörü" },
];
const join = (...parts: string[]) => parts.filter(Boolean).join(" · ");

const items = computed<Record<Kind, Item[]>>(() => {
  const c = cleanup.value;
  return {
    imajlar: (c?.imajlar ?? []).map((i) => ({
      kind: "imajlar", value: i.id, label: i.etiketler.length ? i.etiketler.join(", ") : `<etiketsiz> ${shortId(i.id)}`,
      detail: join(`Kimlik ${shortId(i.id)}`, i.boyut === null ? "" : bytes(i.boyut), i.olusturuldu ? date(i.olusturuldu) : ""), size: i.boyut,
    })),
    aglar: (c?.aglar ?? []).map((n) => ({ kind: "aglar", value: n.ad, label: n.ad, detail: join(n.surucu && `Sürücü ${n.surucu}`, n.arayuz && `arayüz ${n.arayuz}`), size: null })),
    birimler: (c?.birimler ?? []).map((b) => ({
      kind: "birimler", value: b.ad, label: b.ad, detail: join(b.surucu && `Sürücü ${b.surucu}`, b.olusturuldu ? date(b.olusturuldu) : ""), size: null,
    })),
    klasorler: (c?.klasorler ?? []).map((k) => ({
      kind: "klasorler", value: k.ad, label: k.yol, detail: join(`Uygulama ${k.ad} kaldırılmış`, k.boyut === null ? k.neden || "boyutu ölçülemedi" : bytes(k.boyut)), size: k.boyut,
    })),
  };
});
const total = computed(() => GROUPS.reduce((n, g) => n + items.value[g.kind].length, 0));

const keyOf = (i: Item) => `${i.kind}:${i.value}`;
const selected = ref<string[]>([]);
const isSelected = (i: Item) => selected.value.includes(keyOf(i));
function toggle(i: Item): void {
  const key = keyOf(i);
  selected.value = isSelected(i) ? selected.value.filter((k) => k !== key) : [...selected.value, key];
}
const allOf = (kind: Kind) => items.value[kind].length > 0 && items.value[kind].every(isSelected);
function toggleAll(kind: Kind): void {
  const keys = items.value[kind].map(keyOf);
  selected.value = allOf(kind) ? selected.value.filter((k) => !keys.includes(k)) : [...new Set([...selected.value, ...keys])];
}
// A new read keeps only the ticks of items still offered.
watch(items, (now) => {
  const offered = new Set(GROUPS.flatMap((g) => now[g.kind].map(keyOf)));
  selected.value = selected.value.filter((k) => offered.has(k));
});
const chosen = computed(() => GROUPS.flatMap((g) => items.value[g.kind].filter(isSelected).map((i) => ({ ...i, what: g.what }))));
const chosenSize = computed(() => chosen.value.reduce((n, i) => n + (i.size ?? 0), 0));

const MANAGER: Record<Temizlik["konteynerler"][number]["yonetici"], string> = {
  podman: "Yalnız Podman; Uygulama ekle'de var olan konteyner olarak seçilebilir",
  kayitsiz: "Bir uygulamanın etiketini taşıyor ama kaydı yok",
  baska: "Başka bir yönetici çalıştırıyor",
};

// ---- the job
const askOpen = ref(false);
const word = ref(false);
const sending = ref(false);
const sendError = ref("");
const jobId = ref("");
const step = ref("");
const result = ref<{ tone: Tone; text: string } | null>(null);
let stopWatch: (() => void) | null = null;

// A cleanup that runs already (started here or in another tab) holds the button.
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
    result.value = { tone: "warning", text: `Temizlik tamamlanamadı: ${job.adim || "sunucu bir neden bildirmedi"}` };
  } else {
    let text = "Temizlik bitti.";
    try {
      const removed = (await readJob(id)).result?.kaldirilan;
      if (Array.isArray(removed)) {
        // An image goes by its ID: its first 12 characters, as the lists show it.
        const names = removed.map((r) => (r && typeof r === "object" ? `${WORDS[String(r.tur)] ?? r.tur} ${r.tur === "imaj" ? shortId(String(r.ad)) : String(r.ad)}` : "")).filter(Boolean);
        text = `Temizlendi: ${names.length} öge kaldırıldı${names.length ? ` (${names.join(", ")})` : ""}.`;
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
  <div class="advanced-tab podman" data-testid="podman">
    <section class="card podman-runtime" aria-labelledby="podman-baslik" data-testid="podman-runtime">
      <div class="card-head">
        <h2 id="podman-baslik" class="card-title">Podman</h2>
        <div class="card-actions">
          <span v-if="readAt" class="meter-note">Son okuma {{ clock(readAt) }}</span>
          <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="podman-refresh" @click="load"><Icon name="refresh" :size="16" />Yenile</button>
        </div>
      </div>
      <p v-if="listError" class="form-error" role="alert" data-testid="podman-error">{{ list ? `Son okuma başarısız: ${listError}` : listError }}</p>
      <template v-if="list">
        <div v-if="list.runtime.ok" class="podman-facts">
          <StatusPill tone="ok" dot>Çalışıyor</StatusPill>
          <dl class="facts">
            <dt>Sürüm</dt>
            <dd>Podman {{ list.runtime.version || UNKNOWN }} · bu sunucu, rootful, systemd ile yönetilir</dd>
            <dt>Depolama</dt>
            <dd>{{ list.storage.size === null ? UNKNOWN : bytes(list.storage.size) }}</dd>
          </dl>
        </div>
        <p v-else class="notice notice-danger" role="alert" data-testid="podman-runtime-error">
          <Icon name="xcircle" class="notice-icon" /><span>{{ list.runtime.error || "Podman yanıt vermedi." }}</span>
        </p>
      </template>
      <p v-else-if="!listError" class="meter-note" role="status">Okunuyor…</p>
      <p class="meter-note">Salt okunur. Tek işlem temizlik. Uygulamalar ve servisleri <RouterLink to="/uygulamalar">Uygulamalar</RouterLink>'dadır.</p>
    </section>

    <section class="card cleanup" aria-labelledby="temizlik-baslik" :aria-busy="busy" data-testid="cleanup">
      <div class="card-head">
        <h2 id="temizlik-baslik" class="card-title">Temizlik</h2>
        <div class="card-actions">
          <button type="button" class="btn btn-secondary btn-sm" :disabled="cleanupLoading" data-testid="cleanup-refresh" @click="loadCleanup(true)"><Icon name="refresh" :size="16" />Yenile</button>
        </div>
      </div>
      <p class="meter-note">
        Hiçbir uygulamanın ve konteynerin kullanmadığı imajlar, ağlar ve birimler; kaldırılmış uygulamalardan kalan klasörler. Podman'ın varsayılan
        ağına ve bir uygulamanınkine dokunulmaz; her öge kaldırılmadan hemen önce yeniden denetlenir.
      </p>
      <p v-if="cleanupError" class="form-error" role="alert" data-testid="cleanup-error">{{ cleanupError }}</p>
      <p v-for="(h, i) in cleanup?.hatalar ?? []" :key="i" class="notice notice-warning" data-testid="cleanup-warning"><Icon name="alert" class="notice-icon" /><span>{{ h }}</span></p>
      <p v-if="busy" class="cleanup-run" role="status" data-testid="cleanup-running">
        <span class="spinner" aria-hidden="true"></span><span>Temizlik sürüyor<template v-if="step"> · {{ step }}</template></span>
        <button type="button" class="btn btn-secondary btn-sm" data-testid="cleanup-jobs" @click="openSurface('drawer')"><Icon name="pulse" :size="16" />İşlemleri göster</button>
      </p>
      <p v-if="result" class="notice" :class="'notice-' + result.tone" role="status" data-testid="cleanup-result">
        <Icon :name="result.tone === 'ok' ? 'check' : 'alert'" class="notice-icon" /><span>{{ result.text }}</span>
      </p>
      <template v-if="cleanup">
        <template v-for="g in GROUPS" :key="g.kind">
          <fieldset v-if="items[g.kind].length" class="cleanup-group" :data-tur="g.kind">
            <legend class="cleanup-legend">
              <label class="check-row">
                <input type="checkbox" :checked="allOf(g.kind)" :indeterminate="!allOf(g.kind) && items[g.kind].some(isSelected)" :disabled="busy" :data-hepsi="g.kind" @change="toggleAll(g.kind)" />
                <span>{{ g.title }} ({{ items[g.kind].length }})</span>
              </label>
            </legend>
            <ul class="cleanup-items">
              <li v-for="i in items[g.kind]" :key="i.value" class="cleanup-item" :data-oge="i.value">
                <label class="check-row">
                  <input type="checkbox" :checked="isSelected(i)" :disabled="busy" @change="toggle(i)" />
                  <span class="cell-stack">
                    <strong class="mono wrap">{{ i.label }}</strong>
                    <span class="cell-note">{{ i.detail }}</span>
                  </span>
                </label>
              </li>
            </ul>
          </fieldset>
        </template>
        <EmptyState v-if="!total" title="Temizlenecek bir şey yok" text="Bütün imajlar, ağlar ve birimler kullanılıyor; kaldırılmış bir uygulamadan klasör kalmamış." icon="check" />
        <div v-else class="cleanup-bar">
          <span class="meter-note" data-testid="cleanup-chosen">{{ chosen.length ? `${chosen.length} öge seçili${chosenSize ? ` · ${bytes(chosenSize)}` : ""}` : "Kaldırılacakları seçin." }}</span>
          <button type="button" class="btn btn-danger" :disabled="!chosen.length || busy" data-testid="cleanup-start" @click="ask"><Icon name="trash" :size="16" />Temizle…</button>
        </div>
      </template>
      <p v-else-if="!cleanupError" class="meter-note" role="status">Okunuyor…</p>
    </section>

    <section v-if="cleanup" class="card" aria-labelledby="disarida-baslik" data-testid="unmanaged">
      <h2 id="disarida-baslik" class="card-title">Obhut dışı konteynerler</h2>
      <ul v-if="cleanup.konteynerler.length" class="cleanup-items">
        <li v-for="c in cleanup.konteynerler" :key="c.ad" class="cleanup-item" :data-konteyner="c.ad">
          <span class="cell-stack">
            <strong class="wrap">{{ c.ad }} <span class="muted">· {{ c.durum || UNKNOWN }}</span></strong>
            <span class="mono wrap cell-note">{{ c.imaj || UNKNOWN }}</span>
            <span class="cell-note">{{ MANAGER[c.yonetici] }}</span>
          </span>
        </li>
      </ul>
      <p v-else class="card-text">Yok: bütün konteynerler bir uygulamanın.</p>
      <p class="meter-note">Salt okunur; Obhut bunları başlatmaz, durdurmaz ve kaldırmaz.</p>
    </section>

    <Tabs v-if="list" :tabs="TABS" label="Podman kaynakları" param="kaynak">
      <template #default="{ active }">
        <!-- images -->
        <section v-if="active === 'imajlar'" class="card resource-card" aria-label="İmajlar" data-testid="images">
          <p v-if="collectionError('images')" class="notice notice-warning" role="alert" data-testid="images-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("images") }}</span></p>
          <div v-else-if="list.images?.length" class="table-wrap">
            <table class="data-table resource-table">
              <thead>
                <tr><th scope="col">İmaj</th><th scope="col">Kimlik</th><th scope="col">Boyut</th><th scope="col">Oluşturma</th><th scope="col">Kullanan</th></tr>
              </thead>
              <tbody>
                <tr v-for="(i, n) in list.images" :key="`${i.id}:${i.name}:${n}`" :data-imaj="i.name">
                  <th scope="row" class="col-main">
                    <strong class="mono wrap"><span aria-hidden="true">{{ shortImage(i.name) }}</span><span class="sr-only">{{ i.name }}</span></strong>
                  </th>
                  <td data-label="Kimlik" class="mono">{{ shortId(i.id) || UNKNOWN }}</td>
                  <td data-label="Boyut" class="nowrap">{{ bytes(i.size) }}</td>
                  <td data-label="Oluşturma" class="nowrap">{{ date(i.created) }}</td>
                  <td data-label="Kullanan">
                    <span v-if="!i.used_by.length" class="muted">kullanılmıyor</span>
                    <span v-else class="used-by">
                      <template v-for="(u, k) in i.used_by" :key="u"><template v-if="k">, </template><RouterLink v-if="appNames.has(u)" :to="appRoute(u)">{{ u }}</RouterLink><span v-else>{{ u }}</span></template>
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="İmaj yok" text="Bir uygulama kurulunca burada görünür." icon="box" />
        </section>

        <!-- volumes -->
        <section v-else-if="active === 'birimler'" class="card resource-card" aria-label="Birimler" data-testid="volumes">
          <p class="meter-note">Birim (volume), Podman'ın konteynerden bağımsız sakladığı adlı veri alanıdır: konteyner kaldırılınca kalır. Uygulamaların verileri kendi klasörlerindedir (Dosyalar → Depolama).</p>
          <p v-if="collectionError('volumes')" class="notice notice-warning" role="alert" data-testid="volumes-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("volumes") }}</span></p>
          <div v-else-if="list.volumes?.length" class="table-wrap">
            <table class="data-table resource-table">
              <thead>
                <tr><th scope="col">Birim</th><th scope="col">Sürücü</th><th scope="col">Kullanan</th></tr>
              </thead>
              <tbody>
                <tr v-for="v in list.volumes" :key="v.name" :data-birim="v.name">
                  <th scope="row" class="col-main">
                    <strong class="mono wrap">{{ v.name }}</strong>
                    <span class="badges"><StatusPill :tone="v.managed ? 'ok' : 'neutral'">{{ v.managed ? "Obhut" : "Dışarıda" }}</StatusPill></span>
                  </th>
                  <td data-label="Sürücü">{{ v.driver || UNKNOWN }}</td>
                  <td data-label="Kullanan"><span :class="{ 'warn-text': !v.used_by.length }">{{ v.used_by.length ? v.used_by.join(", ") : "kullanılmıyor" }}</span></td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="Birim yok" text="Bir konteyner adlı bir birim kullanınca burada görünür." icon="box" />
        </section>

        <!-- networks -->
        <section v-else-if="active === 'aglar'" class="card resource-card" aria-label="Ağlar" data-testid="networks">
          <p class="meter-note">Her uygulama kendi köprüsündedir (ksl-…); portları Erişim → Adresler'de seçilen erişime göre açılır.</p>
          <p v-if="collectionError('networks')" class="notice notice-warning" role="alert" data-testid="networks-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("networks") }}</span></p>
          <div v-else-if="list.networks?.length" class="table-wrap">
            <table class="data-table resource-table">
              <thead>
                <tr><th scope="col">Ağ</th><th scope="col">Sürücü</th><th scope="col">Alt ağ</th><th scope="col">Kullanan</th></tr>
              </thead>
              <tbody>
                <tr v-for="net in list.networks" :key="net.name" :data-ag="net.name">
                  <th scope="row" class="col-main">
                    <strong class="mono wrap">{{ net.name }}</strong>
                    <span class="badges">
                      <StatusPill :tone="net.managed ? 'ok' : 'neutral'">{{ net.managed ? "Obhut" : "Sistem" }}</StatusPill>
                      <StatusPill v-if="net.internal" tone="accent">İç ağ</StatusPill>
                    </span>
                  </th>
                  <td data-label="Sürücü">{{ net.driver || UNKNOWN }}</td>
                  <td data-label="Alt ağ" class="mono wrap">{{ net.subnets.join(", ") || UNKNOWN }}</td>
                  <td data-label="Kullanan">{{ net.used_by.length ? net.used_by.join(", ") : UNKNOWN }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="Ağ yok" icon="globe" />
        </section>
      </template>
    </Tabs>

    <Modal :open="askOpen" title="Temizlensin mi?" :description="`${chosen.length} öge kalıcı olarak kaldırılır.`" @close="askOpen = false">
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
        <button type="button" class="btn btn-danger" :disabled="!word || sending" data-testid="cleanup-go" @click="confirm">{{ sending ? "Başlatılıyor…" : "Temizle" }}</button>
      </template>
    </Modal>
  </div>
</template>
