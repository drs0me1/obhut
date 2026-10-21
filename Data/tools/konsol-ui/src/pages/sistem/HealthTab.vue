<!-- Sistem → Sağlık (DD-293): only what needs attention. The health checks (live.saglik, cached 30 s by the
     server) as one line of counts, the ones with a problem listed under it; "Tüm denetimler" shows every check
     in a table, problems first. Then "Denetle ve onar" (DD-239): the last report in one line (which mode, when,
     who ran it) with its state, the steps with a problem or a repair listed; "Tüm adımlar" shows every step with
     the run's facts. "Denetle" starts at once and "Onar" after a confirmation, both only from the tailnet. While
     a run goes on its report is read every 2 s (the run may restart Caddy or Konsol: a failed read just waits)
     and the line says how far it got. "Onarım kaydı" (A7) opens master-onar's log (?kayit=72s|7g). -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import type { Tone } from "../../components/ui/types";
import RepairLogSheet from "./RepairLogSheet.vue";
import { readRepairReport, startRepairRun } from "../../api/sistem";
import { checkLevel, live, serverNow, type Level } from "../../live";
import { useQueryParam } from "../../query";
import { UNKNOWN, clock, dateTime, since } from "../../format";
import type { Onarim, OnarimAdimi } from "../../api/sema";

// ---- the checks
const LEVEL: Record<Level, { text: string; tone: Tone; rank: number }> = {
  danger: { text: "Sorun var", tone: "danger", rank: 0 },
  warning: { text: "Dikkat", tone: "warning", rank: 1 },
  ok: { text: "Sorunsuz", tone: "ok", rank: 2 },
};
const checks = computed(() =>
  (live.saglik?.checks ?? [])
    .map((c, i) => ({ c, i, level: LEVEL[checkLevel(c.status)] }))
    .sort((a, b) => a.level.rank - b.level.rank || a.i - b.i),
);
const counts = computed(() => {
  const out = { danger: 0, warning: 0, ok: 0 };
  for (const c of live.saglik?.checks ?? []) out[checkLevel(c.status)] += 1;
  return out;
});
const overall = computed(() => {
  if (!live.saglik) return null;
  const { danger, warning } = counts.value;
  return danger ? LEVEL.danger : warning ? LEVEL.warning : { ...LEVEL.ok, text: "Sağlıklı" };
});
// Only the checks that need attention are listed; the toggle shows them all.
const attention = computed(() => checks.value.filter((x) => x.level.rank < LEVEL.ok.rank));
const allChecks = ref(false);
const countLine = computed(() => {
  const { danger, warning, ok } = counts.value;
  return [danger ? `${danger} sorun` : "", warning ? `${warning} uyarı` : "", `${ok} sorunsuz`].filter(Boolean).join(" · ");
});
const now = ref(serverNow());
let clockTimer: number | undefined;

// ---- denetle ve onar
const repair = ref<Onarim | null>(null);
const repairFailed = ref(false);
const askOpen = ref(false);
const starting = ref<"" | "onar" | "denetle">("");
const startError = ref("");
const note = ref("");
let pollTimer: number | undefined;

async function loadRepair(): Promise<void> {
  try {
    repair.value = await readRepairReport();
    repairFailed.value = false;
  } catch {
    // A run may restart Konsol; the next read tries again.
    repairFailed.value = true;
  }
  schedule();
}

const repairJob = computed(() => (live.islemler ?? []).find((j) => j.tur === "onarim") ?? null);
const running = computed(() => repair.value?.calisiyor === true || repairJob.value?.durum === "calisiyor" || repair.value?.rapor?.durum === "calisiyor");

let alive = true;
function schedule(): void {
  clearTimeout(pollTimer);
  pollTimer = undefined;
  if (alive && running.value) pollTimer = window.setTimeout(() => {
    if (document.hidden) schedule();
    else void loadRepair();
  }, 2000);
}

// "… başladı" belongs to the run it announced: it goes when that run ends.
watch(running, (on, was) => {
  if (was && !on) note.value = "";
});

// The activity list says a run started or ended (here, in another tab or over SSH): read the report again.
watch(() => (repairJob.value ? `${repairJob.value.durum}:${repairJob.value.bitis ?? ""}` : ""), (next, before) => {
  if (next !== before) void loadRepair();
});

