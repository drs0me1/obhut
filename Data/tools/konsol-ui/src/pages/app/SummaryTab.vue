<!-- An application's Özet (DD-271, phase 3): the application as a whole (state, format, resources, version,
     network, pod) and each service with its state, how it starts and as whom, its image and digest, the update
     state of its tag, health, restarts, last start, container and unit. A failing health check is said
     first, with the way to the service's log. Unknown values are "—". -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import UsageBar from "../../components/ui/UsageBar.vue";
import { FORMAT_TEXT, START_TEXT, appState, hasUpdateState, servicesText, shortImage, updateText } from "../../apps";
import { UNKNOWN, bytes, dateTime, percent } from "../../format";
import type { Uygulama, UygulamaAyrinti, UygulamaServisAyrintisi } from "../../api/sema";

const props = defineProps<{ app: Uygulama; detail: UygulamaAyrinti }>();

const state = computed(() => appState(props.app));
const unmeasured = computed(() => props.app.kaynak.cpu === null && props.app.kaynak.bellek === null);

const HEALTH: Record<string, string> = { healthy: "Sağlıklı", unhealthy: "Sağlıksız", starting: "Başlıyor" };
/** A running service's health check; a stopped one has none to show. */
const health = (s: UygulamaServisAyrintisi) => (s.durum !== "calisiyor" ? UNKNOWN : s.saglik ? (HEALTH[s.saglik] ?? s.saglik) : "Denetim tanımlı değil");
const unhealthy = computed(() => props.detail.servisler.filter((s) => s.saglik === "unhealthy").map((s) => s.ad));
const services = computed(() => props.detail.servisler.map((s) => ({ s, state: appState(s) })));
</script>

<template>
  <div class="summary-tab">
    <p v-if="unhealthy.length" class="notice notice-danger" role="note" data-testid="note-unhealthy">
      <Icon name="alert" class="notice-icon" />
      <span>
        Sağlık denetimi başarısız: {{ unhealthy.join(", ") }}. Nedeni için
        <RouterLink :to="{ query: { sekme: 'gunluk', servis: unhealthy[0] } }">Günlük</RouterLink> bölümüne bakın.
      </span>
    </p>
    <div class="tab-grid">
      <Card title="Uygulama" data-testid="summary-state">
        <dl class="facts">
          <dt>Çalışma</dt>
          <dd><StatusPill :tone="state.tone" :dot="app.durum === 'calisiyor'">{{ state.text }}</StatusPill></dd>
          <dt>Biçim</dt>
          <dd data-testid="app-format">{{ FORMAT_TEXT[app.bicim] ?? app.bicim }} · {{ servicesText(detail.servisler.length) }}</dd>
          <template v-if="hasUpdateState(app.guncelleme)">
            <dt>Sürüm</dt>
            <dd data-testid="app-version">{{ updateText(app.guncelleme) }}</dd>
          </template>
          <dt>Ağ</dt>
          <dd class="mono" data-testid="app-network">{{ detail.ag || UNKNOWN }}</dd>
          <template v-if="detail.pod">
            <dt>Pod</dt>
            <dd class="mono" data-testid="app-pod">{{ detail.pod }}</dd>
          </template>
        </dl>
      </Card>

      <Card title="Kaynak" data-testid="summary-resources">
        <div class="meter-row">
          <div class="meter-line"><span>İşlemci</span><strong data-testid="app-cpu">{{ app.kaynak.cpu === null ? UNKNOWN : percent(app.kaynak.cpu) }}</strong></div>
          <UsageBar :value="app.kaynak.cpu" />
        </div>
        <div class="meter-row">
          <div class="meter-line"><span>Bellek</span><strong data-testid="app-memory">{{ bytes(app.kaynak.bellek) }}</strong></div>
        </div>
        <p class="meter-note">{{ unmeasured ? "Kaynak kullanımı şu an okunamıyor." : "Çalışan servislerin toplamı." }}</p>
      </Card>

      <Card v-for="x in services" :key="x.s.ad" :title="x.s.ad" :data-servis="x.s.ad" data-testid="service">
        <dl class="facts">
          <dt>Çalışma</dt>
          <dd><StatusPill :tone="x.state.tone" :dot="x.s.durum === 'calisiyor'" data-testid="service-state">{{ x.state.text }}</StatusPill></dd>
          <dt>Başlatma</dt>
          <dd data-testid="service-start">{{ START_TEXT[x.s.baslangic] ?? x.s.baslangic }}</dd>
          <dt>Kullanıcı</dt>
          <dd :class="{ mono: x.s.kullanici }" data-testid="service-user">{{ x.s.kullanici || "İmajın varsayılanı" }}</dd>
          <dt>İmaj</dt>
          <dd class="mono wrap" data-testid="service-image">{{ x.s.imaj || UNKNOWN }}</dd>
          <dt>Özet</dt>
          <dd class="mono wrap" :title="x.s.ozet || undefined" data-testid="service-digest">{{ x.s.ozet ? shortImage(x.s.ozet) : UNKNOWN }}</dd>
          <template v-if="hasUpdateState(x.s.guncelleme)">
            <dt>Sürüm</dt>
            <dd data-testid="service-version">{{ updateText(x.s.guncelleme) }}<span v-if="x.s.kanal" class="muted"> · {{ x.s.kanal }}</span></dd>
          </template>
          <dt>Sağlık</dt>
          <dd data-testid="service-health">{{ health(x.s) }}</dd>
          <dt>Yeniden başlama</dt>
          <dd data-testid="service-restarts">{{ x.s.yeniden_baslama }}</dd>
          <dt>Son başlatma</dt>
          <dd data-testid="service-started">{{ dateTime(x.s.calisma) }}</dd>
          <dt>Konteyner</dt>
          <dd class="mono wrap">{{ x.s.konteyner }}</dd>
          <dt>Birim</dt>
          <dd class="mono wrap">{{ x.s.birim }}</dd>
        </dl>
      </Card>
    </div>
  </div>
</template>
