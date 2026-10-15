<!-- A share's sheet (DD-158, DD-192): a new share (?yeni=<folder>) chooses its folder in the user area, its
     account and both connections, each with its switch, permission and duration (read/write and the
     internet over plain HTTP ask for their acknowledgement right there); an edit (?paylasim=<id>) changes
     the folder, the user name or, when typed, the password, while the connections stay on the card. The
     password can be shown, generated (20 random bytes as hex) and copied; it is never kept in the browser
     and is cleared when the sheet closes. The page sends the request; its refusal is shown here in the
     server's words and the form stays. Closing or reloading the browser tab with a draft asks first. -->
<script setup lang="ts">
import { computed, nextTick, ref, useId, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../../components/icons";
import CopyButton from "../../../components/ui/CopyButton.vue";
import Field from "../../../components/ui/Field.vue";
import Modal from "../../../components/ui/Modal.vue";
import Switch from "../../../components/ui/Switch.vue";
import ShareFolderPicker from "./ShareFolderPicker.vue";
import { accessRoute } from "../../../sections";
import { useLeaveGuard } from "../../../leave";
import type { Paylasim, Paylasimlar } from "../../../api/sema";
import type { ConnectionPatch, ShareDays, ShareSave, ShareScope } from "../../../api/paylasim";
import {
  DURATIONS, PERMISSIONS, SCOPES, cleanPath, fullPath, generatePassword, limitsText, passwordProblem, pathProblem, scopeName, transportText,
  usernameProblem, wanMode,
} from "./share";

const props = defineProps<{
  open: boolean;
  /** null: a new share. */
  share: Paylasim | null;
  /** The folder a new share starts with (the address's ?yeni=). */
  path: string;
  view: Paylasimlar | null;
  root: string;
  sending: boolean;
  error: string;
}>();
const emit = defineEmits<{ close: []; pick: [path: string]; submit: [body: ShareSave, done: string]; edit: [id: string]; remove: [share: Paylasim] }>();

interface Draft {
  enabled: boolean;
  permission: "ro" | "rw";
  days: ShareDays;
  ack: boolean;
}

const fPath = ref("");
const fUser = ref("");
const fPass = ref("");
const showPass = ref(false);
const generated = ref(false);
const ackHttp = ref(false);
const tried = ref(false);
const drafts = ref<Record<ShareScope, Draft>>(freshDrafts());
const formId = useId();

const creating = computed(() => props.share === null);
const items = computed(() => props.view?.items ?? []);
const tailOn = computed(() => props.view?.tail_enabled === true);
const wanOn = computed(() => props.view?.wan.available === true);
const http = computed(() => wanMode(props.view) === "http");

function freshDrafts(): Record<ShareScope, Draft> {
  // DD-193: a new folder starts on Tailscale only while that transport is published; the internet off.
  return {
    tailscale: { enabled: props.view?.tail_enabled === true, permission: "ro", days: 7, ack: false },
    wan: { enabled: false, permission: "ro", days: 7, ack: false },
  };
}

function reset(): void {
  fPath.value = props.share ? props.share.path : cleanPath(props.path);
  fUser.value = props.share ? props.share.username : "";
  fPass.value = "";
  showPass.value = false;
  generated.value = false;
  ackHttp.value = false;
  tried.value = false;
  drafts.value = freshDrafts();
}

watch(
  () => [props.open, props.share?.id ?? ""] as const,
  ([open], before) => {
    if (open && (!before || !before[0] || before[1] !== (props.share?.id ?? ""))) reset();
    // The password leaves memory as soon as the sheet closes.
    if (!open) fPass.value = "";
  },
  { immediate: true },
);
// The folder follows the address while a new share is open (a link from the folder list, Back).
watch(
  () => props.path,
  (p) => {
    if (props.open && creating.value && cleanPath(p) !== fPath.value) fPath.value = cleanPath(p);
  },
);

function pick(path: string): void {
  fPath.value = path;
  emit("pick", path);
}

// ---- the rules (the server checks them again)
const existing = computed(() => (creating.value ? items.value.find((s) => s.path === fPath.value) ?? null : null));
const pathError = computed(() => pathProblem(fPath.value));
const userError = computed(() => usernameProblem(fUser.value.trim(), items.value, props.share?.id ?? ""));
const passError = computed(() => passwordProblem(fPass.value, creating.value));
const ackError = (scope: ShareScope) =>
  creating.value && drafts.value[scope].permission === "rw" && !drafts.value[scope].ack ? "Yazma iznini bu bağlantı için onaylayın." : "";
const needsHttpAck = computed(() => creating.value && http.value && drafts.value.wan.enabled);
const httpError = computed(() => (needsHttpAck.value && !ackHttp.value ? "Şifresiz HTTP'yi onaylayın." : ""));
const problems = computed(() =>
  [pathError.value, existing.value ? "Bu klasör zaten paylaşılıyor." : "", userError.value, passError.value, ackError("tailscale"), ackError("wan"), httpError.value].filter(Boolean),
);
const show = (text: string) => (tried.value ? text : "");

const changed = computed(() => {
  const s = props.share;
  if (!s) return true;
  return fPath.value !== s.path || fUser.value.trim() !== s.username || fPass.value !== "";
});
const dirty = computed(() => props.open && (creating.value ? Boolean(fPath.value || fUser.value || fPass.value) : changed.value));
useLeaveGuard(dirty);

const title = computed(() => {
  if (props.share) return `${props.share.name} · paylaşımı düzenle`;
  const name = fPath.value.split("/").pop();
  return name ? `${name} · WebDAV ile paylaş` : "Klasör paylaş";
});
const description = computed(() =>
  props.share ? `${fullPath(props.root, props.share.path)} · ortak klasör ve hesap` : "Ortak klasör ve hesap · bağımsız Tailscale ve internet bağlantıları",
);

function generate(): void {
  fPass.value = generatePassword();
  showPass.value = true;
  generated.value = true;
}

function patchOf(d: Draft): ConnectionPatch {
  return { enabled: d.enabled, permission: d.permission, days: d.days, ...(d.permission === "rw" ? { ack_write: true as const } : {}) };
}

async function submit(): Promise<void> {
  if (props.sending) return;
  tried.value = true;
  if (problems.value.length) {
    await nextTick();
    document.querySelector<HTMLElement>(`#${CSS.escape(formId)} [aria-invalid="true"]`)?.focus();
    return;
  }
  const user = fUser.value.trim();
  if (creating.value) {
    const body: ShareSave = {
      path: fPath.value,
      username: user,
      password: fPass.value,
      connections: { tailscale: patchOf(drafts.value.tailscale), wan: patchOf(drafts.value.wan) },
      ...(needsHttpAck.value ? { ack_wan_http: true as const } : {}),
    };
    emit("submit", body, `${fPath.value.split("/").pop()} paylaşımı hazır.`);
    return;
  }
  const s = props.share as Paylasim;
  const body: ShareSave = { id: s.id };
  if (fPath.value !== s.path) body.path = fPath.value;
  if (user !== s.username) body.username = user;
  if (fPass.value) body.password = fPass.value;
  emit("submit", body, `${s.name} paylaşımı güncellendi.`);
}

function onRwChange(d: Draft): void {
  if (d.permission !== "rw") d.ack = false;
}
function setEnabled(scope: ShareScope, on: boolean): void {
  drafts.value[scope].enabled = on;
  if (scope === "wan" && !on) ackHttp.value = false;
}
</script>

<template>
  <Modal :open="open" variant="sheet" :title="title" :description="description" @close="emit('close')">
    <form :id="formId" class="form-stack share-form" novalidate data-testid="share-form" @submit.prevent="submit">
      <Field v-slot="{ id, describedby, invalid }" label="Klasör" :hint="creating ? 'Kullanıcı alanındaki bir klasör; alt klasörleri de paylaşılır.' : 'Klasörü değiştirmek hesabı ve bağlantıları korur.'" :error="show(pathError)">
        <ShareFolderPicker
          :id="id"
          :model-value="fPath"
          :describedby="describedby"
          :invalid="invalid"
          :disabled="sending"
          :root="root"
          :shared="items.filter((s) => s.id !== share?.id).map((s) => s.path)"
          @update:model-value="pick"
        />
      </Field>
      <div v-if="existing" class="notice" role="note" data-testid="share-exists">
        <Icon name="info" class="notice-icon" />
        <div class="share-exists">
          <span>Bu klasör zaten paylaşılıyor; hesabı ve bağlantıları onun kartında.</span>
          <button type="button" class="btn btn-secondary btn-sm fit" data-testid="share-exists-edit" @click="emit('edit', existing.id)">Paylaşımı düzenle</button>
        </div>
      </div>

      <Field v-slot="{ id, describedby, invalid }" label="Kullanıcı adı" hint="3–32 karakter: harf, rakam, . _ -; harf ya da rakamla başlar. Paylaşımlar arasında tekrarlanmaz." :error="show(userError)">
        <input
          :id="id"
          v-model="fUser"
          class="input"
          type="text"
          maxlength="32"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          placeholder="ör. aile-medya"
          :disabled="sending"
          :aria-describedby="describedby"
          :aria-invalid="invalid || undefined"
          data-alan="kullanici"
        />
      </Field>

      <Field
        v-slot="{ id, describedby, invalid }"
        :label="creating ? 'Parola' : 'Yeni parola'"
        :optional="!creating"
        :hint="creating ? 'En az 8 karakter; : olamaz.' : 'Boş bırakırsanız kayıtlı parola korunur.'"
        :error="show(passError)"
      >
        <div class="share-pass">
          <input
            :id="id"
            v-model="fPass"
            class="input mono"
            :type="showPass ? 'text' : 'password'"
            maxlength="256"
            autocomplete="new-password"
            autocapitalize="off"
            spellcheck="false"
            :placeholder="creating ? 'En az 8 karakter' : 'Boş bırakın: mevcut parola korunur'"
            :disabled="sending"
            :aria-describedby="describedby"
            :aria-invalid="invalid || undefined"
            data-alan="parola"
          />
          <button
            type="button"
            class="icon-btn"
            :aria-pressed="showPass"
            :aria-label="showPass ? 'Parolayı gizle' : 'Parolayı göster'"
            :title="showPass ? 'Parolayı gizle' : 'Parolayı göster'"
            :aria-controls="id"
            data-testid="share-pass-show"
            @click="showPass = !showPass"
          >
            <Icon :name="showPass ? 'eyeOff' : 'eye'" :size="18" />
          </button>
          <CopyButton :text="fPass" label="Parola" :disabled="!fPass" />
        </div>
      </Field>
      <div class="share-pass-tools">
        <button type="button" class="btn btn-secondary btn-sm fit" :disabled="sending" data-testid="share-pass-generate" @click="generate"><Icon name="key" :size="16" />Parola üret</button>
        <p class="meter-note">Parolayı kaydetmeden önce not edin; daha sonra gösterilmez. Tarayıcıya kaydedilmez.</p>
        <p v-if="generated" class="sr-only" role="status">40 karakterlik parola üretildi ve gösteriliyor.</p>
      </div>

      <template v-if="creating">
        <fieldset v-for="scope in SCOPES" :key="scope" class="share-draft" :data-baglanti="scope">
          <legend class="form-section-title">{{ scopeName(scope) }}</legend>
          <p class="meter-note">{{ transportText(scope, view) }}</p>
          <Switch
            :model-value="drafts[scope].enabled"
            :label="`${scopeName(scope)} bağlantısı açık`"
            :disabled="sending || (!drafts[scope].enabled && !(scope === 'tailscale' ? tailOn : wanOn))"
            :data-testid="'draft-switch-' + scope"
            @update:model-value="setEnabled(scope, $event)"
          />
          <p v-if="scope === 'tailscale' && !tailOn" class="cell-note warn-text">
            Tailscale yayını kapalı. <RouterLink :to="accessRoute('adresler', 'paylasim')">Erişim'de açın.</RouterLink>
          </p>
          <p v-if="scope === 'wan' && !wanOn" class="cell-note warn-text" data-testid="draft-wan-reason">{{ view?.wan.reason || "İnternet erişimi kullanılamıyor." }}</p>
          <div class="share-conn-controls">
            <Field v-slot="{ id }" label="Erişim">
              <select :id="id" v-model="drafts[scope].permission" class="input" :disabled="sending" data-alan="izin" @change="onRwChange(drafts[scope])">
                <option v-for="p in PERMISSIONS" :key="p.id" :value="p.id">{{ p.text }}</option>
              </select>
            </Field>
            <Field v-slot="{ id }" label="Süre">
              <select :id="id" v-model.number="drafts[scope].days" class="input" :disabled="sending" data-alan="sure">
                <option v-for="d in DURATIONS" :key="d.days" :value="d.days">{{ d.text }}</option>
              </select>
            </Field>
          </div>
          <label v-if="drafts[scope].permission === 'rw'" class="check-option" :data-onay="'yazma-' + scope">
            <input v-model="drafts[scope].ack" type="checkbox" :disabled="sending" :aria-invalid="Boolean(show(ackError(scope))) || undefined" />
            <span>{{ scopeName(scope) }}: yazma; yükleme, üzerine yazma, taşıma ve kalıcı silmeyi kapsar. WebDAV ile silinenler Çöp'e gitmez. Onaylıyorum.</span>
          </label>
          <p v-if="show(ackError(scope))" class="field-error">{{ ackError(scope) }}</p>
          <template v-if="scope === 'wan' && needsHttpAck">
            <label class="check-option" data-onay="http">
              <input v-model="ackHttp" type="checkbox" :disabled="sending" :aria-invalid="Boolean(show(httpError)) || undefined" />
              <span>İnternet üzerinden HTTP, parola ve dosyaları şifrelemeden gönderir. Onaylıyorum.</span>
            </label>
            <p v-if="show(httpError)" class="field-error">{{ httpError }}</p>
          </template>
        </fieldset>
        <p class="meter-note">İki bağlantı da kapalıysa hesap duraklatılmış olarak saklanır. {{ limitsText(view?.limits ?? {}) }}</p>
      </template>
      <p v-else class="meter-note">Bağlantılar (açık ya da kapalı, izin, süre) paylaşımın kartında değişir.</p>

      <p class="notice" role="note"><Icon name="refresh" class="notice-icon" /><span>Kaydetmek WebDAV hizmetini yeniler ve sürmekte olan aktarımları keser. Kapalı ya da süresi dolmuş bağlantılar kendiliğinden açılmaz.</span></p>
      <p v-if="error" class="form-error" role="alert" data-testid="share-form-error">{{ error }}</p>

      <div v-if="share" class="danger-zone">
        <p class="meter-note">Kaldırmak iki bağlantıyı ve hesabı iptal eder; klasör ve dosyalar silinmez.</p>
        <button type="button" class="btn btn-danger-quiet btn-sm fit" :disabled="sending" data-testid="share-form-remove" @click="emit('remove', share)">
          <Icon name="trash" :size="16" />Paylaşımı kaldır…
        </button>
      </div>
    </form>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="sending" @click="emit('close')">Vazgeç</button>
      <button type="submit" :form="formId" class="btn btn-primary" :disabled="sending || !changed" data-testid="share-form-go">
        <Icon name="share" :size="18" />{{ sending ? "Kaydediliyor…" : creating ? "Paylaşımı oluştur" : "Kaydet" }}
      </button>
    </template>
  </Modal>
</template>