const lock = computed(() => {
  const r = repair.value;
  if (!r) return repairFailed.value ? "Onarım durumu okunamadı." : "";
  if (!r.baslatilabilir) return "Onarım yalnız Tailscale adresinden başlatılır.";
  if (!r.kurulu) return "Onarım aracı kurulu değil; kurulumu bir kez yeniden çalıştırın.";
  return "";
});
const disabled = computed(() => !repair.value || Boolean(lock.value) || running.value || starting.value !== "");

async function start(kip: "onar" | "denetle"): Promise<void> {
  if (starting.value) return;
  starting.value = kip;
  startError.value = "";
  note.value = "";
  try {
    await startRepairRun(kip);
    askOpen.value = false;
    note.value = kip === "onar" ? "Denetim ve onarım başladı." : "Denetim başladı.";
    if (repair.value) repair.value = { ...repair.value, calisiyor: true, rapor: null };
    schedule();
    void loadRepair();
  } catch (err) {
    startError.value = err instanceof Error ? err.message : String(err);
  } finally {
    starting.value = "";
  }
}

function askRepair(): void {
  startError.value = "";
  askOpen.value = true;
}

// ---- the report
const report = computed(() => repair.value?.rapor ?? null);
const SOURCE: Record<string, string> = { konsol: "Konsol", terminal: "SSH (sudo master-onar)" };
const STEP: Record<OnarimAdimi["durum"], { text: string; tone: Tone }> = {
  ok: { text: "Sorunsuz", tone: "ok" },
  onarildi: { text: "Onarıldı", tone: "accent" },
  sorun: { text: "Sorun var", tone: "warning" },
  hata: { text: "Hata", tone: "danger" },
  atlandi: { text: "Atlandı", tone: "neutral" },
  calisiyor: { text: "Denetleniyor…", tone: "accent" },
};
const step = (s: OnarimAdimi) => STEP[s.durum] ?? { text: s.durum, tone: "neutral" as Tone };
const reportState = computed<{ text: string; tone: Tone } | null>(() => {
  const r = report.value;
  if (!r) return null;
  if (r.durum === "calisiyor") return { text: "Sürüyor", tone: "accent" };
  if (r.durum === "hata") return r.yarida ? { text: "Yarıda kaldı", tone: "danger" } : { text: "Sorun var", tone: "danger" };
  const open = r.adimlar.filter((s) => s.durum === "sorun" || s.durum === "hata").length;
  return open ? { text: `Tamamlandı · ${open} sorun`, tone: "warning" } : { text: "Tamamlandı", tone: "ok" };
});
const head = computed(() => {
  const r = report.value;
  if (running.value && (!r || r.durum === "calisiyor")) return r?.kip === "denetle" ? "Denetim sürüyor…" : "Denetim ve onarım sürüyor…";
  if (!r) return repair.value ? "Henüz denetim yapılmadı." : repairFailed.value ? "Onarım durumu okunamadı." : "Okunuyor…";
  return `Son ${r.kip === "denetle" ? "denetim" : "onarım"}: ${dateTime(r.bitis || r.baslangic)} · ${SOURCE[r.kaynak] ?? r.kaynak ?? UNKNOWN}`;
});
// The steps with a problem or a repair are listed; the toggle shows every step with the run's facts.
const OPEN = new Set<OnarimAdimi["durum"]>(["hata", "sorun", "onarildi"]);
const openSteps = computed(() => (report.value?.adimlar ?? []).filter((s) => OPEN.has(s.durum)));
const allSteps = ref(false);
const stepLine = computed(() => {
  const r = report.value;
  if (!r) return "";
  const steps = r.adimlar;
  if (r.durum === "calisiyor") {
    const current = steps.find((s) => s.durum === "calisiyor");
    const done = steps.length - (current ? 1 : 0);
    return [done ? `${done} adım bitti` : "İlk adım başlıyor", current ? `şimdi: ${current.ad}` : ""].filter(Boolean).join(" · ");
  }
  const n = (d: OnarimAdimi["durum"]) => steps.filter((s) => s.durum === d).length;
  if (steps.length && n("ok") === steps.length) return `${steps.length} adımın hepsi sorunsuz`;
  return [`${steps.length} adım`, n("ok") ? `${n("ok")} sorunsuz` : "", n("onarildi") ? `${n("onarildi")} onarıldı` : "",
    n("atlandi") ? `${n("atlandi")} atlandı` : ""].filter(Boolean).join(" · ");
});

// ---- the repair log's sheet (Onarım kaydı)
const logSpan = useQueryParam<"" | "72s" | "7g">("kayit", ["", "72s", "7g"], "");

