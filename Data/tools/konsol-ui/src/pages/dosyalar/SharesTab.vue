<!-- Dosyalar → Paylaşımlar (phase 4b, DD-267; DD-158, DD-179, DD-190, DD-192): every folder share with its
     two independent connections (Tailscale, İnternet), each switched, given a permission and a duration
     at once; turning read/write on and the internet on over plain HTTP ask first (the server needs the
     acknowledgement), removal takes the typed word. The boundary notice (?sinir=1 opens its detail), n/max,
     the transports and where they are published (Erişim keeps the publication and the HTTPS name). A new share opens with ?yeni=<folder> (a folder list links here),
     a share's sheet with ?paylasim=<id>. One change at a time; every reply is the whole view. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink, useRoute, useRouter } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Modal from "../../components/ui/Modal.vue";
import ShareCard from "./paylasim/ShareCard.vue";
import ShareSheet from "./paylasim/ShareSheet.vue";
import { readShares, removeShare, saveShare, type ConnectionPatch, type ShareDays, type ShareSave, type ShareScope } from "../../api/paylasim";
import { live, refreshAccess } from "../../live";
import { updateQuery, useQueryFlag } from "../../query";
import { accessRoute } from "../../sections";
import { fullPath, scopeName, transportText, wanMode } from "./paylasim/share";
import type { Paylasim, Paylasimlar } from "../../api/sema";

const route = useRoute();
const router = useRouter();

const message = (err: unknown) => (err instanceof Error ? err.message : String(err));

// ---- the view
const view = ref<Paylasimlar | null>(null);
const loadError = ref("");
/** A change is being saved: every control waits, and no read replaces its reply. */
const busy = ref(false);
let seq = 0;

async function load(): Promise<void> {
  if (busy.value) return;
  const mine = ++seq;
  try {
    const value = await readShares();
    if (mine !== seq) return;
    view.value = value;
    loadError.value = "";
  } catch (err) {
    if (mine === seq) loadError.value = message(err);
  }
}

const onVisibility = () => {
  if (!document.hidden) void load();
};
onMounted(() => {
  void load();
  document.addEventListener("visibilitychange", onVisibility);
});
onBeforeUnmount(() => document.removeEventListener("visibilitychange", onVisibility));
// The transports follow Erişim's settings (the WebDAV publication, the HTTPS name).
watch(() => live.ayarSurumu, () => void load());

const root = computed(() => live.kaynaklar?.root ?? "");
const items = computed(() => view.value?.items ?? []);
const full = computed(() => (view.value ? items.value.length >= view.value.max : false));
const boundary = useQueryFlag("sinir");

// ---- one change at a time
const note = ref("");
/** A refusal in the server's words, where it belongs: a share's card ("" for the page) or the sheet. */
const failure = ref<{ where: string; text: string } | null>(null);

async function write(run: () => Promise<Paylasimlar>, done: string, where: string): Promise<boolean> {
  if (busy.value) return false;
  busy.value = true;
  failure.value = null;
  note.value = "";
  seq += 1;
  try {
    view.value = await run();
    loadError.value = "";
    note.value = done;
    // The WebDAV row in Erişim follows the shares.
    void refreshAccess();
    return true;
  } catch (err) {
    failure.value = { where, text: message(err) };
    return false;
  } finally {
    busy.value = false;
    if (failure.value) void load();
  }
}

const errorOf = (where: string) => (failure.value?.where === where ? failure.value.text : "");
const save = (body: ShareSave, done: string, where: string) => write(() => saveShare(body), done, where);
const patch = (s: Paylasim, scope: ShareScope, value: ConnectionPatch, done: string, extra: Partial<ShareSave> = {}) =>
  save({ id: s.id, connections: { [scope]: value }, ...extra }, done, s.id);

// ---- the card's controls
type Ask = { kind: "yazma"; share: Paylasim; scope: ShareScope } | { kind: "http"; share: Paylasim } | { kind: "kaldir"; share: Paylasim };
const ask = ref<Ask | null>(null);
const removeConfirmed = ref(false);

function toggle(s: Paylasim, scope: ShareScope, on: boolean): void {
  if (scope === "wan" && on && wanMode(view.value) === "http") {
    ask.value = { kind: "http", share: s };
    return;
  }
  void sendToggle(s, scope, on);
}

