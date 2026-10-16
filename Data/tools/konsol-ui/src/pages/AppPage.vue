<!-- An application's page (DD-258, phase 2; #/uygulamalar/<id>, e.g. konteyner:notlar): its name, state
     and actions, then Özet · Erişim · Depolama · Ayarlar · Günlük
     (?sekme=). Data from GET /api/konsol/uygulamalar/ayrinti; actions go to POST
     /api/konsol/uygulamalar/islem (202: the job shows in the activity drawer through "islemler", and the
     page reads the application again when that job ends). Durdur and Güncelle ask in a small dialog;
     Kaldır in a sheet with the typed word "onayla". A container's own detail (GET
     /api/konsol/konteynerler/ayrinti) is read beside it for the tabs: who manages it, its definition, its
     ports and its update state. "İmajı güncelle" is offered whenever the container's actions include it
     (Güncelle when a newer image is known) and says afterwards whether the image changed; a container made
     outside Konsol offers "Yönetime al". -->
<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { RouterLink, useRoute, useRouter } from "vue-router";
import { Icon, type IconName } from "../components/icons";
import AppIcon from "../components/AppIcon.vue";
import ConfirmWord from "../components/ui/ConfirmWord.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import Modal from "../components/ui/Modal.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import Tabs from "../components/ui/Tabs.vue";
import SummaryTab from "./app/SummaryTab.vue";
import AccessTab from "./app/AccessTab.vue";
import StorageTab from "./app/StorageTab.vue";
import SettingsTab from "./app/SettingsTab.vue";
import LogTab from "./app/LogTab.vue";
import { live, refreshApps } from "../live";
import { appState, openTarget, type AppAction } from "../apps";
import { usePageHead } from "../page";
import { updateQuery } from "../query";
import { readAppDetail, startAppAction } from "../api/konsol";
import { readContainer, readOperation, readUpdates, type ContainerDetail } from "../api/podman";
import { ApiError } from "../api/http";
import { addRoute } from "../sections";
import type { Islem, Uygulama, UygulamaAyrinti, UygulamaIslemi } from "../api/sema";

const TABS = [
  { id: "ozet", label: "Özet" },
  { id: "erisim", label: "Erişim" },
  { id: "depolama", label: "Depolama" },
  { id: "ayarlar", label: "Ayarlar" },
  { id: "gunluk", label: "Günlük" },
] as const;

const route = useRoute();
const router = useRouter();
const id = computed(() => (typeof route.params.id === "string" ? route.params.id : ""));

// ---- the application: GET …/ayrinti, with the live list's item until it answers
const detail = ref<UygulamaAyrinti | null>(null);
const missing = ref("");
const loadError = ref("");
let seq = 0;

async function load(): Promise<void> {
  const mine = ++seq;
  const wanted = id.value;
  try {
    const value = await readAppDetail(wanted);
    if (mine !== seq) return;
    detail.value = value;
    missing.value = "";
    loadError.value = "";
    void loadBox();
  } catch (err) {
    if (mine !== seq) return;
    const message = err instanceof Error ? err.message : String(err);
    if (err instanceof ApiError && (err.status === 404 || err.status === 400)) {
      detail.value = null;
      missing.value = message;
    } else loadError.value = message;
  }
}

// ---- the container's own detail, when the application's detail names a container
const box = ref<ContainerDetail | null>(null);
const boxLoading = ref(false);
const boxError = ref("");
let boxSeq = 0;

async function loadBox(): Promise<void> {
  const name = detail.value?.konteyner ? detail.value.uygulama.konteyner : null;
  const mine = ++boxSeq;
  if (!name) {
    box.value = null;
    boxLoading.value = false;
    return;
  }
  boxLoading.value = true;
  try {
    const value = await readContainer(name);
    if (mine !== boxSeq) return;
    box.value = value;
    boxError.value = "";
  } catch (err) {
    if (mine === boxSeq) boxError.value = err instanceof Error ? err.message : String(err);
  } finally {
    if (mine === boxSeq) boxLoading.value = false;
  }
}

// "Güncellemeleri denetle": the registries asked again (at most once a minute on the server).
const checking = ref(false);
const checkError = ref("");
async function checkUpdates(): Promise<void> {
  if (checking.value) return;
  checking.value = true;
  checkError.value = "";
  try {
    await readUpdates(true);
    await loadBox();
    void refreshApps();
  } catch (err) {
    checkError.value = err instanceof Error ? err.message : String(err);
  } finally {
    checking.value = false;
  }
}

const listItem = computed(() => live.uygulamalar?.items.find((a) => a.id === id.value) ?? null);
const app = computed<Uygulama | null>(() => (missing.value ? null : (detail.value?.uygulama ?? listItem.value)));
const name = computed(() => app.value?.ad ?? listItem.value?.ad ?? id.value);
const state = computed(() => (app.value ? appState(app.value) : null));

