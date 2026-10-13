<!-- An application's Özet: its state and container facts, how it is reached, and (for a container) its
     resources. Unknown values are "—". -->
<script setup lang="ts">
import { computed } from "vue";
import Card from "../../components/ui/Card.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import UsageBar from "../../components/ui/UsageBar.vue";
import { CELL_TEXT, CELL_TONE, KIND_TEXT, appState, hasUpdateState, shortImage, updateText } from "../../apps";
import { UNKNOWN, bytes, dateTime, percent } from "../../format";
import type { Uygulama, UygulamaAyrinti } from "../../api/sema";

const props = defineProps<{ app: Uygulama; detail: UygulamaAyrinti | null }>();
const emit = defineEmits<{ access: [] }>();

const box = computed(() => props.detail?.konteyner ?? null);
const state = computed(() => appState(props.app));

const HEALTH: Record<string, string> = { healthy: "Sağlıklı", unhealthy: "Sağlıksız", starting: "Başlıyor" };
const health = computed(() => {
  const value = box.value?.saglik ?? "";
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
</script>

<template>
  <div class="tab-grid">
    <Card title="Durum" data-testid="summary-state">
      <dl class="facts">
        <dt>Çalışma</dt>
        <dd><StatusPill :tone="state.tone" :dot="app.durum === 'calisiyor'">{{ state.text }}</StatusPill></dd>
        <dt>Tür</dt>
        <dd>{{ KIND_TEXT[app.tur] }}</dd>
        <template v-if="box">
          <dt>Son başlatma</dt>
          <dd data-testid="started">{{ dateTime(box.baslangic) }}</dd>
          <dt>Sağlık</dt>
          <dd data-testid="app-health">{{ health }}</dd>
          <dt>Yeniden başlama</dt>
          <dd data-testid="restarts">{{ box.yeniden_baslama }}</dd>
          <dt>Hesap</dt>
          <dd class="mono" data-testid="account">{{ box.kullanici || "Konteynerin varsayılanı" }}</dd>
          <dt>İmaj</dt>
          <dd class="mono wrap" :title="box.imaj || undefined">{{ box.imaj ? shortImage(box.imaj) : UNKNOWN }}</dd>
          <dt>Ağ</dt>
          <dd class="mono">{{ box.ag || UNKNOWN }}</dd>
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

    <Card v-if="app.konteyner" title="Kaynak" data-testid="summary-resources">
      <div class="meter-row">
        <div class="meter-line"><span>İşlemci</span><strong data-testid="app-cpu">{{ app.kaynak.cpu === null ? UNKNOWN : percent(app.kaynak.cpu) }}</strong></div>
        <UsageBar :value="app.kaynak.cpu" />
      </div>
      <div class="meter-row">
        <div class="meter-line"><span>Bellek</span><strong data-testid="app-memory">{{ bytes(app.kaynak.bellek) }}</strong></div>
      </div>
      <p v-if="unmeasured" class="meter-note">Kaynak kullanımı şu an okunamıyor.</p>
    </Card>
  </div>
</template>
