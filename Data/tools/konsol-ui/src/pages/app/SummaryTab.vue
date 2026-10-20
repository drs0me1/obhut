<!-- An application's Özet (rebuild phase 5, the prototype): the application as a whole (its state, where its file
     came from, its network, pod and data folder), its resources with the live rate of its own bridge, its image
     update state (each service's pinned digest, when the registries were last asked, "Güncelle" when the backend
     offers it) and every service with its
     state, how it starts (A4) and as whom, its image and digest, health, restarts, last start, container and
     unit. A failing health check is said first, with the way to the service's log. Unknown values are "—". -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import UsageBar from "../../components/ui/UsageBar.vue";
import { FORMAT_TEXT, SOURCE_TEXT, appState, runState, servicesText, shortImage, updateText, userText } from "../../apps";
import { UNKNOWN, bytes, dateTime, percent, rate as rateOf, since } from "../../format";
import { serverNow } from "../../live";
import type { Uygulama, UygulamaAyrinti, UygulamaServisAyrintisi } from "../../api/sema";

const props = defineProps<{ app: Uygulama; detail: UygulamaAyrinti; rate: Uygulama["ag"]; canUpdate: boolean }>();
const emit = defineEmits<{ update: [] }>();

const state = computed(() => appState(props.app));
const unmeasured = computed(() => props.app.kaynak.cpu === null && props.app.kaynak.bellek === null);
const source = computed(() => {
  const k = props.detail.koken;
  return k.adres ?? k.imaj ?? "";
});