// The live list is read again when a job starts or ends and every minute: a change in this application's
// state there (started elsewhere, too) is a reason to read its detail again.
const signature = (a: Uygulama | null) => (a ? JSON.stringify([a.durum, a.eylemler, a.revizyon, a.guncelleme]) : "");
watch(
  () => signature(listItem.value),
  (now, before) => {
    if (before && now && now !== before && now !== signature(detail.value?.uygulama ?? null)) void load();
  },
);

const description = computed(() => {
  const a = app.value;
  if (!a) return missing.value ? "" : "Okunuyor…";
  const parts = [a.aciklama.replace(/\.\s*$/, "")];
  if (a.guncelleme === "guncel") parts.push("güncel");
  else if (a.guncelleme === "yeni") parts.push("yeni sürüm var");
  else if (a.guncelleme === "denetlenemedi") parts.push("sürüm denetlenemedi");
  return parts.filter(Boolean).join(" · ");
});

usePageHead(() => ({ title: name.value, parent: { label: "Uygulamalar", to: "/uygulamalar" } }));

// ---- actions
const open = computed(() => (app.value ? openTarget(app.value) : null));
const can = (action: AppAction) => Boolean(app.value?.eylemler.includes(action));
// The container's image can be pulled again even when no newer one is known (the old "İmajı güncelle").
const canImage = computed(() => !can("guncelle") && Boolean(box.value?.actions.includes("image-update")) && app.value?.durum !== "islemde");
const canAdopt = computed(() => Boolean(box.value?.source === "external" && box.value.actions.includes("adopt")));

const acting = ref<AppAction | null>(null);
const actionError = ref("");
const actionNote = ref("");
const confirmAction = ref<"durdur" | "guncelle" | null>(null);
const removeOpen = ref(false);
const removeConfirmed = ref(false);
const dialogOpen = computed(() => confirmAction.value !== null || removeOpen.value);

const DOING: Record<AppAction, string> = {
  baslat: "Başlatılıyor",
  durdur: "Durduruluyor",
  "yeniden-baslat": "Yeniden başlatılıyor",
  guncelle: "Güncelleniyor",
  kaldir: "Kaldırılıyor",
};

// The job an action started: the container broker's ("konteyner", the job id in the reply). The page reads
// the application again when it ends.
interface Tracked {
  tur: Islem["tur"];
  id: string;
  eylem: AppAction;
  seen: boolean;
  /** A finished job with the same id from before this action (still listed for a while). */
  before: number | null;
}
const tracked = ref<Tracked | null>(null);

function track(job: string | null, eylem: AppAction): void {
  if (!job) return;
  const old = (live.islemler ?? []).find((j) => j.tur === "konteyner" && j.id === job);
  tracked.value = { tur: "konteyner", id: job, eylem, seen: false, before: old && old.durum !== "calisiyor" ? (old.bitis ?? 0) : null };
}

// An image update says how it went: the same image, or the new version (the operation's result).
async function updateResult(t: Tracked, name: string): Promise<void> {
  try {
    const op = await readOperation(t.id);
    const r = op.result ?? {};
    const version = typeof r.version === "string" && r.version ? ` (${r.version})` : "";
    actionNote.value = r.changed === false ? `${name}: imaj zaten güncel.` : `${name}: imaj güncellendi${version}.`;
  } catch {
    actionNote.value = `${name}: güncelleme bitti.`;
  }
}

watch(
  () => live.islemler,
  (jobs) => {
    const t = tracked.value;
    if (!t || !jobs) return;
    const job = jobs.find((j) => j.tur === t.tur && j.id === t.id);
    if (job?.durum === "calisiyor") {
      t.seen = true;
      return;
    }
    const ended = job ? t.seen || (job.bitis ?? 0) !== t.before : t.seen;
    if (!ended) return;
    tracked.value = null;
    if (job?.durum === "hata") actionError.value = job.adim ? `İşlem başarısız: ${job.adim}` : "İşlem başarısız oldu.";
    actionNote.value = "";
    if (job?.durum === "tamam" && t.eylem === "guncelle" && t.tur === "konteyner") void updateResult(t, app.value?.ad ?? id.value);
    void refreshApps();
    // A removed application has no page any more: back to the list (the drawer keeps the finished job).
    if (job?.durum === "tamam" && t.eylem === "kaldir") {
      void router.replace("/uygulamalar");
      return;
    }
    void load();
  },
);

function body(a: Uygulama, eylem: AppAction): UygulamaIslemi {
  const out: UygulamaIslemi = { id: a.id, eylem };
  if (a.revizyon !== null) out.revizyon = a.revizyon;
  return out;
}

