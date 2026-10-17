<!-- Erişim (DD-258, phase 3): who reaches what, from where. Tabs in the address (?sekme=): Genel (the
     reachability matrix, summaries and warnings), Adresler (every access row with its sheet, ?satir=<row id>;
     local names; the local domain), Tailscale, WireGuard and Güvenlik duvarı. -->
<script setup lang="ts">
import { computed, onMounted } from "vue";
import Tabs from "../components/ui/Tabs.vue";
import OverviewTab from "./erisim/OverviewTab.vue";
import AddressesTab from "./erisim/AddressesTab.vue";
import TailscaleTab from "./erisim/TailscaleTab.vue";
import WireGuardTab from "./erisim/WireGuardTab.vue";
import FirewallTab from "./erisim/FirewallTab.vue";
import { ACCESS_TABS } from "../sections";
import { live, refreshAccess } from "../live";
import { usePageHead } from "../page";

const TABS = ACCESS_TABS.map((t) => ({ id: t.id, label: t.label }));

const summary = computed(() => {
  const e = live.erisim;
  if (!e) return null;
  const internet = e.hizmetler.filter((h) => h.internet.durum === "acik" || h.internet.durum === "kismen").length;
  const tailnet = e.hizmetler.filter((h) => h.tailscale.durum === "acik").length;
  const parts = [`${tailnet} hizmet Tailscale'de`, internet ? `${internet} hizmet internette` : "internete açık hizmet yok"];
  if (e.uyarilar.length) parts.push(`${e.uyarilar.length} uyarı`);
  return parts.join(" · ");
});
usePageHead(() => ({ description: summary.value }));

onMounted(() => void refreshAccess());
</script>

<template>
  <div class="page-body access-page">
    <Tabs :tabs="TABS" label="Erişim bölümleri" param="sekme">
      <template #default="{ active }">
        <OverviewTab v-if="active === 'genel'" />
        <AddressesTab v-else-if="active === 'adresler'" />
        <TailscaleTab v-else-if="active === 'tailscale'" />
        <WireGuardTab v-else-if="active === 'wireguard'" />
        <FirewallTab v-else-if="active === 'guvenlik-duvari'" />
      </template>
    </Tabs>
  </div>
</template>