const HEALTH: Record<string, string> = { healthy: "Sağlıklı", unhealthy: "Sağlıksız", starting: "Başlıyor" };
/** A running service's health check; a stopped one has none to show. */
const health = (s: UygulamaServisAyrintisi) => (s.durum !== "calisiyor" ? UNKNOWN : s.saglik ? (HEALTH[s.saglik] ?? s.saglik) : "Denetim tanımlı değil");
const unhealthy = computed(() => props.detail.servisler.filter((s) => s.saglik === "unhealthy").map((s) => s.ad));
const services = computed(() => props.detail.servisler.map((s) => ({ s, state: appState(s) })));
const updateTone = computed(() => (props.app.guncelleme === "yeni" ? "accent" : props.app.guncelleme === "guncel" ? "ok" : props.app.guncelleme === "denetlenemedi" ? "warning" : "neutral"));
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
      <Card title="Durum" data-testid="summary-state">
        <dl class="facts">
          <dt>Çalışma</dt>
          <dd><StatusPill :tone="state.tone" :dot="app.durum === 'calisiyor'">{{ state.text }}</StatusPill></dd>
          <dt>Kaynak</dt>
          <dd data-testid="app-source">{{ FORMAT_TEXT[app.bicim] ?? app.bicim }} · {{ SOURCE_TEXT[detail.koken.tur] ?? detail.koken.tur }}<template v-if="source"> · <span class="mono wrap">{{ source }}</span></template></dd>
          <dt>Servis</dt>
          <dd data-testid="app-format">{{ servicesText(detail.servisler.length) }}</dd>
          <dt>Ağ</dt>
          <dd class="mono" data-testid="app-network">{{ detail.ag || UNKNOWN }}</dd>
          <template v-if="detail.pod">
            <dt>Pod</dt>
            <dd class="mono" data-testid="app-pod">{{ detail.pod }}</dd>
          </template>
          <dt>Veri</dt>
          <dd class="mono wrap" data-testid="app-data">{{ detail.veri }}</dd>
        </dl>
      </Card>

      <Card title="Kaynak kullanımı" data-testid="summary-resources">
        <div class="meter-row">
          <div class="meter-line"><span>İşlemci</span><strong data-testid="app-cpu">{{ app.kaynak.cpu === null ? UNKNOWN : percent(app.kaynak.cpu) }}</strong></div>
          <UsageBar :value="app.kaynak.cpu" />
        </div>
        <div class="meter-row">
          <div class="meter-line"><span>Bellek</span><strong data-testid="app-memory">{{ bytes(app.kaynak.bellek) }}</strong></div>
        </div>
        <div class="meter-row">
          <div class="meter-line"><span>Ağ</span><strong data-testid="app-rate">{{ rate ? `↓ ${rateOf(rate.indirme)} · ↑ ${rateOf(rate.yukleme)}` : UNKNOWN }}</strong></div>
        </div>
        <p class="meter-note">{{ unmeasured ? "Kaynak kullanımı şu an okunamıyor." : "Çalışan servislerin toplamı; ağ, uygulamanın kendi köprüsünün canlı hızı." }}</p>
      </Card>

      <Card title="Güncelleme" data-testid="summary-update">
        <template #actions>
          <StatusPill :tone="updateTone" :dot="app.guncelleme === 'yeni' || app.guncelleme === 'guncel'" data-testid="app-version">
            {{ updateText(app.guncelleme) === UNKNOWN ? "Denetlenmedi" : updateText(app.guncelleme) }}
          </StatusPill>
        </template>
        <dl class="facts">
          <template v-for="x in services" :key="x.s.ad">
            <dt>{{ x.s.ad }}</dt>
            <dd class="mono wrap" :title="x.s.ozet || undefined" data-testid="update-digest">{{ x.s.ozet ? shortImage(x.s.ozet) : UNKNOWN }}</dd>
          </template>
          <dt>Son denetim</dt>
          <dd data-testid="update-checked">{{ detail.guncelleme_denetlendi ? `${dateTime(detail.guncelleme_denetlendi)} (${since(detail.guncelleme_denetlendi, serverNow())})` : "Henüz denetlenmedi" }}</dd>
        </dl>
        <p v-if="app.guncelleme === 'yeni'" class="meter-note">Etiketin yeni yapısı yayımlandı; yalnız siz onaylarsanız uygulanır.</p>
        <p v-else-if="app.guncelleme === 'sabit'" class="meter-note">İmajlar özetle sabitlenmiş; denetlenecek etiket yok.</p>
        <div v-if="canUpdate">
          <button type="button" class="btn btn-secondary btn-sm" data-eylem="guncelle-ozet" @click="emit('update')"><Icon name="update" :size="16" />Güncelle</button>
        </div>
      </Card>
    </div>

    <section class="card" aria-labelledby="servis-baslik" data-testid="services">
      <h2 id="servis-baslik" class="card-title">Servisler</h2>
      <ul class="service-list">
        <li v-for="x in services" :key="x.s.ad" class="service-item" :data-servis="x.s.ad" data-testid="service">
          <div class="service-head">
            <span class="sev sev-accent" aria-hidden="true"><Icon name="box" :size="16" /></span>
            <strong class="service-name">{{ x.s.ad }}</strong>
            <StatusPill :tone="x.state.tone" :dot="x.s.durum === 'calisiyor'" data-testid="service-state">{{ x.state.text }}</StatusPill>
            <StatusPill :tone="runState(x.s).tone" data-testid="service-start">{{ runState(x.s).text }}</StatusPill>
          </div>
          <dl class="facts service-facts">
            <dt>Kullanıcı</dt>
            <dd :class="{ mono: x.s.kullanici }" data-testid="service-user">{{ x.s.kullanici || "İmajın varsayılanı" }}</dd>
            <dt>Süreçler</dt>
            <dd data-testid="service-processes">
              <template v-if="x.s.surecler">
                <span v-for="u in x.s.surecler" :key="u.uid" class="process-line" :data-uid="u.uid">
                  <span>{{ userText(u) }} · {{ u.surec }} süreç</span>
                  <span v-if="u.komutlar.length" class="mono process-commands">{{ u.komutlar.join(", ") }}</span>
                </span>
              </template>
              <span v-else class="muted">{{ x.s.durum === "calisiyor" ? "Okunamadı" : "Çalışmıyor" }}</span>
            </dd>
            <dt>İmaj</dt>
            <dd class="mono wrap" data-testid="service-image">{{ x.s.imaj || UNKNOWN }}</dd>
            <dt>Özet</dt>
            <dd class="mono wrap" :title="x.s.ozet || undefined" data-testid="service-digest">{{ x.s.ozet ? shortImage(x.s.ozet) : UNKNOWN }}</dd>
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
        </li>
      </ul>
    </section>
  </div>
</template>