async function run(eylem: AppAction): Promise<boolean> {
  const a = app.value;
  if (!a || acting.value) return false;
  acting.value = eylem;
  actionError.value = "";
  actionNote.value = "";
  try {
    const started = await startAppAction(body(a, eylem));
    track(started.is, eylem);
    actionNote.value = `${DOING[eylem]}; ilerlemesi İşlemler'de görünür.`;
    void load();
    void refreshApps();
    return true;
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err);
    return false;
  } finally {
    acting.value = null;
  }
}

function ask(action: "durdur" | "guncelle"): void {
  actionError.value = "";
  confirmAction.value = action;
}

async function confirm(): Promise<void> {
  const action = confirmAction.value;
  if (!action) return;
  if (await run(action)) confirmAction.value = null;
}

function askRemove(): void {
  actionError.value = "";
  removeConfirmed.value = false;
  removeOpen.value = true;
}

async function confirmRemove(): Promise<void> {
  if (!removeConfirmed.value) return;
  if (await run("kaldir")) removeOpen.value = false;
}

function closeDialogs(): void {
  if (acting.value) return;
  confirmAction.value = null;
  removeOpen.value = false;
  actionError.value = "";
}

const confirmText = computed(() => {
  const a = app.value;
  if (!a || !confirmAction.value) return null;
  if (confirmAction.value === "durdur") {
    const items: [IconName, string][] = [["stop", "Konteyner durur. Konsol'un yönettiği bir konteyner sunucu yeniden başlasa da kapalı kalır."]];
    return { title: `${a.ad} durdurulsun mu?`, sub: "Kurulu kalır; istediğinizde başlatırsınız.", go: "Durdur", items };
  }
  const u = box.value?.update;
  const sub = u?.state === "var" ? `Yeni sürüm yayınlanmış${u.channel ? " · " + u.channel : ""}` : "Kendiliğinden güncelleme yoktur; yalnız siz onaylayınca.";
  const items: [IconName, string][] = [
    ["download", "İmajın etiketi yeniden çekilir ve yeni özetle karşılaştırılır."],
    ["refresh", "Özet değiştiyse konteyner yeni imajla yeniden oluşturulur; kısa bir kesinti olabilir."],
    ["folder", "Kalıcı veriler bağlamalarda kalır; konteynerin yazılabilir katmanı silinir."],
  ];
  return { title: `${a.ad} güncellensin mi?`, sub, go: "Güncelle", items };
});

const REMOVE_ITEMS: readonly [IconName, string][] = [
  ["box", "Konteyner durdurulur ve kaldırılır; Konsol'da bir tanımı varsa o da silinir."],
  ["folder", "Adlı birimler ve imaj kalır; Gelişmiş → Podman'dan silinir. Sunucu klasörlerine dokunulmaz."],
];

function showAccess(): void {
  updateQuery(router, { sekme: "erisim" });
}

// Ayarlar is kept mounted after its first visit (per application), so its draft outlives a tab switch.
const settingsKept = ref(false);
watch(
  () => route.query.sekme,
  (tab) => {
    if (tab === "ayarlar") settingsKept.value = true;
  },
  { immediate: true },
);

function reloadAll(): void {
  void load();
  void refreshApps();
}

// Another application (the palette, Back): start over with its own data.
watch(
  id,
  () => {
    detail.value = null;
    settingsKept.value = route.query.sekme === "ayarlar";
    box.value = null;
    boxError.value = "";
    checkError.value = "";
    boxSeq += 1;
    missing.value = "";
    loadError.value = "";
    tracked.value = null;
    actionError.value = "";
    actionNote.value = "";
    confirmAction.value = null;
    removeOpen.value = false;
    void load();
  },
  { immediate: true },
);
</script>

