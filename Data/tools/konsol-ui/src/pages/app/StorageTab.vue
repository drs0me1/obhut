<!-- An application's Depolama: the folders bound into its container and its volumes, each read-only or
     read-write (podman inspect, through GET /api/konsol/uygulamalar/ayrinti). -->
<script setup lang="ts">
import { computed } from "vue";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import type { UygulamaAyrinti } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti | null }>();

type Mount = NonNullable<UygulamaAyrinti["konteyner"]>["baglamalar"][number];
const mounts = computed<Mount[]>(() => props.detail?.konteyner?.baglamalar ?? []);
const folders = computed(() => mounts.value.filter((m) => m.tur === "bind"));
const volumes = computed(() => mounts.value.filter((m) => m.tur !== "bind"));
const access = (m: Mount) => (m.yazilabilir ? "Okuma-yazma" : "Salt okunur");
</script>

<template>
  <div v-if="detail?.konteyner" class="tab-grid tab-grid-wide">
    <Card title="Bağlı klasörler" data-testid="folders">
      <ul v-if="folders.length" class="mount-list">
        <li v-for="m in folders" :key="m.kaynak + '→' + m.hedef" class="mount">
          <span class="mono">{{ m.kaynak }}</span>
          <span class="mount-meta">{{ access(m) }} · konteynerde <span class="mono">{{ m.hedef }}</span></span>
        </li>
      </ul>
      <p v-else class="meter-note">Bu konteynere bağlı sunucu klasörü yok.</p>
    </Card>
    <Card title="Birimler" data-testid="volumes">
      <ul v-if="volumes.length" class="mount-list">
        <li v-for="m in volumes" :key="(m.ad || m.kaynak) + '→' + m.hedef" class="mount">
          <span class="mono">{{ m.ad || m.kaynak }}</span>
          <span class="mount-meta">{{ access(m) }} · konteynerde <span class="mono">{{ m.hedef }}</span><template v-if="m.tur !== 'volume'"> · {{ m.tur }}</template></span>
        </li>
      </ul>
      <p v-else class="meter-note">Bu konteynerin adlı birimi yok.</p>
      <p class="meter-note">Birimler konteyner kaldırılınca kalır; Podman sayfasından silinir.</p>
    </Card>
  </div>
  <section v-else class="card" aria-label="Depolama" data-testid="storage-empty">
    <EmptyState
      title="Bu uygulama bir konteynerde çalışmıyor"
      text="Konteynere bağlanan bir klasörü ya da birimi yok."
      icon="folder"
    />
  </section>
</template>
