<!-- An application's Erişim: the four cells of its row in Erişim's read model (this server, Tailscale,
     WireGuard, the internet) with their addresses and notes, the technical lines behind "Teknik ayrıntı"
     (open state in the address, ?teknik=1), and the way to change it: the Yayınla flow over this page
     (?yayinla=<id>). WireGuard itself is changed on Erişim's WireGuard tab. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink, useRouter } from "vue-router";
import { Icon, type IconName } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { CELL_TEXT, CELL_TONE } from "../../apps";
import { candidateOfApp } from "../../access";
import { accessRoute } from "../../sections";
import { updateQuery, useQueryFlag } from "../../query";
import type { ErisimHucresi, Hizmet, Uygulama } from "../../api/sema";

const props = defineProps<{ row: Hizmet | null; app: Pick<Uygulama, "id" | "ad"> }>();
const router = useRouter();

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

const vpn = computed(() => props.app.id === "paket:wireguard");

function onToggle(event: Event): void {
  technical.value = (event.target as HTMLDetailsElement).open;
}

function publish(): void {
  updateQuery(router, { yayinla: props.row ? props.row.id : candidateOfApp(props.app.id) });
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
      <span class="meter-note">Tailscale adı, internet adı ve kimin erişeceği Yayınla ile değişir.</span>
      <button type="button" class="btn btn-primary" data-testid="access-edit" @click="publish">Erişimi düzenle</button>
    </div>
  </section>
  <section v-else class="card" aria-label="Erişim" data-testid="access">
    <EmptyState
      v-if="vpn"
      title="Bu uygulamanın yayınladığı bir adres yok"
      text="WireGuard ağları ve cihazları Erişim'in WireGuard bölümünde."
      icon="shield"
    >
      <RouterLink :to="accessRoute('wireguard')" class="btn btn-secondary">WireGuard ağları</RouterLink>
    </EmptyState>
    <EmptyState v-else title="Bu uygulamanın yayınladığı bir adres yok" text="Erişim'de bu uygulamaya ait bir satır görünmüyor." icon="globe">
      <button type="button" class="btn btn-secondary" data-testid="access-publish" @click="publish">Yayınla</button>
    </EmptyState>
  </section>
</template>
