<!-- Sistem → Güncellemeler (DD-233, DD-260): the installed and the newest version with their build numbers,
     the state (güncel, yeni sürüm, denetlenemedi), "Yeniden denetle" (GET ?yenile=1, past the server's
     cache) and "Güncelle", which says what happens before it asks the server (tailnet only). The run is
     followed in the activity list (the "guncelleme" job) and the update read: when it ends well the
     installer has replaced Konsol's own files, so the page reloads itself; a failure is shown here.
     DD-277: when GitHub's build is of another generation (`yeni_nesil`), the server's notice stands where
     "Güncelle" would: that generation installs only on a clean operating system and is never an update. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import type { Tone } from "../../components/ui/types";
import { readUpdate, startUpdate } from "../../api/sistem";
import { live, serverNow } from "../../live";
import { UNKNOWN, dateTime, shortVersion, since } from "../../format";
import type { Guncelleme } from "../../api/sema";

const g = computed(() => live.guncelleme);
const loading = ref(false);
const readError = ref("");
const note = ref("");

async function load(fresh = false): Promise<Guncelleme | null> {
  loading.value = true;
  try {
    const value = await readUpdate(fresh);
    live.guncelleme = value;
    readError.value = "";
    return value;
  } catch (err) {
    readError.value = err instanceof Error ? err.message : String(err);
    return null;
  } finally {
    loading.value = false;
  }
}

const installed = (r: Guncelleme) => r.kurulu_surum || shortVersion(r.kurulu);
const offered = (r: Guncelleme) => r.son_surum || shortVersion(r.son);

async function recheck(): Promise<void> {
  note.value = "";
  const r = await load(true);
  if (!r) return;
  if (r.hata) note.value = `Sürüm denetlenemedi: ${r.hata}`;
  else if (r.yeni_nesil) note.value = "Obhut'un yeni bir nesli çıktı; temiz kurulum gerektirir.";
  else note.value = r.yeni ? `Yeni sürüm var: ${offered(r)}` : `Sürüm güncel: ${installed(r)}`;
}

const state = computed<{ text: string; tone: Tone } | null>(() => {
  const r = g.value;
  if (!r) return null;
  if (r.hata) return { text: "Denetlenemedi", tone: "warning" };
  if (r.yeni_nesil) return { text: "Yeni nesil çıktı", tone: "accent" };
  return r.yeni ? { text: "Yeni sürüm var", tone: "accent" } : { text: "Güncel", tone: "ok" };
});

// ---- the run
const job = computed(() => (live.islemler ?? []).find((j) => j.tur === "guncelleme") ?? null);
// Seen running in this page (started here, or found running): only then does its end reload the page.
const followed = ref(false);
const startedAt = ref(0);
const failure = ref("");
const finished = ref("");
const running = computed(() => job.value?.durum === "calisiyor" || g.value?.is.durum === "calisiyor" || (followed.value && !finished.value && !failure.value));
const stage = computed(() => (job.value?.durum === "calisiyor" ? job.value.adim : "") || (g.value?.is.durum === "calisiyor" ? g.value.is.asama : "") || "Başlatılıyor");
let reloadTimer: number | undefined;
let pollTimer: number | undefined;

/** The end of the run this page follows: the job's or the update read's, never an earlier run's. */
function ended(): { ok: boolean; message: string } | null {
  const fresh = (at: number | null | undefined) => !startedAt.value || (typeof at === "number" && at >= startedAt.value - 5);
  const j = job.value;
  if (j && j.durum !== "calisiyor" && fresh(j.bitis)) return { ok: j.durum === "tamam", message: j.adim };
  const is = g.value?.is;
  if (is && (is.durum === "tamam" || is.durum === "hata") && fresh(is.bitis) && !(j && j.durum === "calisiyor")) return { ok: is.durum === "tamam", message: is.mesaj };
  return null;
}

