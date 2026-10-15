<!-- The plan review (DD-258 goal 4): what a settings change would do before anything changes, as
     POST /api/konsol/ayarlar/plan returns it. The items grouped by area, each before → after; what restarts;
     the warnings; whether it commits at once or waits for a timed confirmation; and, when it could not be
     confirmed from here, why. The sheet around it holds "Uygula" (disabled when `uygulanabilir` is false). -->
<script setup lang="ts">
import { computed } from "vue";
import { Icon, type IconName } from "../icons";
import StatusPill from "./StatusPill.vue";
import type { Tone } from "./types";
import type { AyarPlani, PlanDegisikligi, PlanUyarisi } from "../../api/sema";
import { countdown } from "../../format";

const props = withDefaults(defineProps<{ plan: AyarPlani; heading?: 2 | 3 }>(), { heading: 3 });

const AREAS: Record<PlanDegisikligi["alan"], string> = {
  "guvenlik-duvari": "Güvenlik duvarı",
  dns: "Yerel adlar (DNS)",
  "alan-adi": "Yerel alan adı",
  yayin: "Adresler",
};
const ACTIONS: Record<PlanDegisikligi["islem"], { text: string; tone: Tone }> = {
  ekle: { text: "Eklenir", tone: "ok" },
  kaldir: { text: "Kaldırılır", tone: "danger" },
  degistir: { text: "Değişir", tone: "accent" },
  ac: { text: "Açılır", tone: "ok" },
  kapat: { text: "Kapanır", tone: "neutral" },
};
const LEVELS: Record<PlanUyarisi["seviye"], { icon: IconName; label: string }> = {
  info: { icon: "info", label: "Bilgi" },
  warn: { icon: "alert", label: "Uyarı" },
  bad: { icon: "xcircle", label: "Engel" },
};

const groups = computed(() => {
  const out: { alan: PlanDegisikligi["alan"]; title: string; items: PlanDegisikligi[] }[] = [];
  for (const item of props.plan.degisiklikler) {
    let group = out.find((g) => g.alan === item.alan);
    if (!group) {
      group = { alan: item.alan, title: AREAS[item.alan] ?? item.alan, items: [] };
      out.push(group);
    }
    group.items.push(item);
  }
  return out;
});
const action = (i: PlanDegisikligi) => ACTIONS[i.islem] ?? { text: i.islem, tone: "neutral" as Tone };
const level = (u: PlanUyarisi) => LEVELS[u.seviye] ?? LEVELS.info;
const count = computed(() => props.plan.degisiklikler.length);
</script>

<template>
  <div class="plan" data-testid="plan">
    <p class="plan-window" :class="plan.onay_sn ? 'plan-window-timed' : ''" data-testid="plan-window">
      <Icon :name="plan.onay_sn ? 'clock' : 'check'" :size="18" />
      <span v-if="plan.onay_sn">
        Süreli onay: uygulandıktan sonra <strong>{{ countdown(plan.onay_sn) }}</strong> içinde onaylamazsanız önceki ayarlar geri yüklenir.
      </span>
      <span v-else>Hemen kaydedilir; onay beklenmez.</span>
    </p>
    <section v-for="g in groups" :key="g.alan" class="plan-group" :data-alan="g.alan" :aria-label="g.title">
      <component :is="'h' + heading" class="plan-title">{{ g.title }}</component>
      <ul class="plan-items">
        <li v-for="(i, n) in g.items" :key="n" class="plan-item" :data-islem="i.islem">
          <div class="plan-item-head">
            <StatusPill :tone="action(i).tone">{{ action(i).text }}</StatusPill>
            <strong class="plan-object">{{ i.nesne }}</strong>
          </div>
          <p class="plan-change">
            <template v-if="i.once !== null"><span class="sr-only">Önce: </span><span class="plan-before">{{ i.once }}</span></template>
            <span v-if="i.once !== null && i.sonra !== null" class="plan-arrow" aria-hidden="true">→</span>
            <template v-if="i.sonra !== null"><span class="sr-only">Sonra: </span><span class="plan-after">{{ i.sonra }}</span></template>
          </p>
        </li>
      </ul>
    </section>
    <p class="sr-only">{{ count }} değişiklik</p>
    <section v-if="plan.etkiler.length" class="plan-group" aria-label="Etkiler">
      <component :is="'h' + heading" class="plan-title">Ne olur</component>
      <ul class="plan-effects">
        <li v-for="(e, n) in plan.etkiler" :key="n"><Icon name="refresh" :size="16" /><span>{{ e }}</span></li>
      </ul>
    </section>
    <ul v-if="plan.uyarilar.length" class="plan-warnings" aria-label="Uyarılar">
      <li v-for="(u, n) in plan.uyarilar" :key="n" class="plan-warning" :data-seviye="u.seviye">
        <Icon :name="level(u).icon" :size="18" /><span><span class="sr-only">{{ level(u).label }}: </span>{{ u.metin }}</span>
      </li>
    </ul>
    <p v-if="!plan.uygulanabilir" class="notice notice-danger plan-blocked" role="alert" data-testid="plan-blocked">
      Bu değişiklik buradan uygulanamaz; yukarıdaki nedene bakın.
    </p>
  </div>
</template>
