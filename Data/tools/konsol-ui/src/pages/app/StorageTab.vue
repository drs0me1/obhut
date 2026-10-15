<!-- An application's Depolama: the folders bound into its container and its volumes, each read-only or
     read-write (podman inspect, through GET /api/konsol/uygulamalar/ayrinti). The container's detail marks
     what the editor never changes (`protected_mounts`: an App Store package's data, with its reason) and an
     App Store package's save folder, which is its own setting (Ayarlar). -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import { podmanRoute } from "../../apps";
import type { ContainerDetail } from "../../api/podman";
import type { UygulamaAyrinti } from "../../api/sema";

const props = withDefaults(defineProps<{ detail: UygulamaAyrinti | null; box?: ContainerDetail | null }>(), { box: null });

type Mount = NonNullable<UygulamaAyrinti["konteyner"]>["baglamalar"][number];
const mounts = computed<Mount[]>(() => props.detail?.konteyner?.baglamalar ?? []);
const folders = computed(() => mounts.value.filter((m) => m.tur === "bind"));
const volumes = computed(() => mounts.value.filter((m) => m.tur !== "bind"));
const access = (m: Mount) => (m.yazilabilir ? "Okuma-yazma" : "Salt okunur");
const guarded = computed(() => new Map((props.box?.protected ?? []).map((p) => [p.destination, p.reason])));
const save = computed(() => props.box?.adapter?.save ?? "");
const flag = (m: Mount) => {
  const reason = guarded.value.get(m.hedef);
  if (reason !== undefined) return { kind: "korunur", text: reason ? `korunur · ${reason.replace(/\.$/, "")}` : "uygulama verisi · korunur" };
  if (save.value && (m.hedef === save.value || m.kaynak === save.value)) return { kind: "kayit", text: "kayıt klasörü · uygulama ayarı" };
  return null;
};
</script>

<template>
  <div v-if="detail?.konteyner" class="tab-grid tab-grid-wide">
    <Card title="Bağlı klasörler" data-testid="folders">
      <ul v-if="folders.length" class="mount-list">
        <li v-for="m in folders" :key="m.kaynak + '→' + m.hedef" class="mount" :data-hedef="m.hedef">
          <span class="mono">{{ m.kaynak }}</span>
          <span class="mount-meta">{{ access(m) }} · konteynerde <span class="mono">{{ m.hedef }}</span></span>
          <span v-if="flag(m)" class="mount-flag" :data-isaret="flag(m)?.kind"><Icon name="lock" :size="14" />{{ flag(m)?.text }}</span>
        </li>
      </ul>
      <p v-else class="meter-note">Bu konteynere bağlı sunucu klasörü yok.</p>
      <p v-if="save" class="meter-note" data-testid="save-folder">
        Kayıt klasörü <span class="mono">{{ save }}</span>; uygulamanın ayarıdır, <RouterLink :to="{ query: { sekme: 'ayarlar' } }">Ayarlar</RouterLink>'dan değişir.
      </p>
    </Card>
    <Card title="Birimler" data-testid="volumes">
      <ul v-if="volumes.length" class="mount-list">
        <li v-for="m in volumes" :key="(m.ad || m.kaynak) + '→' + m.hedef" class="mount" :data-hedef="m.hedef">
          <span class="mono">{{ m.ad || m.kaynak }}</span>
          <span class="mount-meta">{{ access(m) }} · konteynerde <span class="mono">{{ m.hedef }}</span><template v-if="m.tur !== 'volume'"> · {{ m.tur }}</template></span>
          <span v-if="flag(m)" class="mount-flag" :data-isaret="flag(m)?.kind"><Icon name="lock" :size="14" />{{ flag(m)?.text }}</span>
        </li>
      </ul>
      <p v-else class="meter-note">Bu konteynerin adlı birimi yok.</p>
      <p class="meter-note">Birimler konteyner kaldırılınca kalır; <RouterLink :to="podmanRoute('birimler')">Gelişmiş → Podman → Birimler</RouterLink>'den silinir.</p>
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