watch([() => job.value?.durum, () => job.value?.bitis, () => g.value?.is.durum, () => g.value?.is.bitis], () => {
  if (job.value?.durum === "calisiyor" || g.value?.is.durum === "calisiyor") followed.value = true;
  if (!followed.value || finished.value) return;
  const end = ended();
  if (!end) return;
  if (end.ok) {
    // The version the server runs now (the installer wrote it); then the page loads Konsol's new files.
    finished.value = "Güncelleme tamamlandı. Sayfa yenileniyor…";
    void load().then((r) => {
      if (r) finished.value = `Güncelleme tamamlandı: ${installed(r)}. Sayfa yenileniyor…`;
    });
    clearTimeout(reloadTimer);
    reloadTimer = window.setTimeout(() => location.reload(), 2500);
  } else {
    failure.value = `Güncelleme başarısız: ${end.message || "ayrıntı Günlük'te"}`;
    followed.value = false;
  }
}, { immediate: true });

// While it runs, the update is read every 5 s too: the installer restarts Konsol, and the stream may miss
// the job's end (a failed read just waits).
watch(running, (on) => {
  clearInterval(pollTimer);
  pollTimer = on ? window.setInterval(() => {
    if (!document.hidden) void readUpdate().then((r) => (live.guncelleme = r), () => undefined);
  }, 5000) : undefined;
}, { immediate: true });

// ---- the confirmation
const askOpen = ref(false);
const sending = ref(false);
const sendError = ref("");
const lock = computed(() => (g.value && !g.value.baslatilabilir ? "Güncelleme yalnız Tailscale adresinden başlatılır." : ""));
const canUpdate = computed(() => Boolean(g.value?.yeni && g.value.son && g.value.commit && g.value.baslatilabilir && !running.value));

function ask(): void {
  sendError.value = "";
  askOpen.value = true;
}

async function confirm(): Promise<void> {
  const r = g.value;
  if (!r?.son || !r.commit || sending.value) return;
  sending.value = true;
  sendError.value = "";
  try {
    await startUpdate(r.son, r.commit);
    askOpen.value = false;
    failure.value = "";
    finished.value = "";
    startedAt.value = serverNow();
    followed.value = true;
    note.value = "Güncelleme başladı; bu sayfa açık kalabilir.";
    live.guncelleme = { ...r, is: { durum: "calisiyor", asama: "İndiriliyor", hedef: r.son, mesaj: "", bitis: null } };
  } catch (err) {
    sendError.value = err instanceof Error ? err.message : String(err);
    void load();
  } finally {
    sending.value = false;
  }
}

onMounted(() => void load());
onBeforeUnmount(() => {
  clearTimeout(reloadTimer);
  clearInterval(pollTimer);
});
</script>

