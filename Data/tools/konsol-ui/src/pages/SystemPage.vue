<!-- Sistem (DD-258; A7): Obhut's own care, in tabs in the address (?sekme=): Sağlık (every check, "Denetle ve onar"
     with its last report and the Onarım kaydı), Güncellemeler (Obhut's version and the applications' image
     updates), Hesap (the Konsol account and this session), Sunucu (the facts and the reboot) and İşlem geçmişi (the
     audit log). The theme is the top bar's and the palette's. -->
<script setup lang="ts">
import Tabs from "../components/ui/Tabs.vue";
import HealthTab from "./sistem/HealthTab.vue";
import UpdatesTab from "./sistem/UpdatesTab.vue";
import AccountTab from "./sistem/AccountTab.vue";
import ServerTab from "./sistem/ServerTab.vue";
import AuditTab from "./sistem/AuditTab.vue";
import { SYSTEM_TABS } from "../sections";

const TABS = SYSTEM_TABS.map((t) => ({ id: t.id, label: t.label }));
</script>

<template>
  <div class="page-body system-page">
    <Tabs :tabs="TABS" label="Sistem bölümleri" param="sekme">
      <template #default="{ active }">
        <HealthTab v-if="active === 'saglik'" />
        <UpdatesTab v-else-if="active === 'guncellemeler'" />
        <AccountTab v-else-if="active === 'hesap'" />
        <ServerTab v-else-if="active === 'sunucu'" />
        <AuditTab v-else-if="active === 'gecmis'" />
      </template>
    </Tabs>
  </div>
</template>
