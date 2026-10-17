<!-- Erişim → Tailscale: this server on the tailnet as `tailscale status` reports it (Erişim's summary): its
     device name, addresses, state, client version, key expiry (a warning under 14 days) and whether it is
     offered as an exit node. Devices, ACLs, key expiry and exit-node approval belong to the Tailscale admin
     console (a link); Konsol changes none of them. -->
<script setup lang="ts">
import { computed } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import type { Tone } from "../../components/ui/types";
import { live, serverNow } from "../../live";
import { tailscaleAdmin } from "../../links";
import { UNKNOWN, date, daysUntil } from "../../format";

const ts = computed(() => live.erisim?.ozet.tailscale ?? null);
const STATES: Record<string, { text: string; tone: Tone; note: string }> = {
  bagli: { text: "Bağlı", tone: "ok", note: "" },
  "bagli-degil": { text: "Bağlı değil", tone: "danger", note: "Konsol'a ve tailnet adlarına öbür cihazlardan ulaşılamaz. Sunucuda tailscaled'i ve oturumu denetleyin." },
  bilinmiyor: { text: "Bilinmiyor", tone: "neutral", note: "Tailscale'in durumu okunamadı." },
};
const state = computed(() => STATES[ts.value?.durum ?? "bilinmiyor"] ?? (STATES.bilinmiyor as { text: string; tone: Tone; note: string }));
const addresses = computed(() => {
  const t = ts.value;
  if (!t) return [];
  return t.adresler.length ? t.adresler : [t.ipv4, t.ipv6].filter(Boolean);
});
const keyLeft = computed(() => (ts.value?.anahtar_bitis ? daysUntil(ts.value.anahtar_bitis, serverNow()) : null));
const keyText = computed(() => {
  const t = ts.value;
  if (!t?.anahtar_bitis) return "Süresiz ya da bilinmiyor";
  const left = keyLeft.value ?? 0;
  if (left < 0) return `${date(t.anahtar_bitis)} · süresi doldu`;
  return `${date(t.anahtar_bitis)} · ${left} gün kaldı`;
});
const exitNode = computed(() => {
  const value = ts.value?.cikis_dugumu;
  if (value === true) return "Sunuluyor: yönetim panelinde onaylanınca cihazlarınız internete bu sunucudan çıkabilir.";
  if (value === false) return "Sunulmuyor.";
  return UNKNOWN;
});
const admin = tailscaleAdmin("machines");
</script>

<template>
  <section v-if="ts" class="card ts-card" aria-labelledby="ts-baslik" data-testid="ts-device">
    <div class="card-head">
      <h2 id="ts-baslik" class="card-title">Bu sunucu tailnet'te</h2>
      <StatusPill :tone="state.tone" :dot="ts.durum === 'bagli'">{{ state.text }}</StatusPill>
    </div>
    <p v-if="state.note" class="card-text">{{ state.note }}</p>
    <dl class="facts" data-testid="ts-tab">
      <dt>Cihaz adı</dt>
      <dd class="mono" data-testid="ts-name">{{ ts.ad || UNKNOWN }}</dd>
      <dt>Adres</dt>
      <dd class="mono" data-testid="ts-addresses">{{ addresses.join(" · ") || UNKNOWN }}</dd>
      <dt>İstemci</dt>
      <dd data-testid="ts-version">{{ ts.surum || UNKNOWN }}</dd>
      <dt>Anahtar süresi</dt>
      <dd data-testid="ts-key" :class="{ 'warn-text': keyLeft !== null && keyLeft < 14 }">{{ keyText }}</dd>
      <dt>Çıkış düğümü</dt>
      <dd data-testid="ts-exit">{{ exitNode }}</dd>
    </dl>
    <p v-if="keyLeft !== null && keyLeft < 14" class="notice notice-warning" role="note" data-testid="ts-key-warning">
      <Icon name="alert" class="notice-icon" />
      <span>Cihaz anahtarının süresi {{ keyLeft < 0 ? "doldu" : `${keyLeft} gün sonra doluyor` }}. Süre dolunca sunucu tailnet'ten düşer; yönetim panelinden anahtarı yenileyin ya da süresini kapatın.</span>
    </p>
    <p class="meter-note" data-testid="ts-admin">
      Cihazlar, erişim kuralları (ACL), anahtar süresi ve çıkış düğümü onayı Tailscale yönetim panelinde değişir; Konsol bunları değiştirmez:
      <a :href="admin" target="_blank" rel="noopener noreferrer" data-testid="ts-admin-link">login.tailscale.com</a>
    </p>
  </section>
  <section v-else class="card" aria-label="Tailscale">
    <EmptyState title="Tailscale bilgisi henüz okunamadı" text="Sunucu yanıt verince burada görünür." icon="tailnet" />
  </section>
</template>
