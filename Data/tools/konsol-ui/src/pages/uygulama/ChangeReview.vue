<!-- The review before a container is created or its definition saved (DD-211): what it will be, or each
     field that changes (added, removed, before → after), then what saving does: whether a running container
     is interrupted and re-created, that mounts move no files, that an internet port bypasses Konsol. Nothing
     has changed yet while this shows. -->
<script setup lang="ts">
import { computed } from "vue";
import { Icon, type IconName } from "../../components/icons";
import StatusPill from "../../components/ui/StatusPill.vue";
import type { Tone } from "../../components/ui/types";
import type { Change, Consequence } from "./container";

const props = withDefaults(defineProps<{ changes: readonly Change[]; consequences: readonly Consequence[]; create?: boolean; heading?: string }>(), { create: false, heading: "" });

const KIND: Record<Change["kind"], { text: string; tone: Tone }> = {
  add: { text: "Eklenir", tone: "ok" },
  del: { text: "Kaldırılır", tone: "danger" },
  chg: { text: "Değişir", tone: "accent" },
};
const LEVEL: Record<Consequence["tone"], { seviye: "info" | "warn" | "bad"; icon: IconName }> = {
  info: { seviye: "info", icon: "info" },
  ok: { seviye: "info", icon: "check" },
  warn: { seviye: "warn", icon: "alert" },
  bad: { seviye: "bad", icon: "alert" },
};
const title = computed(() => props.heading || (props.create ? "Oluşturulacak" : `${props.changes.length} değişiklik`));
</script>

<template>
  <div class="plan change-review" data-testid="review">
    <section class="plan-group" :aria-label="title">
      <h3 class="plan-title" tabindex="-1" data-testid="review-title">{{ title }}</h3>
      <dl v-if="create" class="facts review-facts">
        <template v-for="(c, i) in changes" :key="i">
          <dt>{{ c.field }}</dt>
          <dd class="wrap">{{ c.after }}</dd>
        </template>
      </dl>
      <ul v-else class="plan-items" data-testid="diff">
        <li v-for="(c, i) in changes" :key="i" class="plan-item" :data-tur="c.kind">
          <div class="plan-item-head">
            <StatusPill :tone="KIND[c.kind].tone">{{ KIND[c.kind].text }}</StatusPill>
            <strong class="plan-object">{{ c.field }}</strong>
          </div>
          <p class="plan-change wrap">
            <template v-if="c.before"><span class="sr-only">Önce: </span><span class="plan-before" :class="{ 'plan-removed': c.kind === 'del' }">{{ c.before }}</span></template>
            <span v-if="c.before && c.after" class="plan-arrow" aria-hidden="true">→</span>
            <template v-if="c.after"><span class="sr-only">Sonra: </span><span class="plan-after">{{ c.after }}</span></template>
          </p>
        </li>
      </ul>
    </section>
    <section v-if="consequences.length" class="plan-group" aria-label="Ne olur">
      <h3 class="plan-title">Ne olur</h3>
      <ul class="plan-warnings" data-testid="consequences">
        <li v-for="(c, i) in consequences" :key="i" class="plan-warning" :data-seviye="LEVEL[c.tone].seviye" :data-ton="c.tone">
          <Icon :name="LEVEL[c.tone].icon" :size="18" /><span>{{ c.text }}</span>
        </li>
      </ul>
    </section>
  </div>
</template>
