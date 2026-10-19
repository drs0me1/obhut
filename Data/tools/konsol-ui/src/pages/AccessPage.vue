<!-- Erişim (DD-258; rebuild phase 5, A7): who reaches what, from where. Tabs in the address (?sekme=): Genel (the
     summaries and the reachability matrix), Adresler (every access row with its sheet, ?satir=<row id>), Yerel adlar
     (the local names, the upstream DNS and the local domain), WireGuard and Güvenlik duvarı (the operator's port
     rules beside the locked rows). "Adres aç" beside the tabs gives an application's raw TCP port a
     Tailscale name: it opens the first such port's sheet on Adresler, where another port can be chosen. -->
<script setup lang="ts">
import { computed, onMounted } from "vue";
import { useRouter } from "vue-router";
import { Icon } from "../components/icons";
import Tabs from "../components/ui/Tabs.vue";
import OverviewTab from "./erisim/OverviewTab.vue";
import AddressesTab from "./erisim/AddressesTab.vue";
import NamesTab from "./erisim/NamesTab.vue";
import WireGuardTab from "./erisim/WireGuardTab.vue";
import FirewallTab from "./erisim/FirewallTab.vue";
import { ACCESS_TABS, accessRoute } from "../sections";
import { accessCounts, addressCandidates } from "../access";
import { live, refreshAccess } from "../live";
import { usePageHead } from "../page";

const TABS = ACCESS_TABS.map((t) => ({ id: t.id, label: t.label }));
const router = useRouter();

const summary = computed(() => {
  const e = live.erisim;
  if (!e) return null;
  const c = accessCounts(e.hizmetler);
  const parts = [`${c.tailscale} adres Tailscale'de`, `${c.internet} internet adı`];
  if (e.uyarilar.length) parts.push(`${e.uyarilar.length} uyarı`);
  return parts.join(" · ");
});
usePageHead(() => ({ description: summary.value }));

const candidates = computed(() => addressCandidates(live.erisim?.hizmetler ?? []));
const locked = computed(() => Boolean(live.bekleyen));
function openAddress(): void {
  const first = candidates.value[0];
  if (first) void router.push(accessRoute("adresler", first.id, "adres-ac"));
}

onMounted(() => void refreshAccess());
</script>

<template>
  <div class="page-body access-page">
    <Tabs :tabs="TABS" label="Erişim bölümleri" param="sekme">
      <template #end>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          :disabled="!candidates.length || locked"
          :title="candidates.length ? undefined : 'Adresi olmayan bir TCP portu yok'"
          data-testid="adres-ac"
          @click="openAddress"
        >
          <Icon name="plus" :size="16" />Adres aç
        </button>
      </template>
      <template #default="{ active }">
        <OverviewTab v-if="active === 'genel'" />
        <AddressesTab v-else-if="active === 'adresler'" />
        <NamesTab v-else-if="active === 'adlar'" />
        <WireGuardTab v-else-if="active === 'wireguard'" />
        <FirewallTab v-else-if="active === 'guvenlik-duvari'" />
      </template>
    </Tabs>
  </div>
</template>
