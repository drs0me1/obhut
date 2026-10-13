<!-- Uygulamalar (DD-258, phase 2): App Store packages, Konsol's containers and the built-ins in one list
     (GET /api/konsol/uygulamalar, DD-261). The filter (?suzgec=) and the search (?ara=) are in the address.
     A table on wide screens, cards on narrow ones (a container query, so the sidebar's width counts). Adding
     an application still happens in the current interface (App Store, Podman). -->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../components/icons";
import AppIcon from "../components/AppIcon.vue";
import AccessChips from "../components/AccessChips.vue";
import Card from "../components/ui/Card.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import { apps, live, refreshApps } from "../live";
import { KIND_TEXT, appState, hasUpdateState, needsAttention, openTarget, resourceText, updateText } from "../apps";
import { appRoute } from "../router";
import { usePageHead } from "../page";
import { useQueryParam } from "../query";
import { UNKNOWN, fold } from "../format";
import type { Uygulama } from "../api/sema";

type Filter = "tumu" | "calisan" | "durmus" | "dikkat";
const FILTERS: readonly { id: Filter; label: string; empty: string }[] = [
  { id: "tumu", label: "Tümü", empty: "Uygulama yok." },
  { id: "calisan", label: "Çalışan", empty: "Çalışan uygulama yok." },
  { id: "durmus", label: "Durdurulmuş", empty: "Durdurulmuş uygulama yok." },
  { id: "dikkat", label: "Dikkat", empty: "Dikkat isteyen uygulama yok." },
];
const TESTS: Record<Filter, (a: Uygulama) => boolean> = {
  tumu: () => true,
  calisan: (a) => a.durum === "calisiyor",
  durmus: (a) => a.durum === "durduruldu",
  dikkat: needsAttention,
};

const filter = useQueryParam<Filter>("suzgec", FILTERS.map((f) => f.id), "tumu");
const searchParam = useQueryParam<string>("ara", null, "");
// The field keeps exactly what was typed; the address follows it, and Back/Forward set it again.
const search = ref(searchParam.value);
watch(searchParam, (value) => {
  if (value !== search.value) search.value = value;
});
watch(search, (value) => (searchParam.value = value));

const list = computed(() => apps.value ?? []);
const counts = computed(() => Object.fromEntries(FILTERS.map((f) => [f.id, list.value.filter(TESTS[f.id]).length])) as Record<Filter, number>);

const description = (a: Uygulama) => {
  const text = a.aciklama.replace(/\.\s*$/, "");
  return a.tur === "paket" ? [text, KIND_TEXT.paket].filter(Boolean).join(" · ") : text || KIND_TEXT[a.tur];
};

const rows = computed(() => {
  const tokens = fold(search.value).split(/\s+/).filter(Boolean);
  return list.value
    .filter(TESTS[filter.value])
    .filter((a) => {
      if (!tokens.length) return true;
      const hay = fold(`${a.ad} ${a.aciklama} ${a.id}`);
      return tokens.every((t) => hay.includes(t));
    })
    .map((app) => {
      const open = openTarget(app);
      return {
        app,
        description: description(app),
        state: appState(app),
        resources: resourceText(app),
        open: open && { ...open, label: open.external ? `${app.ad} uygulamasını yeni sekmede aç` : `${app.ad} sayfasını aç` },
      };
    });
});

const emptyText = computed(() => {
  if (search.value.trim()) return "Aramayla eşleşen uygulama yok.";
  return FILTERS.find((f) => f.id === filter.value)?.empty ?? "";
});

const summary = computed(() => {
  const l = apps.value;
  if (!l) return null;
  const n = l.length;
  if (!n) return "Henüz uygulama yok";
  const running = counts.value.calisan;
  const parts = [`${n} uygulama`, running === n ? "hepsi çalışıyor" : running === 0 ? "hiçbiri çalışmıyor" : `${running} çalışıyor`];
  if (counts.value.durmus && running !== 0) parts.push(`${counts.value.durmus} durdurulmuş`);
  if (counts.value.dikkat) parts.push(`${counts.value.dikkat} dikkat`);
  return parts.join(" · ");
});
usePageHead(() => ({ description: summary.value }));

const catalogue = computed(() => live.uygulamalar?.katalog ?? []);
const infra = computed(() => {
  const a = live.uygulamalar?.altyapi;
  if (!a) return null;
  if (!a.calisiyor) return a.podman ? `Podman ${a.podman} · çalışmıyor` : "Podman çalışmıyor";
  return [
    a.podman ? `Podman ${a.podman}` : "Podman",
    `${a.imaj} imaj`,
    `${a.birim} birim`,
    `${a.ag} ağ`,
    a.kullanilmayan_imaj ? `${a.kullanilmayan_imaj} kullanılmayan imaj` : "kullanılmayan imaj yok",
  ].join(" · ");
});
const errors = computed(() => live.uygulamalar?.hatalar ?? []);

const addPanel = ref<InstanceType<typeof Card> | null>(null);
function showAdd(): void {
  const el = (addPanel.value?.$el as HTMLElement | undefined)?.querySelector<HTMLElement>("h2");
  if (!el) return;
  el.tabIndex = -1;
  el.focus({ preventScroll: true });
  el.scrollIntoView({ block: "start", behavior: "smooth" });
}

onMounted(() => void refreshApps());
</script>

<template>
  <div class="page-body apps-page">
    <section v-if="errors.length" class="notice notice-warning" aria-labelledby="uyg-hata-baslik" data-testid="app-errors">
      <Icon name="alert" class="notice-icon" />
      <div>
        <h2 id="uyg-hata-baslik" class="notice-title">Bazı bilgiler okunamadı</h2>
        <ul class="notice-list">
          <li v-for="(e, i) in errors" :key="i">{{ e }}</li>
        </ul>
      </div>
    </section>

    <div class="toolbar">
      <div class="filters" role="group" aria-label="Süzgeç">
        <button
          v-for="f in FILTERS"
          :key="f.id"
          type="button"
          class="filter-chip"
          :data-suzgec="f.id"
          :aria-pressed="filter === f.id"
          @click="filter = f.id"
        >
          {{ f.label }} <span class="filter-count">{{ apps ? counts[f.id] : UNKNOWN }}</span>
        </button>
      </div>
      <div class="search-box">
        <label for="uyg-ara" class="sr-only">Uygulama ara</label>
        <Icon name="search" :size="18" class="search-icon" />
        <input id="uyg-ara" v-model="search" class="input" type="search" placeholder="Uygulama ara" autocomplete="off" spellcheck="false" />
      </div>
      <button type="button" class="btn btn-primary toolbar-add" @click="showAdd"><Icon name="plus" :size="18" />Uygulama ekle</button>
    </div>
    <p class="sr-only" role="status">{{ apps ? `${rows.length} uygulama gösteriliyor` : "" }}</p>

    <section class="card app-list" aria-label="Uygulama listesi" data-testid="app-list">
      <table v-if="rows.length" class="app-table">
        <thead>
          <tr>
            <th scope="col">Uygulama</th>
            <th scope="col">Durum</th>
            <th scope="col">Erişim</th>
            <th scope="col">Kaynak</th>
            <th scope="col">Sürüm</th>
            <th scope="col"><span class="sr-only">Eylemler</span></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.app.id" :data-uygulama="r.app.id">
            <th scope="row" class="col-app">
              <AppIcon :app="r.app" size="sm" />
              <span class="app-cell">
                <RouterLink :to="appRoute(r.app.id)" class="app-name">{{ r.app.ad }}</RouterLink>
                <span class="app-desc">{{ r.description }}</span>
              </span>
            </th>
            <td class="col-state" data-label="Durum">
              <StatusPill :tone="r.state.tone" :dot="r.app.durum === 'calisiyor'">{{ r.state.text }}</StatusPill>
            </td>
            <td class="col-access" data-label="Erişim"><AccessChips :app="r.app" /></td>
            <td class="col-res" :class="{ 'cell-empty': r.resources === UNKNOWN }" data-label="Kaynak">{{ r.resources }}</td>
            <td class="col-ver" :class="{ 'cell-empty': !hasUpdateState(r.app.guncelleme) }" data-label="Sürüm">
              <StatusPill v-if="r.app.guncelleme === 'yeni'" tone="accent">{{ updateText("yeni") }}</StatusPill>
              <span v-else :class="{ muted: r.app.guncelleme !== 'guncel' }" :data-surum="r.app.guncelleme">{{ updateText(r.app.guncelleme) }}</span>
            </td>
            <td class="col-act">
              <span class="row-actions">
                <a
                  v-if="r.open"
                  class="btn btn-secondary btn-sm"
                  :href="r.open.href"
                  :target="r.open.external ? '_blank' : undefined"
                  :rel="r.open.external ? 'noopener noreferrer' : undefined"
                  :aria-label="r.open.label"
                  data-eylem="ac"
                >
                  Aç<Icon v-if="r.open.external" name="open" :size="15" />
                </a>
                <RouterLink :to="appRoute(r.app.id)" class="icon-btn" :aria-label="`${r.app.ad} ayrıntıları`"><Icon name="chevron" :size="18" /></RouterLink>
              </span>
            </td>
          </tr>
        </tbody>
      </table>
      <EmptyState v-else-if="apps" :title="emptyText" :icon="search.trim() ? 'search' : 'apps'">
        <button v-if="search.trim() || filter !== 'tumu'" type="button" class="btn btn-secondary" @click="(search = ''), (filter = 'tumu')">
          Tüm uygulamaları göster
        </button>
      </EmptyState>
      <EmptyState v-else title="Uygulamalar henüz okunamadı" text="Sunucu yanıt verince liste burada görünür." icon="unknown" />
    </section>

    <div class="apps-more">
      <Card ref="addPanel" title="Uygulama ekle" data-testid="add-app">
        <div class="add-option" data-secenek="katalog">
          <strong>Katalogdan</strong>
          <span v-if="catalogue.length">{{ catalogue.length }} uygulama kurulabilir; kurulum App Store'da.</span>
          <span v-else>Katalogdaki uygulamaların hepsi kurulu.</span>
          <ul v-if="catalogue.length" class="catalog">
            <li v-for="k in catalogue" :key="k.id">
              <a href="/#/moduller">{{ k.ad }}</a><span v-if="k.aciklama"> · {{ k.aciklama }}</span>
            </li>
          </ul>
          <a class="btn btn-secondary btn-sm" href="/#/moduller">App Store'u aç</a>
        </div>
        <a class="add-option add-link" href="/#/konteynerler" data-secenek="imaj">
          <strong>Bir imajdan</strong>
          <span>Konteyneri Dosyalar hesabıyla, sabitlenmiş imajla çalıştırır</span>
        </a>
        <a class="add-option add-link" href="/#/konteynerler" data-secenek="benimse">
          <strong>Var olanı benimse</strong>
          <span>Podman'da Konsol dışında kurulmuş bir konteyneri yönetime alır</span>
        </a>
      </Card>
      <Card title="Altyapı" data-testid="infra">
        <p class="card-text" data-testid="infra-line">{{ infra ?? UNKNOWN }}</p>
        <p class="meter-note">İmajlar, birimler ve ağlar günlük kullanımda gerekmez; şimdilik Podman sayfasında durur.</p>
        <a class="btn btn-secondary btn-sm fit" href="/#/konteynerler">Podman'ı aç</a>
      </Card>
    </div>
  </div>
</template>
