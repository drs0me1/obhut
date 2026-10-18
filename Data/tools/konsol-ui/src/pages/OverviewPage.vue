<!-- Genel Bakış (rebuild phase 5; DD-286, DD-287): the applications (state, address, "Aç" for one with an address,
     "Ayrıntı"). What needs attention is not here: the top bar's count opens Uyarılar (ProblemsPage), the one list;
     the access counts are Erişim's; the resources and the server's facts are the sidebar's cards (SideNav); each
     application's network is its row in Uygulamalar. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../components/icons";
import AppIcon from "../components/AppIcon.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import { apps } from "../live";
import { appState, warningText } from "../apps";
import { appRoute } from "../router";
import { UNKNOWN } from "../format";

// ---- applications: "Aç" opens the first address of one that runs (a new browser tab)
const ADDRESS_RE = /^https?:\/\/[^/\s]+/;
const cards = computed(() =>
  (apps.value ?? []).map((app) => {
    const fresh = app.guncelleme === "yeni";
    const notes = [app.uyari ? warningText(app.uyari) : "", fresh ? "yeni imaj var" : ""].filter(Boolean);
    const address = typeof app.adres === "string" && ADDRESS_RE.test(app.adres) ? app.adres : "";
    const host = address.replace(/^https?:\/\//, "").replace(/\/.*$/, "");
    return { app, state: appState(app), notes, address, host, open: Boolean(address) && (app.durum === "calisiyor" || app.durum === "kismen") };
  }),
);
</script>

<template>
  <div class="page-body overview">
    <!-- applications -->
    <section class="card overview-apps" aria-labelledby="uyg-baslik" data-testid="overview-apps">
      <div class="card-head">
        <h2 id="uyg-baslik" class="card-title">Uygulamalar</h2>
        <RouterLink to="/uygulamalar" class="section-link" data-testid="all-apps">Tümü ({{ apps ? apps.length : UNKNOWN }})</RouterLink>
      </div>
      <div v-if="cards.length" class="app-grid">
        <article v-for="c in cards" :key="c.app.ad" class="app-card" :data-uygulama="c.app.ad">
          <div class="app-card-head">
            <AppIcon :app="c.app" />
            <div class="app-card-name">
              <RouterLink :to="appRoute(c.app.ad)" class="app-name">{{ c.app.ad }}</RouterLink>
              <StatusPill :tone="c.state.tone" :dot="c.app.durum === 'calisiyor'">{{ c.state.text }}</StatusPill>
            </div>
          </div>
          <p class="app-line">
            <span v-if="c.host" class="mono" data-testid="app-address">{{ c.host }}</span><span v-else class="muted">Dışarıya açık adresi yok</span><template
              v-for="n in c.notes" :key="n"> · <span :class="n === 'yeni imaj var' ? 'fresh' : 'warn-text'">{{ n }}</span></template>
          </p>
          <div class="app-card-actions">
            <a v-if="c.open" :href="c.address" class="btn btn-primary btn-sm" target="_blank" rel="noopener noreferrer" :aria-label="`${c.app.ad} uygulamasını aç`"
              data-eylem="ac">Aç<Icon name="open" :size="14" /></a>
            <RouterLink :to="appRoute(c.app.ad)" class="btn btn-secondary btn-sm" :aria-label="`${c.app.ad} ayrıntıları`">Ayrıntı</RouterLink>
          </div>
        </article>
      </div>
      <EmptyState
        v-else
        :title="apps ? 'Henüz uygulama yok.' : 'Uygulamalar henüz okunamadı'"
        :text="apps ? 'Uygulamalar bölümünden bir Compose ya da Kubernetes dosyasıyla eklenir.' : ''"
        icon="apps"
      />
    </section>
  </div>
</template>
