<!-- An application's Özet: its state and container facts, how it is reached, and (for a container) its
     resources with their limits. A container's own detail (GET /api/konsol/konteynerler/ayrinti, `box`)
     adds who manages it, its unit and ID, the image with the tag it follows, the update state with its
     channel and check time ("Güncellemeleri denetle" asks the registries again, ?yenile=1), the command,
     the environment (a secret's value never comes to the browser) and how it starts. A stopped definition
     without a live container, a failing health check and an action the server holds back are said first.
     Unknown values are "—". -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import UsageBar from "../../components/ui/UsageBar.vue";
import type { Tone } from "../../components/ui/types";
import { CELL_TEXT, CELL_TONE, KIND_TEXT, appState, hasUpdateState, shortImage, updateText } from "../../apps";
import { RESTART_TEXT, USER_TEXT } from "../uygulama/container";
import { UNKNOWN, bytes, clock, dateTime, percent } from "../../format";
import type { ContainerDetail } from "../../api/podman";
import type { Uygulama, UygulamaAyrinti } from "../../api/sema";

const props = defineProps<{ app: Uygulama; detail: UygulamaAyrinti | null; box: ContainerDetail | null; checking: boolean; checkError: string }>();
const emit = defineEmits<{ access: []; check: [] }>();

const facts = computed(() => props.detail?.konteyner ?? null);
const state = computed(() => appState(props.app));

const HEALTH: Record<string, string> = { healthy: "Sağlıklı", unhealthy: "Sağlıksız", starting: "Başlıyor" };
const health = computed(() => {
  const value = facts.value?.saglik ?? "";
  return value ? (HEALTH[value] ?? value) : "Denetim tanımlı değil";
});

const access = computed(() =>
  (
    [
      ["tailscale", "Tailscale"],
      ["internet", "İnternet"],
    ] as const
  ).map(([scope, label]) => {
    const cell = props.app[scope];
    // The note tells what an open cell does not: only some ports, or why it fails.
    const note = cell.durum === "kismen" || cell.durum === "hata" ? cell.not : "";
    return { scope, label, cell, address: cell.adresler[0] ?? "", note };
  }),
);

const unmeasured = computed(() => props.app.kaynak.cpu === null && props.app.kaynak.bellek === null);

// ---- the container's own detail
const SOURCE: Record<ContainerDetail["source"], { text: string; tone: Tone; note: string }> = {
  appstore: { text: "App Store", tone: "accent", note: "Yaşam döngüsü App Store uygulamasıyla ortak." },
  konsol: { text: "Konsol", tone: "ok", note: "Konsol'da tanımlı; ayarları Ayarlar'da düzenlenir." },
  external: { text: "Dışarıda", tone: "neutral", note: "Konsol dışında oluşturuldu." },
};
const source = computed(() => (props.box ? SOURCE[props.box.source] : null));
const config = computed(() => props.box?.generic ?? null);
const tag = computed(() => {
  const ref = config.value?.image_ref ?? "";
  return ref && ref !== props.box?.image ? ref : "";
});

const UPDATE: Record<string, { text: string; tone: Tone }> = {
  guncel: { text: "Güncel", tone: "ok" },
  var: { text: "Yeni sürüm var", tone: "accent" },
  sabit: { text: "Sabit özet", tone: "neutral" },
  denetlenemedi: { text: "Denetlenemedi", tone: "danger" },
};
const update = computed(() => {
  const u = props.box?.update ?? null;
  if (!u) return { text: props.checking ? "Denetleniyor…" : "Henüz denetlenmedi", tone: "neutral" as Tone, note: "" };
  const known = UPDATE[u.state] ?? { text: u.state, tone: "neutral" as Tone };
  const note =
    u.state === "sabit"
      ? "Bir etiket izlemiyor; imaj yalnız elle değişir."
      : [u.channel ? `kanal: ${u.channel}` : "", u.error, u.checked_at ? `${clock(u.checked_at)}'de denetlendi` : ""].filter(Boolean).join(" · ");
  return { ...known, note };
});
const showUpdate = computed(() => Boolean(props.box && props.box.source !== "external"));

const environment = computed(() => config.value?.environment ?? null);

const autostart = computed(() => {
  const b = props.box;
  if (!b) return null;
  const cfg = config.value;
  const on = b.effective_autostart ?? (cfg ? cfg.autostart !== false && !cfg.manual_stop : null);
  if (b.source === "external") return { text: "Konsol söz veremez", note: "Bu konteyneri başka bir araç yönetir; açılışta ne olacağını o belirler." };
  if (b.source === "appstore") return { text: on ? "Açılışta başlar" : "Kapalı · uygulama durduruldu", note: "App Store uygulamasının durumu izlenir: durdurulursa açılışta da kapalı kalır." };
  if (cfg?.manual_stop) return { text: "Kapalı · siz durdurdunuz", note: "Başlat bu durumu kaldırır; açılış tercihi yeniden geçerli olur." };
  return { text: on ? "Açılışta başlar" : "Açılışta başlamaz", note: cfg?.autostart === false ? "Açılış tercihi kapalı." : "" };
});
</script>

<template>
  <div class="summary-tab">
    <div v-if="box && (box.live === false || box.health === 'unhealthy' || box.restricted_reason)" class="summary-notes">
      <p v-if="box.live === false" class="notice" role="note" data-testid="note-definition">
        <Icon name="info" class="notice-icon" />
        <span>Hizmet durduğu için Podman konteyneri şu an yok. Gösterilenler kayıtlı tanımdır; Başlat aynı tanımla yeniden oluşturur.</span>
      </p>
      <p v-if="box.health === 'unhealthy'" class="notice notice-danger" role="note" data-testid="note-unhealthy">
        <Icon name="alert" class="notice-icon" />
        <span>Sağlık denetimi başarısız; nedeni için <RouterLink :to="{ query: { sekme: 'gunluk' } }">Günlük</RouterLink> bölümüne bakın.</span>
      </p>
      <p v-if="box.restricted_reason" class="notice notice-warning" role="note" data-testid="note-restricted">
        <Icon name="lock" class="notice-icon" /><span>{{ box.restricted_reason }}</span>
      </p>
    </div>
    <div class="tab-grid">
      <Card title="Durum" data-testid="summary-state">
        <dl class="facts">
          <dt>Çalışma</dt>
          <dd><StatusPill :tone="state.tone" :dot="app.durum === 'calisiyor'">{{ state.text }}</StatusPill></dd>
          <dt>Tür</dt>
          <dd>{{ KIND_TEXT[app.tur] }}</dd>
          <template v-if="box && source">
            <dt>Yönetim</dt>
            <dd data-testid="source"><StatusPill :tone="source.tone">{{ source.text }}</StatusPill> <span class="muted">{{ source.note }}</span></dd>
            <dt>Hizmet</dt>
            <dd class="mono wrap" data-testid="unit">{{ box.unit || UNKNOWN }}</dd>
            <dt>Kimlik</dt>
            <dd data-testid="container-id"><span class="mono">{{ box.id || UNKNOWN }}</span><span v-if="box.live === false" class="muted"> · çalışan konteyner yok</span></dd>
          </template>
          <template v-if="facts">
            <dt>Son başlatma</dt>
            <dd data-testid="started">{{ dateTime(facts.baslangic) }}</dd>
            <dt>Sağlık</dt>
            <dd data-testid="app-health">{{ health }}</dd>
            <dt>Yeniden başlama</dt>
            <dd data-testid="restarts">{{ facts.yeniden_baslama }}</dd>
            <dt>Hesap</dt>
            <dd class="mono" data-testid="account">{{ facts.kullanici || "Konteynerin varsayılanı" }}<span v-if="config?.user" class="muted"> · {{ USER_TEXT[config.user] }}</span></dd>
            <dt>İmaj</dt>
            <dd class="mono wrap" :title="facts.imaj || undefined">{{ facts.imaj ? shortImage(facts.imaj) : UNKNOWN }}<span v-if="tag" class="muted" data-testid="image-tag"> · etiket {{ tag }}</span></dd>
            <dt>Ağ</dt>
            <dd class="mono">{{ facts.ag || UNKNOWN }}</dd>
            <template v-if="box?.command">
              <dt>Komut</dt>
              <dd class="mono wrap" data-testid="command">{{ box.command }}</dd>
            </template>
          </template>
          <template v-if="hasUpdateState(app.guncelleme)">
            <dt>Sürüm</dt>
            <dd data-testid="app-version">{{ updateText(app.guncelleme) }}</dd>
          </template>
        </dl>
      </Card>

      <Card title="Erişim" data-testid="summary-access">
        <ul class="cell-list">
          <li v-for="a in access" :key="a.scope" class="cell-line" :data-erisim="a.scope">
            <span class="cell-dot" :class="'dot-' + (a.cell.uyari ? 'warning' : CELL_TONE[a.cell.durum])" aria-hidden="true"></span>
            <span class="cell-name">{{ a.label }}</span>
            <span class="cell-value">
              <span v-if="a.address" class="mono">{{ a.address }}</span>
              <span v-else>{{ CELL_TEXT[a.cell.durum] }}</span>
              <span v-if="a.cell.uyari" class="warn-text"> · {{ a.cell.uyari }}</span>
              <span v-else-if="a.note" class="muted"> · {{ a.note }}</span>
            </span>
          </li>
        </ul>
        <button type="button" class="btn btn-secondary btn-sm fit" @click="emit('access')">Erişim ayrıntısı</button>
      </Card>

      <Card v-if="showUpdate" title="Güncelleme" data-testid="summary-update">
        <dl class="facts">
          <dt>İmaj</dt>
          <dd><StatusPill :tone="update.tone" data-testid="update-state">{{ update.text }}</StatusPill></dd>
          <template v-if="update.note">
            <dt>Ayrıntı</dt>
            <dd class="wrap" data-testid="update-note">{{ update.note }}</dd>
          </template>
        </dl>
        <p class="meter-note">Konsol kendiliğinden güncellemez; yeni sürüm varsa yukarıdaki Güncelle ile siz onaylarsınız.</p>
        <p v-if="checkError" class="form-error" role="alert" data-testid="update-error">{{ checkError }}</p>
        <button type="button" class="btn btn-secondary btn-sm fit" :disabled="checking" data-testid="update-check" @click="emit('check')">
          <Icon name="refresh" :size="16" />{{ checking ? "Denetleniyor…" : "Güncellemeleri denetle" }}
        </button>
      </Card>

      <Card v-if="app.konteyner" title="Kaynak" data-testid="summary-resources">
        <div class="meter-row">
          <div class="meter-line"><span>İşlemci</span><strong data-testid="app-cpu">{{ app.kaynak.cpu === null ? UNKNOWN : percent(app.kaynak.cpu) }}</strong></div>
          <UsageBar :value="app.kaynak.cpu" />
          <span v-if="config?.cpus" class="meter-note" data-testid="cpu-limit">Sınır {{ config.cpus }} çekirdek</span>
        </div>
        <div class="meter-row">
          <div class="meter-line"><span>Bellek</span><strong data-testid="app-memory">{{ bytes(app.kaynak.bellek) }}</strong></div>
          <span v-if="config?.memory" class="meter-note" data-testid="memory-limit">Sınır {{ config.memory }}</span>
        </div>
        <p v-if="unmeasured" class="meter-note">Kaynak kullanımı şu an okunamıyor.</p>
      </Card>

      <Card v-if="box" title="Başlatma ve sınırlar" data-testid="summary-start">
        <dl class="facts">
          <template v-if="autostart">
            <dt>Açılışta</dt>
            <dd data-testid="autostart">{{ autostart.text }}<span v-if="autostart.note" class="cell-note">{{ autostart.note }}</span></dd>
          </template>
          <template v-if="config">
            <dt>Açılış tercihi</dt>
            <dd>{{ config.autostart !== false ? "Açık" : "Kapalı" }}</dd>
            <dt>Yeniden başlatma</dt>
            <dd data-testid="restart-policy">{{ RESTART_TEXT[config.restart] ?? config.restart }}</dd>
            <dt>İşlemci sınırı</dt>
            <dd>{{ config.cpus ? `${config.cpus} çekirdek` : "Yok" }}</dd>
            <dt>Bellek sınırı</dt>
            <dd>{{ config.memory || "Yok" }}</dd>
          </template>
        </dl>
        <p v-if="!config" class="meter-note">{{ box.source === "appstore" ? "Başlatma ve sınırları uygulamanın paketi belirler." : "Bu konteynerin tanımı Konsol'da değil." }}</p>
      </Card>

      <Card v-if="box" title="Ortam" data-testid="summary-env">
        <div v-if="environment && environment.length" class="table-wrap">
          <table class="data-table env-table">
            <thead>
              <tr>
                <th scope="col">Ad</th>
                <th scope="col">Değer</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="e in environment" :key="e.name" :data-ortam="e.name">
                <th scope="row" class="col-main mono">{{ e.name }}</th>
                <td data-label="Değer">
                  <span v-if="e.secret" class="secret-note"><Icon name="lock" :size="14" />gizli · gösterilmez</span>
                  <span v-else class="mono wrap">{{ e.value }}</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p v-else-if="environment" class="meter-note">Ortam değişkeni yok.</p>
        <p v-else class="meter-note">{{ box.source === "appstore" ? "Uygulamanın ortamını paket yönetir; burada gösterilmez." : "Bu konteynerin ortamı Konsol'da tanımlı değil; değerleri gösterilmez." }}</p>
        <p class="meter-note">Gizli değerler sunucudan tarayıcıya hiç gönderilmez.</p>
      </Card>
    </div>
  </div>
</template>
