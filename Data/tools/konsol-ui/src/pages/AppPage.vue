<!-- An application's page (DD-258, phase 2; #/uygulamalar/<id>, e.g. paket:torrent, konteyner:gezgin,
     yerlesik:paylasim): its name, state and actions, then Özet · Erişim · Depolama · Ayarlar · Günlük
     (?sekme=). Data from GET /api/konsol/uygulamalar/ayrinti; actions go to POST
     /api/konsol/uygulamalar/islem (202: the job shows in the activity drawer through "islemler", and the
     page reads the application again when that job ends). Durdur and Güncelle ask in a small dialog;
     Kaldır in a sheet with the typed word "onayla". -->
<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { RouterLink, useRoute, useRouter } from "vue-router";
import { Icon, iconOf, type IconName } from "../components/icons";
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
import { KIND_TEXT, appState, openTarget, type AppAction } from "../apps";
import { usePageHead } from "../page";
import { updateQuery } from "../query";
import { readAppDetail, startAppAction } from "../api/konsol";
import { ApiError } from "../api/http";
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
  } catch (err) {
    if (mine !== seq) return;
    const message = err instanceof Error ? err.message : String(err);
    if (err instanceof ApiError && (err.status === 404 || err.status === 400)) {
      detail.value = null;
      missing.value = message;
    } else loadError.value = message;
  }
}

const listItem = computed(() => live.uygulamalar?.items.find((a) => a.id === id.value) ?? null);
const app = computed<Uygulama | null>(() => (missing.value ? null : (detail.value?.uygulama ?? listItem.value)));
const name = computed(() => app.value?.ad ?? listItem.value?.ad ?? id.value);
const state = computed(() => (app.value ? appState(app.value) : null));

// The live list is read again when a job starts or ends and every minute: a change in this application's
// state there (started elsewhere, too) is a reason to read its detail again.
const signature = (a: Uygulama | null) => (a ? JSON.stringify([a.durum, a.islem, a.eylemler, a.revizyon, a.guncelleme]) : "");
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
  if (a.tur === "paket") parts.push(KIND_TEXT.paket);
  if (a.guncelleme === "guncel") parts.push("güncel");
  else if (a.guncelleme === "yeni") parts.push("yeni sürüm var");
  else if (a.guncelleme === "denetlenemedi") parts.push("sürüm denetlenemedi");
  return parts.filter(Boolean).join(" · ");
});

usePageHead(() => ({ title: name.value, parent: { label: "Uygulamalar", to: "/uygulamalar" } }));

// ---- actions
const open = computed(() => (app.value ? openTarget(app.value) : null));
const can = (action: AppAction) => Boolean(app.value?.eylemler.includes(action));

const acting = ref<AppAction | null>(null);
const actionError = ref("");
const actionNote = ref("");
const confirmAction = ref<"durdur" | "guncelle" | null>(null);
const removeOpen = ref(false);
const removeData = ref(false);
const removeConfirmed = ref(false);
const dialogOpen = computed(() => confirmAction.value !== null || removeOpen.value);

const DOING: Record<AppAction, string> = {
  baslat: "Başlatılıyor",
  durdur: "Durduruluyor",
  "yeniden-baslat": "Yeniden başlatılıyor",
  guncelle: "Güncelleniyor",
  kaldir: "Kaldırılıyor",
};

// The job an action started: an App Store package's engine job ("modul", the package id) or the container
// broker's ("konteyner", the job id in the reply). The page reads the application again when it ends.
interface Tracked {
  tur: Islem["tur"];
  id: string;
  seen: boolean;
  /** A finished job of the same package from before this action (still listed for a while). */
  before: number | null;
}
const tracked = ref<Tracked | null>(null);

function track(a: Uygulama, job: string | null): void {
  const target = job ? { tur: "konteyner" as const, id: job } : a.modul ? { tur: "modul" as const, id: a.modul } : null;
  if (!target) return;
  const old = (live.islemler ?? []).find((j) => j.tur === target.tur && j.id === target.id);
  tracked.value = { ...target, seen: false, before: old && old.durum !== "calisiyor" ? (old.bitis ?? 0) : null };
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
    void load();
    void refreshApps();
  },
);

