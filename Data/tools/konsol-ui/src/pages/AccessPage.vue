<!-- Erişim (DD-258, phase 3): who reaches what, from where. Tabs in the address (?sekme=): Genel (the
     reachability matrix, summaries and warnings), Adresler (publications, local names, the local domain),
     Tailscale, WireGuard and Güvenlik duvarı. "Yayınla" opens the Yayınla flow over the page (?yayinla=sec);
     the flow itself is part of the shell (App.vue), so an application's page opens it too. -->
<script setup lang="ts">
import { computed, onMounted } from "vue";
import { useRouter } from "vue-router";
import { Icon } from "../components/icons";
import Tabs from "../components/ui/Tabs.vue";
import OverviewTab from "./erisim/OverviewTab.vue";
import AddressesTab from "./erisim/AddressesTab.vue";
import TailscaleTab from "./erisim/TailscaleTab.vue";
import WireGuardTab from "./erisim/WireGuardTab.vue";
import FirewallTab from "./erisim/FirewallTab.vue";
import { ACCESS_TABS } from "../sections";
import { live, refreshAccess } from "../live";
import { usePageHead } from "../page";
import { updateQuery } from "../query";

const router = useRouter();
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

function publish(): void {
  updateQuery(router, { yayinla: "sec" });
}

onMounted(() => void refreshAccess());
</script>

<template>
  <div class="page-body access-page">
    <Tabs :tabs="TABS" label="Erişim bölümleri" param="sekme">
      <template #end>
        <button type="button" class="btn btn-primary btn-sm" data-testid="publish" @click="publish"><Icon name="globe" :size="16" />Yayınla</button>
      </template>
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