onMounted(() => {
  void loadRepair();
  clockTimer = window.setInterval(() => (now.value = serverNow()), 30000);
});
onBeforeUnmount(() => {
  alive = false;
  clearTimeout(pollTimer);
  clearInterval(clockTimer);
});
watch(() => live.offset, () => (now.value = serverNow()));
</script>

<template>
  <div class="system-tab" data-testid="health-tab">
    <section class="card" aria-labelledby="denetim-baslik" data-testid="checks">
      <div class="card-head">
        <div class="health-head">
          <h2 id="denetim-baslik" class="card-title">Sağlık denetimleri</h2>
          <p v-if="live.saglik" class="meter-note" data-testid="checks-read">
            {{ countLine }} · son denetim {{ clock(live.saglik.read_at) }} ({{ since(live.saglik.read_at, now) }})
          </p>
        </div>
        <div v-if="overall" class="card-actions"><StatusPill :tone="overall.tone" :dot="overall.tone === 'ok'">{{ overall.text }}</StatusPill></div>
      </div>
      <template v-if="live.saglik">
        <template v-if="checks.length">
          <div v-if="allChecks" id="saglik-tum-denetimler" class="table-wrap" data-testid="checks-all">
            <table class="data-table">
              <thead>
                <tr>
                  <th scope="col">Denetim</th>
                  <th scope="col">Durum</th>
                  <th scope="col">Ayrıntı</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="x in checks" :key="x.c.id" :data-denetim="x.c.id" :data-durum="x.c.status">
                  <th scope="row" class="col-main"><strong>{{ x.c.name || x.c.id }}</strong></th>
                  <td data-label="Durum"><StatusPill :tone="x.level.tone">{{ x.level.text }}</StatusPill></td>
                  <td data-label="Ayrıntı" class="wrap">{{ x.c.detail || UNKNOWN }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <ul v-else-if="attention.length" class="health-list" aria-label="Dikkat isteyen denetimler" data-testid="check-problems">
            <li v-for="x in attention" :key="x.c.id" class="health-item" :data-denetim="x.c.id" :data-durum="x.c.status">
              <StatusPill :tone="x.level.tone">{{ x.level.text }}</StatusPill>
              <span class="health-item-text">
                <strong>{{ x.c.name || x.c.id }}</strong>
                <span class="cell-note">{{ x.c.detail || UNKNOWN }}</span>
              </span>
            </li>
          </ul>
          <button type="button" class="btn btn-secondary btn-sm fit" :aria-expanded="allChecks" aria-controls="saglik-tum-denetimler" data-testid="checks-toggle" @click="allChecks = !allChecks">
            {{ allChecks ? "Daha az göster" : `Tüm denetimler (${checks.length})` }}
          </button>
        </template>
        <EmptyState v-else title="Denetim yok" text="Sunucu bir sağlık denetimi bildirmedi." icon="pulse" />
      </template>
      <EmptyState v-else title="Sağlık denetimleri henüz okunamadı" text="Sunucu yanıt verince burada görünür." icon="pulse" />
    </section>

    <section class="card repair" aria-labelledby="onarim-baslik" :aria-busy="running" data-testid="repair">
      <div class="card-head">
        <div class="health-head">
          <h2 id="onarim-baslik" class="card-title">Denetle ve onar</h2>
          <p class="meter-note" data-testid="repair-head">{{ head }}</p>
        </div>
        <div class="card-actions repair-actions">
          <button type="button" class="btn btn-secondary btn-sm" data-testid="repair-log" @click="logSpan = '72s'">
            <Icon name="lines" :size="16" />Onarım kaydı
          </button>
          <button type="button" class="btn btn-secondary btn-sm" :disabled="disabled" :aria-describedby="lock ? 'onarim-kilit' : undefined" data-testid="repair-check" @click="start('denetle')">
            <Icon name="search" :size="16" />{{ starting === "denetle" ? "Başlatılıyor…" : "Denetle" }}
          </button>
          <button type="button" class="btn btn-primary btn-sm" :disabled="disabled" :aria-describedby="lock ? 'onarim-kilit' : undefined" data-testid="repair-fix" @click="askRepair">
            <Icon name="refresh" :size="16" />Onar
          </button>
        </div>
      </div>
      <p v-if="lock" id="onarim-kilit" class="notice" role="note" data-testid="repair-lock">
        <Icon name="lock" class="notice-icon" /><span>{{ lock }}</span>
      </p>
      <p v-if="startError && !askOpen" class="form-error" role="alert" data-testid="repair-error">{{ startError }}</p>
      <p class="sr-only" role="status">{{ note }}</p>
      <p v-if="note" class="meter-note" aria-hidden="true" data-testid="repair-note">{{ note }}</p>

      <template v-if="report">
        <p class="repair-summary" data-testid="repair-summary">
          <StatusPill v-if="reportState" :tone="reportState.tone" :dot="report.durum === 'calisiyor'">{{ reportState.text }}</StatusPill>
          <span class="meter-note" data-testid="repair-line">{{ stepLine }}</span>
        </p>
        <div v-if="allSteps" id="onarim-tum-adimlar" class="health-all" data-testid="repair-all">
          <dl class="facts" data-testid="repair-facts">
            <dt>Tür</dt>
            <dd>{{ report.kip === "denetle" ? "Yalnız denetim" : "Denetim ve onarım" }}</dd>
            <dt>Başlatan</dt>
            <dd>{{ SOURCE[report.kaynak] ?? report.kaynak ?? UNKNOWN }}</dd>
            <dt>Başlangıç</dt>
            <dd>{{ dateTime(report.baslangic) }}</dd>
            <dt>Bitiş</dt>
            <dd>{{ report.bitis ? dateTime(report.bitis) : report.durum === "calisiyor" ? "sürüyor" : UNKNOWN }}</dd>
          </dl>
          <ol v-if="report.adimlar.length" class="health-list" aria-label="Adımlar" data-testid="repair-steps">
            <li v-for="s in report.adimlar" :key="s.id" class="health-item" :data-adim="s.id" :data-durum="s.durum">
              <StatusPill :tone="step(s).tone">{{ step(s).text }}</StatusPill>
              <span class="health-item-text">
                <strong>{{ s.ad }}</strong>
                <span v-if="s.detay" class="cell-note">{{ s.detay }}</span>
              </span>
            </li>
          </ol>
          <p class="meter-note">
            Arka planda sürekli çalışan bir denetim yok: adres denetimi açılışta ve her gece 03–04 arası, onarım bir servis çökünce ve burada
            istenince çalışır; güvenlik duvarı saatte bir ayrıca denetlenir.
          </p>
        </div>
        <ul v-else-if="openSteps.length" class="health-list" aria-label="Dikkat isteyen adımlar" data-testid="repair-problems">
          <li v-for="s in openSteps" :key="s.id" class="health-item" :data-adim="s.id" :data-durum="s.durum">
            <StatusPill :tone="step(s).tone">{{ step(s).text }}</StatusPill>
            <span class="health-item-text">
              <strong>{{ s.ad }}</strong>
              <span v-if="s.detay" class="cell-note">{{ s.detay }}</span>
            </span>
          </li>
        </ul>
        <button v-if="report.adimlar.length" type="button" class="btn btn-secondary btn-sm fit" :aria-expanded="allSteps" aria-controls="onarim-tum-adimlar" data-testid="repair-toggle" @click="allSteps = !allSteps">
          {{ allSteps ? "Daha az göster" : `Tüm adımlar (${report.adimlar.length})` }}
        </button>
      </template>
      <p class="meter-note">Konsol'a ulaşılamazsa SSH ile: <code class="mono">sudo master-onar</code></p>
    </section>

    <Modal :open="askOpen" title="Denetim ve onarım başlasın mı?" @close="askOpen = false">
      <ul class="modal-list">
        <li><Icon name="shield" :size="18" /><span>Güvenlik duvarı, Tailscale ve adresi, servisler, DNS ve Konsol denetlenir.</span></li>
        <li><Icon name="refresh" :size="18" /><span>Bozuk olanlar yeniden başlatılır ya da yeniden kurulur; yapılandırma dosyaları değişmez.</span></li>
        <li><Icon name="info" :size="18" /><span>Caddy ya da Konsol yeniden başlarsa sayfa birkaç saniye yanıt vermeyebilir.</span></li>
      </ul>
      <p v-if="startError" class="form-error" role="alert" data-testid="repair-dialog-error">{{ startError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus @click="askOpen = false">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="starting !== ''" data-testid="repair-go" @click="start('onar')">
          {{ starting === "onar" ? "Başlatılıyor…" : "Onar" }}
        </button>
      </template>
    </Modal>

    <RepairLogSheet :span="logSpan" @span="logSpan = $event" @close="logSpan = ''" />
  </div>
</template>