<template>
  <div class="system-tab" data-testid="updates-tab">
    <p v-if="readError" class="form-error" role="alert" data-testid="update-read-error">{{ readError }}</p>
    <section v-if="g" class="card" aria-labelledby="surum-baslik" data-testid="update">
      <div class="card-head">
        <h2 id="surum-baslik" class="card-title">Obhut sürümü</h2>
        <div v-if="state" class="card-actions"><StatusPill :tone="state.tone" data-testid="update-state">{{ state.text }}</StatusPill></div>
      </div>
      <dl class="facts" data-testid="update-facts">
        <dt>Kurulu</dt>
        <dd><strong>{{ installed(g) }}</strong> <span class="muted">yapı <span class="mono">{{ g.kurulu || UNKNOWN }}</span></span></dd>
        <dt>En yeni</dt>
        <dd v-if="g.son"><strong>{{ offered(g) }}</strong> <span class="muted">yapı <span class="mono">{{ g.son }}<template v-if="g.commit"> · {{ g.commit.slice(0, 7) }}</template></span></span></dd>
        <dd v-else>{{ UNKNOWN }}</dd>
        <dt>Son denetim</dt>
        <dd>{{ g.denetlendi ? `${dateTime(g.denetlendi)} (${since(g.denetlendi, serverNow())})` : UNKNOWN }}</dd>
      </dl>
      <p v-if="g.hata" class="notice notice-warning" role="note" data-testid="update-error">
        <Icon name="alert" class="notice-icon" /><span>Sürüm denetlenemedi: {{ g.hata }}</span>
      </p>
      <p v-if="g.yeni_nesil && !g.hata" class="notice" role="note" data-testid="update-generation">
        <Icon name="info" class="notice-icon" /><span>{{ g.yeni_nesil.metin }}</span>
      </p>
      <p v-if="g.is.durum === 'hata' && g.is.mesaj && !failure" class="notice notice-warning" role="note" data-testid="update-last-failure">
        <Icon name="alert" class="notice-icon" /><span>Son deneme başarısız: {{ g.is.mesaj }}</span>
      </p>
      <div class="action-line">
        <button type="button" class="btn btn-secondary" :disabled="loading || running" data-testid="update-check" @click="recheck">
          <Icon name="refresh" :size="16" />{{ loading ? "Denetleniyor…" : "Yeniden denetle" }}
        </button>
        <button v-if="g.yeni" type="button" class="btn btn-primary" :disabled="!canUpdate" :aria-describedby="lock ? 'guncelleme-kilit' : undefined" data-testid="update-start" @click="ask">
          <Icon name="update" :size="16" />{{ offered(g) }} sürümüne güncelle
        </button>
      </div>
      <p v-if="lock && g.yeni" id="guncelleme-kilit" class="notice" role="note" data-testid="update-lock">
        <Icon name="lock" class="notice-icon" /><span>{{ lock }}</span>
      </p>
      <p class="sr-only" role="status">{{ finished || note }}</p>
      <p v-if="note && !running && !finished" class="meter-note" aria-hidden="true" data-testid="update-note">{{ note }}</p>
    </section>
    <section v-else-if="!readError" class="card" aria-label="Güncellemeler">
      <EmptyState title="Sürüm bilgisi okunuyor" icon="update" />
    </section>

    <section v-if="running || finished" class="card update-run" aria-labelledby="calisan-guncelleme" data-testid="update-run">
      <h2 id="calisan-guncelleme" class="card-title">{{ finished ? "Güncelleme tamamlandı" : "Güncelleniyor" }}</h2>
      <p v-if="finished" class="notice notice-ok" data-testid="update-done"><Icon name="check" class="notice-icon" /><span>{{ finished }}</span></p>
      <template v-else>
        <p class="update-stage"><span class="spinner" aria-hidden="true"></span><strong data-testid="update-stage">{{ stage }}</strong></p>
        <p class="meter-note">Kod indirilir, sistem paketleri güncellenir ve servisler yeniden başlar; birkaç dakika sürebilir. Bu sayfa açık kalabilir; bitince kendini yeniler.</p>
      </template>
    </section>
    <p v-if="failure" class="notice notice-danger" role="alert" data-testid="update-failed"><Icon name="xcircle" class="notice-icon" /><span>{{ failure }}</span></p>

    <Modal :open="askOpen" :title="g ? `Sunucu ${offered(g)} sürümüne güncellensin mi?` : ''" :description="g ? `Kurulu: ${installed(g)} → ${offered(g)}` : ''" @close="askOpen = false">
      <ul v-if="g" class="modal-list">
        <li><Icon name="download" :size="18" /><span>Kod GitHub'dan indirilir (commit {{ (g.commit ?? "").slice(0, 7) }}).</span></li>
        <li><Icon name="box" :size="18" /><span>Sistem paketleri de güncellenir; birkaç dakika sürebilir.</span></li>
        <li><Icon name="refresh" :size="18" /><span>Konsol ve servisler yeniden başlar; bitince sayfa kendini yeniler.</span></li>
        <li v-if="g.is.durum === 'hata' && g.is.mesaj"><Icon name="info" :size="18" /><span>Son deneme başarısız: {{ g.is.mesaj }}</span></li>
      </ul>
      <p v-if="sendError" class="form-error" role="alert" data-testid="update-dialog-error">{{ sendError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus @click="askOpen = false">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="sending" data-testid="update-go" @click="confirm">{{ sending ? "Başlatılıyor…" : "Güncelle" }}</button>
      </template>
    </Modal>
  </div>
</template>
