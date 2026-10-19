<!-- İşlemler (DD-258; rebuild phase 5): the settings change waiting for its confirmation (named as the banner names
     it; it is confirmed or rolled back from the banner), the jobs the server is running (applications, Podman's
     cleanup, the Obhut update, repair) and the ones that just ended with their result (a failed one's reason,
     such as what a cleanup left and why), as the event stream or GET /api/konsol/etkinlik report them. A side
     panel: focus stays inside, Esc or the backdrop closes it. -->
<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import { Icon } from "./icons";
import { trapTab } from "./focus";
import StatusPill from "./ui/StatusPill.vue";
import { finishedJobs, live, runningJobs } from "../live";
import { closeSurface, ui } from "../ui";
import { clock } from "../format";
import { pendingTitle } from "../pending";
import type { Tone } from "./ui/types";
import type { BekleyenDegisiklik, Islem } from "../api/sema";

const panel = ref<HTMLElement | null>(null);
const closeButton = ref<HTMLButtonElement | null>(null);
const open = computed(() => ui.open === "drawer");

watch(open, (isOpen) => {
  if (isOpen) void nextTick(() => closeButton.value?.focus());
});

const KINDS: Record<Islem["tur"], string> = { uygulama: "Uygulama", konteyner: "Podman", guncelleme: "Güncelleme", onarim: "Onarım" };
const STATES: Record<Islem["durum"], string> = { calisiyor: "Çalışıyor", tamam: "Tamamlandı", hata: "Hata" };
const kind = (j: Islem) => KINDS[j.tur] ?? j.tur;
const state = (j: Islem) => STATES[j.durum] ?? j.durum;

// The pending change: its name and its phase in a word; Onayla and Geri al stay in the banner.
const change = computed(() => live.bekleyen ?? null);
const PHASES: Record<BekleyenDegisiklik["phase"], { text: string; tone: Tone }> = {
  applying: { text: "Uygulanıyor", tone: "accent" },
  awaiting: { text: "Onay bekliyor", tone: "warning" },
  committed: { text: "Kaydedildi", tone: "ok" },
  rollback: { text: "Geri alınıyor", tone: "warning" },
  stuck: { text: "Geri alma takıldı", tone: "danger" },
};
const phase = computed(() => (change.value ? PHASES[change.value.phase] ?? { text: change.value.phase, tone: "neutral" as Tone } : null));

const connection = computed(() => {
  switch (live.connection) {
    case "canli":
      return "Canlı bağlantı açık.";
    case "yeniden":
      return "Canlı bağlantı yeniden kuruluyor…";
    case "yoklama":
      return "Canlı bağlantı yok; durum birkaç saniyede bir okunuyor.";
    default:
      return "Bağlanılıyor…";
  }
});

function onKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    closeSurface();
  } else trapTab(event, panel.value);
}
</script>

<template>
  <Transition name="drawer">
    <div v-if="open" class="layer layer-drawer" @keydown="onKeydown">
      <div class="scrim" aria-hidden="true" @click="closeSurface()"></div>
      <section ref="panel" class="drawer" role="dialog" aria-modal="true" aria-labelledby="cekmece-baslik">
        <header class="drawer-head">
          <h2 id="cekmece-baslik">İşlemler</h2>
          <button ref="closeButton" type="button" class="icon-btn" aria-label="Kapat" @click="closeSurface()">
            <Icon name="close" />
          </button>
        </header>
        <div class="drawer-body">
          <section v-if="change && phase" class="job drawer-pending" aria-labelledby="cekmece-bekleyen" data-testid="drawer-pending">
            <div class="job-line">
              <strong id="cekmece-bekleyen" class="job-name">{{ pendingTitle(change, live.erisim) }}</strong>
              <StatusPill :tone="phase.tone">{{ phase.text }}</StatusPill>
            </div>
            <span class="job-meta">Bekleyen ayar değişikliği · onay ve geri alma sayfanın üstündeki bantta</span>
          </section>
          <ul v-if="runningJobs.length" class="jobs" aria-label="Çalışan işlemler">
            <li v-for="j in runningJobs" :key="j.tur + ':' + j.id" class="job" data-durum="calisiyor">
              <div class="job-line">
                <strong class="job-name">{{ j.ad }}</strong>
                <StatusPill tone="accent">{{ state(j) }}</StatusPill>
              </div>
              <span class="job-meta">{{ kind(j) }}<template v-if="j.adim"> · {{ j.adim }}</template></span>
            </li>
          </ul>
          <p v-else class="empty">{{ live.islemler === null ? "Çalışan işlemler henüz okunamadı." : "Şu an çalışan işlem yok" }}</p>
          <template v-if="finishedJobs.length">
            <h3 class="drawer-sub">Son biten</h3>
            <ul class="jobs" aria-label="Son biten işlemler">
              <li v-for="j in finishedJobs" :key="j.tur + ':' + j.id" class="job" :data-durum="j.durum">
                <div class="job-line">
                  <strong class="job-name">{{ j.ad }}</strong>
                  <StatusPill :tone="j.durum === 'hata' ? 'danger' : 'ok'">{{ state(j) }}</StatusPill>
                </div>
                <span class="job-meta">{{ kind(j) }}<template v-if="j.adim"> · {{ j.adim }}</template><template v-if="j.bitis"> · {{ clock(j.bitis) }}</template></span>
              </li>
            </ul>
          </template>
        </div>
        <p class="drawer-foot" data-testid="connection">{{ connection }}</p>
      </section>
    </div>
  </Transition>
</template>