function sendToggle(s: Paylasim, scope: ShareScope, on: boolean, extra: Partial<ShareSave> = {}): Promise<boolean> {
  const c = s.connections[scope];
  const done = on
    ? c?.expired
      ? `${s.name} · ${scopeName(scope)}: seçim kaydedildi. Bağlantının süresi dolmuş; açmak için yeni bir süre seçin.`
      : `${s.name} · ${scopeName(scope)} bağlantısı açıldı.`
    : `${s.name} · ${scopeName(scope)} bağlantısı kapatıldı; hesap ve dosyalar korundu.`;
  return patch(s, scope, { enabled: on }, done, extra);
}

function setPermission(s: Paylasim, scope: ShareScope, value: "ro" | "rw"): void {
  if (value === "rw") {
    ask.value = { kind: "yazma", share: s, scope };
    return;
  }
  void patch(s, scope, { permission: "ro" }, `${s.name} · ${scopeName(scope)} erişimi salt okunur.`);
}

function setDays(s: Paylasim, scope: ShareScope, days: ShareDays): void {
  void patch(s, scope, { days }, `${s.name} · ${scopeName(scope)} süresi kaydedildi${days ? `: ${days} gün, bugünden` : ": süresiz"}.`);
}

async function confirmAsk(): Promise<void> {
  const a = ask.value;
  if (!a) return;
  let ok = false;
  if (a.kind === "yazma") ok = await patch(a.share, a.scope, { permission: "rw", ack_write: true }, `${a.share.name} · ${scopeName(a.scope)} erişimi okuma ve yazma.`);
  else if (a.kind === "http") ok = await sendToggle(a.share, "wan", true, { ack_wan_http: true });
  else if (a.kind === "kaldir") {
    const s = a.share;
    ok = await write(() => removeShare(s.id), `${s.name} paylaşımı kaldırıldı; klasör ve dosyalar korundu.`, "kaldir");
    if (ok && editId.value === s.id) closeSheet();
  }
  if (ok) ask.value = null;
}

function closeAsk(): void {
  if (busy.value) return;
  ask.value = null;
  if (failure.value?.where === "kaldir") failure.value = null;
}

function askRemove(s: Paylasim): void {
  failure.value = null;
  removeConfirmed.value = false;
  ask.value = { kind: "kaldir", share: s };
}

const askTitle = computed(() => {
  const a = ask.value;
  if (!a) return "";
  if (a.kind === "yazma") return "Yazma izni açılsın mı?";
  if (a.kind === "http") return "İnternet erişimi şifresiz HTTP ile açılsın mı?";
  return `“${a.share.name}” paylaşımı kaldırılsın mı?`;
});
const askDescription = computed(() => {
  const a = ask.value;
  if (!a) return "";
  if (a.kind === "yazma") return `${a.share.name} · ${scopeName(a.scope)}`;
  if (a.kind === "http") return `${a.share.name} · ${transportText("wan", view.value)}`;
  return fullPath(root.value, a.share.path);
});

// ---- the sheet, in the address: ?yeni=<folder> for a new share, ?paylasim=<id> for one
const queryText = (name: string): string | null => {
  if (!(name in route.query)) return null;
  const value = route.query[name];
  const text = Array.isArray(value) ? value[0] : value;
  return typeof text === "string" ? text : "";
};
const newPath = computed(() => queryText("yeni"));
const editId = computed(() => queryText("paylasim") || "");
const editing = computed(() => (editId.value ? items.value.find((s) => s.id === editId.value) ?? null : null));
const sheetOpen = computed(() => Boolean(view.value) && (editing.value !== null || (!editId.value && newPath.value !== null)));
const sending = ref(false);

function openCreate(): void {
  failure.value = null;
  updateQuery(router, { yeni: "", paylasim: null });
}
function openEdit(s: Paylasim): void {
  failure.value = null;
  updateQuery(router, { paylasim: s.id, yeni: null });
}
function closeSheet(): void {
  if (sending.value) return;
  if (failure.value?.where === "sheet") failure.value = null;
  updateQuery(router, { yeni: null, paylasim: null });
}

// A link to a folder that is already shared opens that share; a share that is gone says so. Only when the
// sheet is asked for or the view arrives: a folder chosen inside the sheet says so there instead.
watch(
  [() => newPath.value !== null, editId, () => view.value !== null],
  ([creating, id, known]) => {
    if (!known) return;
    if (id && !editing.value) {
      note.value = "Bu paylaşım bulunamadı; kaldırılmış olabilir.";
      updateQuery(router, { paylasim: null });
    } else if (creating && !id) {
      const path = (newPath.value ?? "").split("/").filter(Boolean).join("/");
      const found = path ? items.value.find((s) => s.path === path) : undefined;
      if (found) updateQuery(router, { yeni: null, paylasim: found.id });
    }
  },
  { immediate: true },
);

