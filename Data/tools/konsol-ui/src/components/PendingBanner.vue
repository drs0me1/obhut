<!-- A settings change waiting on the server (DD-156's transaction): shown on every page until it is confirmed
     or rolled back. While it awaits confirmation the banner counts down locally from the server's
     `seconds`; the server re-sends the change about once a second. Confirming stays in the current
     Settings page in phase 1. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from "vue";
import { Icon } from "./icons";
import { live } from "../live";
import { countdown } from "../format";

const now = ref(Date.now());
let ticker: number | undefined;

const change = computed(() => live.bekleyen ?? null);
const awaiting = computed(() => change.value?.phase === "awaiting" && typeof change.value.seconds === "number" && Number.isFinite(change.value.seconds));

watch(
  awaiting,
  (on) => {
    if (on && ticker === undefined) {
      now.value = Date.now();
      ticker = window.setInterval(() => (now.value = Date.now()), 1000);
    } else if (!on && ticker !== undefined) {
      clearInterval(ticker);
      ticker = undefined;
    }
  },
  { immediate: true },
);
onBeforeUnmount(() => clearInterval(ticker));

const remaining = computed(() => {
  const c = change.value;
  if (!c || !awaiting.value) return 0;
  return Math.max(0, c.seconds - Math.floor((now.value - live.bekleyenAt) / 1000));
});

const detail = computed(() => {
  switch (change.value?.phase) {
    case "applying":
      return "Değişiklik sunucuda uygulanıyor…";
    case "committed":
      return "Değişiklik kaydedildi.";
    case "rollback":
      return "Önceki ayarlar geri yükleniyor…";
    case "stuck":
      return "Geri alma tamamlanamadı; Ayarlar'da yeniden deneyin ya da bırakın.";
    default:
      return "";
  }
});
</script>

<template>
  <div class="pending-slot" aria-live="polite">
    <section v-if="change" class="pending" aria-labelledby="bekleyen-baslik" :data-phase="change.phase">
      <span class="pending-icon"><Icon name="clock" /></span>
      <div class="pending-text">
        <strong id="bekleyen-baslik">Bekleyen bir ayar değişikliği var</strong>
        <span class="pending-detail" aria-live="off">
          <template v-if="awaiting && remaining > 0">
            <span class="pending-count" data-testid="countdown">{{ countdown(remaining) }}</span> içinde onaylanmazsa önceki ayarlar geri yüklenir.
          </template>
          <template v-else-if="awaiting">Süre doldu; önceki ayarlar geri yükleniyor…</template>
          <template v-else>{{ detail }}</template>
        </span>
      </div>
      <a class="btn btn-primary" href="/#/ayarlar">Ayarlar'da onayla</a>
    </section>
  </div>
</template>
