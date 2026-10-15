<!-- Sistem (DD-258, phase 4a; DD-266): the server's own care, in tabs in the address (?sekme=): Sağlık (every
     check, "Denetle ve onar" with its last report and log), Güncellemeler, Hesap (the Konsol account and this
     session), Sunucu (the facts and the reboot), Görünüm (the theme) and Günlük (the audit log). -->
<script setup lang="ts">
import Card from "../components/ui/Card.vue";
import Tabs from "../components/ui/Tabs.vue";
import ThemeControl from "../components/ThemeControl.vue";
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
        <div v-else-if="active === 'gorunum'" class="system-tab" data-testid="appearance">
          <Card title="Görünüm">
            <ThemeControl />
          </Card>
        </div>
        <AuditTab v-else-if="active === 'gunluk'" />
      </template>
    </Tabs>
  </div>
</template>