async function submitSheet(body: ShareSave, done: string): Promise<void> {
  sending.value = true;
  try {
    if (await save(body, done, "sheet")) {
      sending.value = false;
      closeSheet();
    }
  } finally {
    sending.value = false;
    if ("password" in body) body.password = "";
  }
}

// The sheet gives the page's modal surface back first (focus returns to its opener); then the question opens.
async function removeFromSheet(s: Paylasim): Promise<void> {
  closeSheet();
  if (sheetOpen.value) {
    await new Promise<void>((resolve) => {
      const stop = watch(sheetOpen, (on) => {
        if (on) return;
        stop();
        resolve();
      });
    });
  }
  await nextTick();
  askRemove(s);
}

const counts = computed(() => (view.value ? `${items.value.length}/${view.value.max} klasör` : ""));
</script>

<template>
  <div class="shares" data-testid="shares">
    <section class="notice share-boundary" aria-labelledby="paylasim-sinir" data-testid="share-boundary">
      <Icon name="shield" class="notice-icon" />
      <div class="share-boundary-text">
        <p id="paylasim-sinir" class="notice-title">Paylaşmadan önce erişim sınırını kontrol edin</p>
        <p class="notice-list">Alıcıya yalnız paylaşımın adresini ve hesabını verin; Konsol ve SSH yalnız yöneticide kalmalı. Konsol parolasını paylaşmayın.</p>
        <div v-if="boundary" id="paylasim-sinir-ayrinti" class="notice-list share-boundary-more" data-testid="share-boundary-more">
          <p>Konsol hesabıyla giren kişi tüm dosyaları yönetebilir. Tailscale ACL ve grants kuralları burada değişmez; alıcının cihazına yalnız WebDAV portunu açın.</p>
          <p>
            Tailscale bağlantısı şifreli tünelde taşınır.
            <template v-if="wanMode(view) === 'http'">İnternet üzerinden HTTP, parola ve dosyaları şifrelemeden gönderir. </template>
            Dosya kilidi isteyen istemciler bu adresle uyumlu olmayabilir; Infuse ve Finder uyumunu istemcide ayrıca sınayın.
          </p>
        </div>
        <button type="button" class="btn btn-secondary btn-sm fit" :aria-expanded="boundary" aria-controls="paylasim-sinir-ayrinti" data-testid="share-boundary-toggle" @click="boundary = !boundary">
          {{ boundary ? "Ayrıntıyı gizle" : "Ayrıntı" }}
        </button>
      </div>
    </section>

    <section class="card share-head" aria-labelledby="paylasim-baslik" data-testid="share-head">
      <div class="card-head">
        <div class="share-head-title">
          <h2 id="paylasim-baslik" class="card-title">Klasör paylaşımları</h2>
          <span v-if="view" class="meter-note" data-testid="share-count">{{ counts }}</span>
        </div>
        <button type="button" class="btn btn-primary btn-sm" :disabled="!view || busy || full" :aria-describedby="full ? 'paylasim-sinir-dolu' : undefined" data-testid="share-add" @click="openCreate">
          <Icon name="plus" :size="16" />Paylaşım ekle
        </button>
      </div>
      <p v-if="full" id="paylasim-sinir-dolu" class="meter-note warn-text">En çok {{ view?.max }} paylaşım oluşturulabilir.</p>
      <dl v-if="view" class="share-routes" data-testid="share-routes">
        <div data-yol="tailscale"><dt>Tailscale</dt><dd>{{ transportText("tailscale", view) }}</dd></div>
        <div data-yol="wan"><dt>İnternet</dt><dd>{{ view.wan.available ? transportText("wan", view) : view.wan.reason || "Kullanılamıyor" }}</dd></div>
      </dl>
      <p class="meter-note">Seçimler anında kaydedilir. Yeni süre bugünden başlar; bağlantıyı açmak süreyi yenilemez. Her değişiklik WebDAV hizmetini yeniler ve sürmekte olan aktarımları keser.</p>
      <RouterLink :to="accessRoute('adresler', 'paylasim')" class="section-link fit" data-testid="share-publication">WebDAV yayını ve HTTPS adı: Erişim → Adresler</RouterLink>
    </section>

    <p class="sr-only" role="status">{{ busy ? "Kaydediliyor…" : note }}</p>
    <p v-if="note && !busy" class="action-note" aria-hidden="true" data-testid="share-note">{{ note }}</p>
    <p v-if="loadError" class="form-error" role="alert" data-testid="share-load-error">Paylaşımlar okunamadı: {{ loadError }}</p>
    <p v-if="errorOf('')" class="form-error" role="alert">{{ errorOf("") }}</p>

    <section v-if="view && !items.length" class="card" aria-label="Paylaşım yok" data-testid="share-empty">
      <EmptyState title="Henüz paylaşım yok" text="Bir klasörü WebDAV ile paylaşmak için Paylaşım ekle'yi seçin; her klasörün kendi hesabı ve iki ayrı bağlantısı olur." icon="share">
        <button type="button" class="btn btn-primary" :disabled="busy" @click="openCreate"><Icon name="plus" :size="18" />Paylaşım ekle</button>
      </EmptyState>
    </section>
    <div v-else-if="view" class="share-list" :aria-busy="busy" data-testid="share-list">
      <ShareCard
        v-for="s in items"
        :key="s.id"
        :share="s"
        :view="view"
        :root="root"
        :busy="busy"
        :error="errorOf(s.id)"
        @toggle="(scope, on) => toggle(s, scope, on)"
        @permission="(scope, value) => setPermission(s, scope, value)"
        @days="(scope, days) => setDays(s, scope, days)"
        @edit="openEdit(s)"
        @remove="askRemove(s)"
      />
    </div>
    <p v-else-if="!loadError" class="meter-note">Paylaşımlar okunuyor…</p>

    <ShareSheet
      :open="sheetOpen"
      :share="editing"
      :path="newPath ?? ''"
      :view="view"
      :root="root"
      :sending="sending"
      :error="errorOf('sheet')"
      @close="closeSheet"
      @pick="(path) => updateQuery(router, { yeni: path })"
      @submit="submitSheet"
      @edit="(id) => updateQuery(router, { yeni: null, paylasim: id })"
      @remove="removeFromSheet"
    />

    <Modal :open="ask !== null" :title="askTitle" :description="askDescription" @close="closeAsk">
      <ul v-if="ask?.kind === 'yazma'" class="modal-list" data-testid="ask-write">
        <li><Icon name="pencil" :size="18" /><span>Yükleme, üzerine yazma, taşıma ve kalıcı silme izni verir.</span></li>
        <li><Icon name="trash" :size="18" /><span>WebDAV ile silinenler Çöp'e gitmez.</span></li>
        <li><Icon name="key" :size="18" /><span>Yalnız bu bağlantı değişir; öbür bağlantının izni aynı kalır.</span></li>
      </ul>
      <ul v-else-if="ask?.kind === 'http'" class="modal-list" data-testid="ask-http">
        <li><Icon name="alert" :size="18" /><span>İnternet üzerinden HTTP, parola ve dosyaları şifrelemeden gönderir.</span></li>
        <li><Icon name="lock" :size="18" /><span>Erişim → Adresler'de bir HTTPS adı tanımlarsanız bağlantı şifreli olur.</span></li>
      </ul>
      <template v-else-if="ask?.kind === 'kaldir'">
        <ul class="modal-list" data-testid="ask-remove">
          <li><Icon name="key" :size="18" /><span>Bu klasörün iki bağlantısı ve ortak hesabı iptal edilir.</span></li>
          <li><Icon name="folder" :size="18" /><span>Klasör ve içindeki dosyalar silinmez.</span></li>
          <li><Icon name="refresh" :size="18" /><span>WebDAV hizmeti yenilenir; diğer paylaşımların sürmekte olan aktarımları da kesilir, yeniden bağlanabilirler.</span></li>
        </ul>
        <ConfirmWord v-model:confirmed="removeConfirmed" />
      </template>
      <p v-if="ask && errorOf(ask.kind === 'kaldir' ? 'kaldir' : ask.share.id)" class="form-error" role="alert" data-testid="ask-error">
        {{ errorOf(ask.kind === "kaldir" ? "kaldir" : ask.share.id) }}
      </p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :data-autofocus="ask?.kind !== 'kaldir' || undefined" :disabled="busy" @click="closeAsk">Vazgeç</button>
        <button
          type="button"
          class="btn"
          :class="ask?.kind === 'kaldir' ? 'btn-danger' : 'btn-primary'"
          :disabled="busy || (ask?.kind === 'kaldir' && !removeConfirmed)"
          data-testid="ask-go"
          @click="confirmAsk"
        >
          {{ busy ? "Kaydediliyor…" : ask?.kind === "yazma" ? "Yazma izni ver" : ask?.kind === "http" ? "Onayla ve aç" : "Paylaşımı kaldır" }}
        </button>
      </template>
    </Modal>
  </div>
</template>
