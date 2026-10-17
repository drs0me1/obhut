<!-- An application's Depolama (DD-271, phase 3; A5): every mount of every service with its target in the
     container, what it is (a folder of the application, a server folder under /srv, or a tmpfs), its path on
     this server and whether it is read-only; and the application's own data folder. Read-only. -->
<script setup lang="ts">
import { computed } from "vue";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import type { UygulamaAyrinti, UygulamaBaglamasi } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti }>();

const KIND_TEXT: Record<UygulamaBaglamasi["tur"], string> = { app: "Uygulamanın klasörü", srv: "Sunucu klasörü", tmpfs: "Geçici (bellekte)" };
const mounts = computed(() =>
  props.detail.servisler.flatMap((s) => s.baglamalar.map((m) => ({ key: `${s.ad}:${m.hedef}`, service: s.ad, m }))),
);
const access = (m: UygulamaBaglamasi) => (m.tur === "tmpfs" ? "" : m.salt_okunur ? "Salt okunur" : "Okuma-yazma");
</script>

<template>
  <div class="tab-grid tab-grid-wide">
    <Card title="Klasörler" data-testid="mounts">
      <ul v-if="mounts.length" class="mount-list">
        <li v-for="x in mounts" :key="x.key" class="mount" :data-hedef="x.key">
          <span><span class="mono">{{ x.m.hedef }}</span> <span class="muted">· {{ x.service }}</span></span>
          <span class="mount-meta">
            {{ KIND_TEXT[x.m.tur] ?? x.m.tur }}<template v-if="x.m.yol"> · <span class="mono">{{ x.m.yol }}</span></template><template v-if="access(x.m)"> · {{ access(x.m) }}</template>
          </span>
        </li>
      </ul>
      <EmptyState v-else title="Bu uygulamaya bağlı klasör yok" icon="folder" />
    </Card>
    <Card title="Uygulamanın verileri" data-testid="data-folder">
      <p class="mono wrap">{{ detail.veri }}</p>
      <p class="meter-note">Uygulamanın klasörleri burada durur; uygulama kaldırılırken verileri silmeyi seçmedikçe kalır.</p>
    </Card>
  </div>
</template>
