<!-- One connection of a share (DD-192): Tailscale or İnternet, each with its own switch, permission and
     duration, saved at once (the page asks first where the server needs an acknowledgement: read/write, the
     internet over plain HTTP). Its state and, when it cannot be used, the server's reason; the address with
     copy and the fields Infuse asks for. A transport that is not published leads to Erişim, where the
     publication and the HTTPS name live. Every control is off while a change is being saved. -->
<script setup lang="ts">
import { computed, useId } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../../components/icons";
import CopyButton from "../../../components/ui/CopyButton.vue";
import Field from "../../../components/ui/Field.vue";
import StatusPill from "../../../components/ui/StatusPill.vue";
import Switch from "../../../components/ui/Switch.vue";
import { accessRoute } from "../../../sections";
import type { Paylasim, Paylasimlar } from "../../../api/sema";
import type { ShareDays, ShareScope } from "../../../api/paylasim";
import { DURATIONS, PERMISSIONS, connectionState, endpointOf, expiryText, scopeIcon, scopeName, transportText } from "./share";

const props = defineProps<{ share: Paylasim; scope: ShareScope; view: Paylasimlar; busy: boolean }>();
const emit = defineEmits<{ toggle: [on: boolean]; permission: [value: "ro" | "rw"]; days: [value: ShareDays] }>();

const headId = useId();
const reasonId = useId();
const c = computed(() => props.share.connections[props.scope] ?? null);
const name = computed(() => scopeName(props.scope));
const state = computed(() => (c.value ? connectionState(c.value) : null));
const endpoint = computed(() => (c.value ? endpointOf(c.value.url) : null));
// A connection that is off and whose transport is not published cannot be turned on from here.
const blocked = computed(() => Boolean(c.value && !c.value.enabled && !c.value.available));
const label = computed(() => `${props.share.name} · ${name.value}`);

function onPermission(event: Event): void {
  const el = event.target as HTMLSelectElement;
  const value = el.value as "ro" | "rw";
  // The select shows the saved value until the server answers (or the question is declined).
  el.value = c.value?.permission ?? "ro";
  if (c.value && value !== c.value.permission) emit("permission", value);
}

const durationValue = computed(() => (c.value?.expires === null ? "0" : "keep"));

function onDays(event: Event): void {
  const el = event.target as HTMLSelectElement;
  const raw = el.value;
  el.value = durationValue.value;
  if (raw === "keep" || !c.value) return;
  const days = Number(raw) as ShareDays;
  if (days === 0 && c.value.expires === null) return;
  emit("days", days);
}
</script>

<template>
  <section class="share-conn" :class="{ 'share-conn-on': c?.active }" :aria-labelledby="headId" :data-baglanti="scope">
    <div class="share-conn-head">
      <h4 :id="headId" class="share-conn-title"><Icon :name="scopeIcon(scope, view)" :size="18" />{{ name }}</h4>
      <Switch
        v-if="c"
        :model-value="c.enabled"
        :label="`${label} bağlantısı`"
        hide-label
        :disabled="busy || blocked"
        :describedby="c.reason ? reasonId : undefined"
        data-testid="conn-switch"
        @update:model-value="emit('toggle', $event)"
      />
    </div>
    <template v-if="c && state">
      <p class="share-conn-state">
        <StatusPill :tone="state.tone" :dot="c.active" data-testid="conn-state">{{ state.text }}</StatusPill>
        <span class="meter-note" data-testid="conn-transport">{{ transportText(scope, view) }}</span>
      </p>
      <p v-if="c.reason" :id="reasonId" class="cell-note" :class="{ 'warn-text': c.enabled || !c.available }" data-testid="conn-reason">{{ c.reason }}</p>
      <RouterLink v-if="!c.available" :to="accessRoute('adresler', 'paylasim')" class="section-link fit" data-testid="conn-publish">
        WebDAV yayınını Erişim'de düzenle
      </RouterLink>
      <div class="share-conn-controls">
        <Field v-slot="{ id }" label="Erişim">
          <select :id="id" class="input" :value="c.permission" :disabled="busy" :aria-label="`${label} erişim izni`" data-alan="izin" @change="onPermission">
            <option v-for="p in PERMISSIONS" :key="p.id" :value="p.id">{{ p.text }}</option>
          </select>
        </Field>
        <Field v-slot="{ id }" label="Süre">
          <select :id="id" class="input" :value="durationValue" :disabled="busy" :aria-label="`${label} paylaşım süresi`" data-alan="sure" @change="onDays">
            <option v-if="c.expires !== null" value="keep">{{ expiryText(c) }}</option>
            <option v-for="d in DURATIONS" :key="d.days" :value="String(d.days)">{{ d.days ? `${d.text} (bugünden)` : d.text }}</option>
          </select>
        </Field>
      </div>
      <template v-if="endpoint">
        <div class="share-address">
          <span class="mono wrap" data-testid="conn-url">{{ endpoint.url }}</span>
          <CopyButton :text="endpoint.url" :label="`${label} adresi`" />
        </div>
        <dl class="share-infuse" :aria-label="`${name} için Infuse alanları`" data-testid="conn-infuse">
          <div><dt>Infuse</dt><dd>WebDAV ({{ endpoint.secure ? "HTTPS" : "HTTP" }})</dd></div>
          <div><dt>Adres</dt><dd class="mono">{{ endpoint.host }}</dd></div>
          <div><dt>Port</dt><dd class="mono">{{ endpoint.port }}</dd></div>
          <div><dt>Yol</dt><dd class="mono">{{ endpoint.path }}</dd></div>
        </dl>
        <p v-if="!c.active" class="meter-note">Bağlantı kullanılabilir olunca bu adresten erişilir.</p>
      </template>
      <p v-else class="meter-note" data-testid="conn-no-url">Bağlantı adresi kullanılamıyor.</p>
    </template>
    <p v-else class="warn-text">{{ name }} bağlantı bilgisi okunamadı.</p>
  </section>
</template>
