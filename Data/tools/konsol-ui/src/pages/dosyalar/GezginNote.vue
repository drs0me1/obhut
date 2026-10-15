<!-- Gezgin, the file manager (DD-262): Konsol's Dosyalar stays lean (storage, a rescue view of /srv, the root
     view) and leaves archives, previews and the rest to it. When the package is installed (live.uygulamalar,
     paket:gezgin) "Gezgin'de aç" opens its own address in a new tab (the internet name over HTTPS, else the
     tailnet name), or its page when it has none yet; otherwise a short note leads to the catalogue. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import { live } from "../../live";
import { openTarget } from "../../apps";
import { appRoute } from "../../router";
import { addRoute } from "../../sections";

withDefaults(defineProps<{ compact?: boolean }>(), { compact: false });

const gezgin = computed(() => live.uygulamalar?.items.find((a) => a.id === "paket:gezgin") ?? null);
const target = computed(() => (gezgin.value ? openTarget(gezgin.value) : null));
</script>

<template>
  <p v-if="compact" class="meter-note files-gezgin-line" data-testid="gezgin">
    <template v-if="gezgin && target">
      Arşivler, önizleme ve daha fazlası için
      <a :href="target.href" target="_blank" rel="noopener noreferrer" data-testid="gezgin-open">Gezgin'de açın</a>.
    </template>
    <template v-else-if="gezgin">
      Arşivler, önizleme ve daha fazlası Gezgin'de; <RouterLink :to="appRoute(gezgin.id)">Gezgin'in sayfasından</RouterLink> bir adres verin.
    </template>
    <template v-else>
      Arşivler, önizleme ve daha fazlası için <RouterLink :to="addRoute('katalog', { paket: 'gezgin' })" data-testid="gezgin-install">Gezgin'i kurun</RouterLink>.
    </template>
  </p>
  <section v-else class="card files-gezgin" aria-labelledby="gezgin-baslik" data-testid="gezgin">
    <h2 id="gezgin-baslik" class="card-title">Dosya yöneticisi</h2>
    <template v-if="gezgin">
      <p class="card-text">Arşivler, önizleme, sık kullanılanlar ve daha fazlası Gezgin'de; Konsol burada depolamayı ve temel klasör işlerini gösterir.</p>
      <div class="link-row">
        <a v-if="target" :href="target.href" target="_blank" rel="noopener noreferrer" class="btn btn-primary btn-sm" data-testid="gezgin-open">
          <Icon name="open" :size="16" />Gezgin'de aç
        </a>
        <RouterLink :to="appRoute(gezgin.id)" class="btn btn-secondary btn-sm" data-testid="gezgin-page">Gezgin'in sayfası</RouterLink>
      </div>
      <p v-if="!target" class="meter-note">Gezgin'in henüz bir adresi yok; sayfasından ya da Erişim'den yayınlayın.</p>
    </template>
    <template v-else>
      <p class="card-text">Tam dosya yöneticisi Gezgin'dir: arşivler, önizleme, sık kullanılanlar ve daha fazlası. Uygulamalar → katalogdan kurulur.</p>
      <div class="link-row">
        <RouterLink :to="addRoute('katalog', { paket: 'gezgin' })" class="btn btn-secondary btn-sm" data-testid="gezgin-install"><Icon name="plus" :size="16" />Gezgin'i kur</RouterLink>
      </div>
    </template>
  </section>
</template>