function body(a: Uygulama, eylem: AppAction): UygulamaIslemi {
  const out: UygulamaIslemi = { id: a.id, eylem };
  if (a.revizyon !== null) out.revizyon = a.revizyon;
  if (eylem === "kaldir") out.veri = a.tur === "paket" && removeData.value;
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
    track(a, started.is);
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
  removeData.value = false;
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

const isPackage = computed(() => app.value?.tur === "paket");

const confirmText = computed(() => {
  const a = app.value;
  if (!a || !confirmAction.value) return null;
  const pkg = a.tur === "paket";
  if (confirmAction.value === "durdur") {
    // A package says in its own words what stopping interrupts (konsol.json durdur_notu).
    const note = pkg ? a.metinler?.durdur ?? "" : "";
    const items: [IconName, string][] = [
      ...(note ? ([["pulse", note]] as [IconName, string][]) : []),
      ["stop", pkg ? "Açılışta da kapalı kalır; başlatılana kadar çalışmaz." : "Konteyner durur. Konsol'un yönettiği bir konteyner sunucu yeniden başlasa da kapalı kalır."],
    ];
    return { title: `${a.ad} durdurulsun mu?`, sub: "Kurulu kalır; istediğinizde başlatırsınız.", go: "Durdur", items };
  }
  const items: [IconName, string][] = pkg
    ? [
        ["download", "Kanalın şu an gösterdiği imaj indirilir; birkaç dakika sürebilir."],
        ["refresh", a.durum === "calisiyor" ? "Uygulama yeni imajla yeniden başlar; kısa bir kesinti olabilir." : "Uygulama durmuş; başlattığınızda yeni imajla açılır."],
        ["shield", "Açılmazsa önceki imaja dönülür; uygulamanın verisi korunur."],
      ]
    : [
        ["download", "İmajın etiketi yeniden çekilir ve yeni özetle karşılaştırılır."],
        ["refresh", "Özet değiştiyse konteyner yeni imajla yeniden oluşturulur; kısa bir kesinti olabilir."],
        ["folder", "Kalıcı veriler bağlamalarda kalır; konteynerin yazılabilir katmanı silinir."],
      ];
  return { title: `${a.ad} güncellensin mi?`, sub: "Kendiliğinden güncelleme yoktur; yalnız siz onaylayınca.", go: "Güncelle", items };
});

// A package names what removal takes away and what its data switch deletes or keeps (konsol.json kaldir),
// as App Store does; the general words stand in only when it says nothing.
const removeTexts = computed(() => (isPackage.value ? app.value?.metinler ?? null : null));
const removeItems = computed<[IconName, string][]>(() => {
  if (!isPackage.value) {
    return [
      ["box", "Konteyner durdurulur ve kaldırılır; Konsol'da bir tanımı varsa o da silinir."],
      ["folder", "Adlı birimler ve imaj kalır; Podman sayfasından silinir. Sunucu klasörlerine dokunulmaz."],
    ];
  }
  const own = (removeTexts.value?.kaldir ?? []).filter((p) => p.length === 2 && p[1]);
  return [
    ...(own.length
      ? own.map((p): [IconName, string] => [iconOf(p[0] ?? ""), p[1] ?? ""])
      : ([["box", "Uygulama durur ve kaldırılır; sayfası ve açtığı adresler gider."]] as [IconName, string][])),
    ["folder", "Kullanıcı alanındaki dosyalarınıza dokunulmaz."],
  ];
});
const removeDataLabel = computed(() => removeTexts.value?.veri_etiket || "Verilerini de sil");
const removeDataNote = computed(() => {
  const t = removeTexts.value;
  if (t?.veri_silinir && t.veri_kalir) return `${t.veri_silinir} İşaretlemezseniz: ${t.veri_kalir}`;
  return "İşaretlerseniz uygulamanın kendi verisi de silinir. İşaretlemezseniz veri sunucuda kalır.";
});

function showAccess(): void {
  updateQuery(router, { sekme: "erisim" });
}

// Another application (the palette, Back): start over with its own data.
watch(
  id,
  () => {
    detail.value = null;
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
          :href="open.href"
          :target="open.external ? '_blank' : undefined"
          :rel="open.external ? 'noopener noreferrer' : undefined"
          :aria-label="open.external ? `${app.ad} uygulamasını yeni sekmede aç` : `${app.ad} sayfasını aç`"
          data-eylem="ac"
        >
          Aç<Icon v-if="open.external" name="open" :size="16" />
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
        <button v-if="can('kaldir')" type="button" class="btn btn-danger-quiet" :disabled="acting !== null" data-eylem="kaldir" @click="askRemove">
          <Icon name="trash" :size="16" />Kaldır…
        </button>
      </div>
    </header>

    <p v-if="actionError && !dialogOpen" class="notice notice-danger" role="alert" data-testid="action-error">{{ actionError }}</p>
    <p class="action-note" role="status" data-testid="action-note">{{ actionNote }}</p>
    <p v-if="loadError" class="notice notice-warning" role="alert">{{ loadError }}</p>

    <section v-if="missing" class="card" aria-label="Uygulama bulunamadı">
      <EmptyState title="Bu uygulama yok" :text="missing" icon="apps">
        <RouterLink to="/uygulamalar" class="btn btn-secondary">Uygulamalar'a dön</RouterLink>
      </EmptyState>
    </section>

    <Tabs v-else-if="app" :tabs="TABS" :label="`${app.ad} bölümleri`" param="sekme">
      <template #default="{ active }">
        <SummaryTab v-if="active === 'ozet'" :app="app" :detail="detail" @access="showAccess" />
        <AccessTab v-else-if="active === 'erisim'" :row="detail?.erisim ?? null" :app="app" />
        <StorageTab v-else-if="active === 'depolama'" :detail="detail" />
        <SettingsTab v-else-if="active === 'ayarlar'" :app="app" />
        <LogTab v-else-if="active === 'gunluk'" :app="app" />
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
      :description="isPackage ? 'Bu bir App Store uygulaması; App Store\'dan da kaldırılır.' : 'Konteyner kaldırılır.'"
      @close="closeDialogs"
    >
      <ul class="modal-list">
        <li v-for="(item, i) in removeItems" :key="i"><Icon :name="item[0]" :size="18" /><span>{{ item[1] }}</span></li>
      </ul>
      <label v-if="isPackage" class="check-option" data-testid="remove-data">
        <input v-model="removeData" type="checkbox" />
        <span>
          <strong>{{ removeDataLabel }}</strong>
          <small>{{ removeDataNote }}</small>
        </span>
      </label>
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