<template>
  <div class="page-body app-page">
    <header class="app-head" :data-uygulama="id">
      <div class="app-head-main">
        <AppIcon v-if="app" :app="app" size="lg" />
        <div class="app-head-text">
          <div class="app-title">
            <h1 tabindex="-1">{{ name }}</h1>
            <StatusPill v-if="state" :tone="state.tone" :dot="app?.durum === 'calisiyor'" data-testid="app-state">{{ state.text }}</StatusPill>
          </div>
          <p class="page-desc" data-testid="app-desc">{{ description }}</p>
        </div>
      </div>
      <div v-if="app" class="app-actions" data-testid="app-actions">
        <a
          v-if="open"
          class="btn btn-primary"
          :href="open"
          target="_blank"
          rel="noopener noreferrer"
          :aria-label="`${app.ad} uygulamasını yeni sekmede aç`"
          data-eylem="ac"
        >
          Aç<Icon name="open" :size="16" />
        </a>
        <button v-if="can('yeniden-baslat')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="yeniden-baslat" @click="run('yeniden-baslat')">
          <Icon name="refresh" :size="16" />{{ acting === "yeniden-baslat" ? "Başlatılıyor…" : "Yeniden başlat" }}
        </button>
        <button v-if="can('durdur')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="durdur" @click="ask('durdur')">
          <Icon name="stop" :size="16" />Durdur
        </button>
        <button v-if="can('baslat')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="baslat" @click="run('baslat')">
          <Icon name="play" :size="16" />{{ acting === "baslat" ? "Başlatılıyor…" : "Başlat" }}
        </button>
        <button v-if="can('guncelle')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="guncelle" @click="ask('guncelle')">
          <Icon name="update" :size="16" />Güncelle
        </button>
        <button v-else-if="canImage" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="imaj-guncelle" @click="ask('guncelle')">
          <Icon name="update" :size="16" />İmajı güncelle
        </button>
        <RouterLink v-if="canAdopt && box" :to="addRoute('sahiplen', { ad: box.name })" class="btn btn-secondary" data-eylem="yonetime-al">
          <Icon name="key" :size="16" />Yönetime al
        </RouterLink>
        <button v-if="can('kaldir')" type="button" class="btn btn-danger-quiet" :disabled="acting !== null" data-eylem="kaldir" @click="askRemove">
          <Icon name="trash" :size="16" />Kaldır…
        </button>
      </div>
    </header>

    <p v-if="actionError && !dialogOpen" class="notice notice-danger" role="alert" data-testid="action-error">{{ actionError }}</p>
    <p class="action-note" role="status" data-testid="action-note">{{ actionNote }}</p>
    <p v-if="loadError" class="notice notice-warning" role="alert">{{ loadError }}</p>
    <p v-if="boxError" class="notice notice-warning" role="alert" data-testid="box-error">Konteyner ayrıntısı okunamadı: {{ boxError }}</p>

    <section v-if="missing" class="card" aria-label="Uygulama bulunamadı">
      <EmptyState title="Bu uygulama yok" :text="missing" icon="apps">
        <RouterLink to="/uygulamalar" class="btn btn-secondary">Uygulamalar'a dön</RouterLink>
      </EmptyState>
    </section>

    <Tabs v-else-if="app" :tabs="TABS" :label="`${app.ad} bölümleri`" param="sekme">
      <template #default="{ active }">
        <SummaryTab v-if="active === 'ozet'" :app="app" :detail="detail" :box="box" :checking="checking" :check-error="checkError" @access="showAccess" @check="checkUpdates" />
        <AccessTab v-else-if="active === 'erisim'" :row="detail?.erisim ?? null" :app="app" :box="box" />
        <StorageTab v-else-if="active === 'depolama'" :detail="detail" />
        <LogTab v-else-if="active === 'gunluk'" :app="app" />
        <!-- Ayarlar stays once opened, hidden on the other tabs, so a draft survives a look at them. -->
        <SettingsTab
          v-if="active === 'ayarlar' || settingsKept"
          :hidden="active !== 'ayarlar'"
          :key="app.id"
          :box="box"
          :box-loading="boxLoading || (!detail && !missing)"
          @changed="reloadAll"
          @reload="loadBox"
        />
      </template>
    </Tabs>

    <Modal :open="confirmAction !== null" :title="confirmText?.title ?? ''" :description="confirmText?.sub" @close="closeDialogs">
      <ul v-if="confirmText" class="modal-list">
        <li v-for="(item, i) in confirmText.items" :key="i"><Icon :name="item[0]" :size="18" /><span>{{ item[1] }}</span></li>
      </ul>
      <p v-if="actionError" class="form-error" role="alert" data-testid="dialog-error">{{ actionError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus :disabled="acting !== null" @click="closeDialogs">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="acting !== null" data-onay="evet" @click="confirm">
          {{ acting ? "Gönderiliyor…" : confirmText?.go }}
        </button>
      </template>
    </Modal>

    <Modal
      :open="removeOpen"
      variant="sheet"
      :title="app ? `${app.ad} kaldırılsın mı?` : ''"
      description="Konteyner kaldırılır."
      @close="closeDialogs"
    >
      <ul class="modal-list">
        <li v-for="(item, i) in REMOVE_ITEMS" :key="i"><Icon :name="item[0]" :size="18" /><span>{{ item[1] }}</span></li>
      </ul>
      <ConfirmWord v-model:confirmed="removeConfirmed" />
      <p v-if="actionError" class="form-error" role="alert" data-testid="dialog-error">{{ actionError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="acting !== null" @click="closeDialogs">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!removeConfirmed || acting !== null" data-onay="kaldir" @click="confirmRemove">
          {{ acting === "kaldir" ? "Gönderiliyor…" : "Kaldır" }}
        </button>
      </template>
    </Modal>
  </div>
</template>
