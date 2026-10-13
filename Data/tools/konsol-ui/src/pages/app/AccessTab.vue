<!-- An application's Erişim: the four cells of its row in Erişim's read model (this server, Tailscale,
     WireGuard, the internet) with their addresses and notes, the technical lines behind "Teknik ayrıntı"
     (open state in the address, ?teknik=1), and the way to change it (still Ayarlar → Caddy in phase 2). -->
<script setup lang="ts">
import { computed } from "vue";
import { Icon, type IconName } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { CELL_TEXT, CELL_TONE } from "../../apps";
import { useQueryFlag } from "../../query";
import type { ErisimHucresi, Hizmet } from "../../api/sema";

const props = defineProps<{ row: Hizmet | null }>();

const technical = useQueryFlag("teknik");

const CELLS: readonly { key: "yerel" | "tailscale" | "wireguard" | "internet"; title: string; icon: IconName }[] = [
  { key: "yerel", title: "Bu sunucu", icon: "server" },
  { key: "tailscale", title: "Tailscale", icon: "tailnet" },
  { key: "wireguard", title: "WireGuard", icon: "shield" },
  { key: "internet", title: "İnternet", icon: "globe" },
];

const cells = computed(() => {
  const row = props.row;
  if (!row) return [];
  return CELLS.map((c) => ({ ...c, cell: row[c.key] as ErisimHucresi }));
});

function onToggle(event: Event): void {
  technical.value = (event.target as HTMLDetailsElement).open;
}
</script>

<template>
  <section v-if="row" class="card access-card" aria-label="Erişim" data-testid="access">
    <ul class="access-rows">
      <li v-for="c in cells" :key="c.key" class="access-row" :data-hucre="c.key">
        <Icon :name="c.icon" :size="22" class="access-row-icon" />
        <div class="access-row-text">
          <strong>{{ c.title }}</strong>
          <span v-if="c.cell.adresler.length" class="mono access-addresses">{{ c.cell.adresler.join(" · ") }}</span>
          <span v-if="c.cell.not" class="access-note">{{ c.cell.not }}</span>
          <span v-if="c.cell.uyari" class="warn-text">{{ c.cell.uyari }}</span>
        </div>
        <StatusPill :tone="c.cell.uyari ? 'warning' : CELL_TONE[c.cell.durum]">{{ CELL_TEXT[c.cell.durum] }}</StatusPill>
      </li>
    </ul>
    <details v-if="row.ayrinti.length" class="technical" :open="technical" @toggle="onToggle">
      <summary>Teknik ayrıntı</summary>
      <dl class="facts mono">
        <template v-for="(line, i) in row.ayrinti" :key="i">
          <dt>{{ line.baslik }}</dt>
          <dd>{{ line.deger }}</dd>
        </template>
      </dl>
    </details>
    <div class="access-foot">
      <span class="meter-note">Erişim şimdilik Ayarlar → Caddy bölümünde değiştirilir.</span>
      <a class="btn btn-primary" href="/#/ayarlar/web">Erişimi düzenle</a>
    </div>
  </section>
  <section v-else class="card" aria-label="Erişim" data-testid="access">
    <EmptyState title="Bu uygulamanın yayınladığı bir adres yok" text="Erişim'de bu uygulamaya ait bir satır görünmüyor." icon="globe">
      <a class="btn btn-secondary" href="/#/ayarlar/web">Ayarlar → Caddy</a>
    </EmptyState>
  </section>
</template>
