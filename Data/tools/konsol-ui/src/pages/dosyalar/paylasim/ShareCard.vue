<!-- One folder share (DD-192): the folder, its state, the account both connections use (copyable), Düzenle
     and Kaldır, and the two connections side by side (stacked on a narrow screen). The page does the
     saving; this card says what was asked. -->
<script setup lang="ts">
import { computed, useId } from "vue";
import { Icon } from "../../../components/icons";
import CopyButton from "../../../components/ui/CopyButton.vue";
import StatusPill from "../../../components/ui/StatusPill.vue";
import ShareConnection from "./ShareConnection.vue";
import type { Paylasim, Paylasimlar } from "../../../api/sema";
import type { ShareDays, ShareScope } from "../../../api/paylasim";
import { SCOPES, fullPath, shareState } from "./share";

const props = defineProps<{ share: Paylasim; view: Paylasimlar; root: string; busy: boolean; error: string }>();
const emit = defineEmits<{
  toggle: [scope: ShareScope, on: boolean];
  permission: [scope: ShareScope, value: "ro" | "rw"];
  days: [scope: ShareScope, value: ShareDays];
  edit: [];
  remove: [];
}>();

const titleId = useId();
const state = computed(() => shareState(props.share));
</script>

<template>
  <article class="card share-card" :aria-labelledby="titleId" :data-paylasim="share.id">
    <div class="share-top">
      <span class="share-icon" aria-hidden="true"><Icon name="folder" :size="20" /></span>
      <div class="share-title">
        <h3 :id="titleId" class="card-title wrap">{{ share.name }}</h3>
        <span class="mono wrap muted" data-testid="share-path">{{ fullPath(root, share.path) }}</span>
      </div>
      <StatusPill :tone="state.tone" :dot="state.tone === 'ok'" data-testid="share-state">{{ state.text }}</StatusPill>
      <span class="row-actions share-actions">
        <button type="button" class="btn btn-secondary btn-sm" :disabled="busy" :aria-label="`${share.name} paylaşımını düzenle`" data-eylem="duzenle" @click="emit('edit')">
          <Icon name="pencil" :size="16" />Düzenle
        </button>
        <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="busy" :aria-label="`${share.name} paylaşımını kaldır`" data-eylem="kaldir" @click="emit('remove')">
          <Icon name="trash" :size="16" />Kaldır
        </button>
      </span>
    </div>
    <div class="share-account">
      <span class="share-account-user">
        <span class="muted">Kullanıcı</span>
        <span class="mono wrap" data-testid="share-user">{{ share.username }}</span>
        <CopyButton :text="share.username" :label="`${share.name} kullanıcı adı`" />
      </span>
      <span class="meter-note">İki bağlantı aynı hesabı kullanır; parola Düzenle'den yenilenir.</span>
    </div>
    <p v-if="error" class="form-error" role="alert" data-testid="share-error">{{ error }}</p>
    <div class="share-conns">
      <ShareConnection
        v-for="scope in SCOPES"
        :key="scope"
        :share="share"
        :scope="scope"
        :view="view"
        :busy="busy"
        @toggle="emit('toggle', scope, $event)"
        @permission="emit('permission', scope, $event)"
        @days="emit('days', scope, $event)"
      />
    </div>
  </article>
</template>
