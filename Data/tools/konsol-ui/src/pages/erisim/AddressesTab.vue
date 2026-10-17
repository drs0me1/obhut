<!-- Erişim → Adresler: every access row (rebuild phase 4) from Erişim's read model: Konsol, Paylaşımlar and each
     application port, with its cells (Yalnız bu sunucu, Tailscale, İnternet). "Düzenle" opens the row's sheet
     (AccessRowSheet: the form, then the settings plan); "Adres aç" gives a raw TCP port a Tailscale name. The
     sheet is in the address (?satir=<row id>), so a warning's Düzelt, the firewall's fixed rows, an application's
     Portlar tab and a locked local name open it from anywhere. The local DNS names (GET /api/konsol/adlar):
     switches, the operator's records and the forwarding of other names, collected as a draft and saved through
     the plan review (they commit at once); an application's name is locked and links to its row. The local
     domain change: plan, apply, then a 300 s confirmation from the new address. -->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Switch from "../../components/ui/Switch.vue";
import SettingsPlanSheet from "./SettingsPlanSheet.vue";
import AccessRowSheet, { type RowMode, type RowOutcome } from "./AccessRowSheet.vue";
import { readNames } from "../../api/erisim";
import { DOMAIN_RE, portKey } from "../../access";
import { CELL_TEXT, CELL_TONE } from "../../apps";
import { accessRoute, filesRoute } from "../../sections";
import { live } from "../../live";
import { useLeaveGuard } from "../../leave";
import { useQueryParam } from "../../query";
import { tailnetKonsol, tailscaleAdmin } from "../../links";
import { UNKNOWN } from "../../format";
import type { Adlar, AyarIstegi, AyarSonucu, DnsKaydi, DnsTaslagi, ErisimHucresi, Hizmet } from "../../api/sema";

// ---- reads: the access rows come with Erişim's read model (live.erisim, read again after every change)
const names = ref<Adlar | null>(null);
const namesError = ref("");

async function loadNames(): Promise<void> {
  try {
    names.value = await readNames();
    namesError.value = "";
  } catch (err) {
    namesError.value = err instanceof Error ? err.message : String(err);
  }
}

onMounted(() => void loadNames());
watch(() => live.ayarSurumu, () => void loadNames());

const locked = computed(() => Boolean(live.bekleyen));
const e = computed(() => live.erisim);

// ---- the access rows
/** A row whose home is here: Konsol and Paylaşımlar (their `web`), each application port (its `satir`). */
const accessRows = computed<Hizmet[]>(() =>
  (e.value?.hizmetler ?? []).filter((h) => h.tur === "konsol" || h.tur === "paylasim" || (h.tur === "uygulama" && h.satir !== null && Boolean(h.uygulama) && Boolean(h.anahtar))),
);
const editable = (h: Hizmet) => (h.tur === "uygulama" ? Boolean(h.satir && h.anahtar && portKey(h.anahtar)) : Boolean(h.web));
const canOpenAddress = (h: Hizmet) => h.tur === "uygulama" && h.satir?.tur === "ham" && portKey(h.anahtar ?? "")?.protokol === "tcp";
function kindOf(h: Hizmet): string {
  if (h.tur === "konsol") return "Konsol · Adres";
  if (h.tur === "paylasim") return "WebDAV · Adres";
  return h.aciklama;
}
const COLUMNS = [
  { key: "yerel", title: "Yalnız bu sunucu" },
  { key: "tailscale", title: "Tailscale" },
  { key: "internet", title: "İnternet" },
] as const;
const cellTone = (c: ErisimHucresi) => (c.uyari ? "warning" : CELL_TONE[c.durum] ?? "neutral");
const cellText = (c: ErisimHucresi) => CELL_TEXT[c.durum] ?? UNKNOWN;

// The open sheet: ?satir=<row id> (a deep link opens it too); "Adres aç" is its other mode.
const satir = useQueryParam<string>("satir", null, "");
const mode = ref<RowMode>("duzenle");
const sheetRow = computed(() => (satir.value ? accessRows.value.find((h) => h.id === satir.value && editable(h)) ?? null : null));
const missingRow = computed(() => Boolean(satir.value && e.value && !sheetRow.value));
watch(satir, (id) => {
  if (!id) mode.value = "duzenle";
});

function edit(h: Hizmet, m: RowMode = "duzenle"): void {
  note.value = "";
  mode.value = m;
  satir.value = h.id;
}

function closeRow(): void {
  satir.value = "";
}

const OUTCOME: Record<RowOutcome, [string, string]> = {
  kaydedildi: ["Değişiklik kaydedildi.", "Değişiklik uygulandı; 60 saniye içinde yukarıdaki banttan onaylayın."],
  kaldirildi: ["Adres kaldırıldı.", "Adres kaldırıldı; 60 saniye içinde yukarıdaki banttan onaylayın."],
  acildi: ["Adres açıldı.", "Adres açıldı; 60 saniye içinde yukarıdaki banttan onaylayın."],
};
function rowApplied(result: AyarSonucu, outcome: RowOutcome): void {
  note.value = OUTCOME[outcome][result.pending ? 1 : 0];
  satir.value = "";
}

// ---- the plan sheet (DNS draft, the local domain)
interface Sheet {
  kind: "dns" | "alan";
  title: string;
  description: string;
  request: AyarIstegi;
  applyLabel: string;
  danger: boolean;
}
const sheet = ref<Sheet | null>(null);
const note = ref("");

function applied(): void {
  const kind = sheet.value?.kind;
  sheet.value = null;
  if (kind === "dns") {
    draft.value = null;
    note.value = "Yerel adlar kaydedildi.";
  } else if (kind === "alan") {
    domainInput.value = "";
    domainTried.value = false;
    note.value = "Alan adı değişikliği uygulandı; yeni adresten 5 dakika içinde onaylayın.";
  }
}

// ---- local DNS names
const SOURCE: Record<string, string> = { base: "Temel", uygulama: "Uygulama" };
const sourceText = (source: string): string => SOURCE[source] ?? source;
const tailscaleV4 = computed(() => live.erisim?.ozet.tailscale.ipv4 || live.kaynaklar?.net?.tailscale || "");
const wanV4 = computed(() => live.erisim?.ozet.internet.ipv4 || live.kaynaklar?.net?.wan || "");

const nameRows = computed(() => {
  const out: { ad: string; aileler: number[]; hedef: string; kaynak: string; kilitli: boolean; satir: string | null }[] = [];
  for (const a of names.value?.adlar ?? []) {
    let row = out.find((r) => r.ad === a.ad);
    if (!row) {
      row = { ad: a.ad, aileler: [], hedef: "", kaynak: sourceText(a.kaynak), kilitli: a.kilitli, satir: a.satir };
      out.push(row);
    }
    if (a.aile) row.aileler.push(a.aile);
    const target = a.hedef === "tailscale" ? `Tailscale adresi${tailscaleV4.value ? " · " + tailscaleV4.value : ""}` : a.hedef;
    if (target && !row.hedef.includes(target)) row.hedef = row.hedef ? `${row.hedef} · ${target}` : target;
    row.kilitli ||= a.kilitli;
    row.satir ??= a.satir;
  }
  return out;
});
/** A locked name's own row in Adresler (an application's), or "" for Konsol's (it is never switched off). */
const nameRow = (r: { satir: string | null }) => (r.satir && r.satir !== "panel" ? r.satir : "");

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const savedDns = computed<DnsTaslagi | null>(() => {
  const n = names.value;
  if (!n) return null;
  return {
    disabled: [...new Set(n.adlar.filter((a) => a.kapali).map((a) => a.ad))],
    records: n.kayitlar.map((r) => ({ name: r.name, target: r.target, enabled: r.enabled })),
    forward: n.yonlendirme,
    servers: [...n.sunucular],
  };
});
const draft = ref<DnsTaslagi | null>(null);
const dns = computed<DnsTaslagi | null>(() => draft.value ?? savedDns.value);
// The saved names changed under a draft (another tab, another change): the draft no longer fits them.
watch(savedDns, (now, before) => {
  if (draft.value && now && before && JSON.stringify(now) !== JSON.stringify(before)) draft.value = null;
});
const sameDns = (a: DnsTaslagi, b: DnsTaslagi) =>
  JSON.stringify([[...a.disabled].sort(), a.records, a.forward, a.servers]) === JSON.stringify([[...b.disabled].sort(), b.records, b.forward, b.servers]);
const dirty = computed(() => Boolean(draft.value && savedDns.value && !sameDns(draft.value, savedDns.value)));
const changes = computed(() => {
  const d = draft.value, s = savedDns.value;
  if (!d || !s) return 0;
  let n = 0;
  const off = new Set(d.disabled), was = new Set(s.disabled);
  for (const x of new Set([...off, ...was])) if (off.has(x) !== was.has(x)) n += 1;
  for (const r of d.records) {
    const old = s.records.find((x) => x.name === r.name);
    if (!old || JSON.stringify(old) !== JSON.stringify(r)) n += 1;
  }
  n += s.records.filter((r) => !d.records.some((x) => x.name === r.name)).length;
  if (d.forward !== s.forward || JSON.stringify(d.servers) !== JSON.stringify(s.servers)) n += 1;
  return n;
});

function editDraft(change: (d: DnsTaslagi) => void): void {
  const base = draft.value ?? (savedDns.value ? clone(savedDns.value) : null);
  if (!base) return;
  change(base);
  draft.value = savedDns.value && sameDns(base, savedDns.value) ? null : base;
}

const isOff = (name: string) => dns.value?.disabled.includes(name) ?? false;
function setName(name: string, on: boolean): void {
  editDraft((d) => {
    d.disabled = on ? d.disabled.filter((n) => n !== name) : [...d.disabled.filter((n) => n !== name), name];
  });
}

function setRecord(name: string, on: boolean): void {
  editDraft((d) => {
    const r = d.records.find((x) => x.name === name);
    if (r) r.enabled = on;
  });
}

function dropRecord(name: string): void {
  editDraft((d) => {
    d.records = d.records.filter((x) => x.name !== name);
  });
}

function discardDraft(): void {
  draft.value = null;
}

function reviewDns(): void {
  if (!names.value || !draft.value) return;
  note.value = "";
  sheet.value = {
    kind: "dns",
    title: "Yerel ad değişiklikleri",
    description: "Uygulayınca hemen kaydedilir; dnsmasq yeniden başlar.",
    request: { revision: names.value.revizyon, dns: clone(draft.value) },
    applyLabel: "Uygula",
    danger: false,
  };
}

// The operator's record: a name under the local domain, the Tailscale address or a fixed IP.
const recordOpen = ref(false);
const recordEditing = ref<string | null>(null);
const recordLabel = ref("");
const recordTarget = ref<"tailscale" | "ip">("tailscale");
const recordIp = ref("");
const recordTried = ref(false);
const domain = computed(() => names.value?.alan || e.value?.alan || live.kaynaklar?.domain || "");
const LABEL_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;
const recordName = computed(() => {
  const text = recordLabel.value.trim().toLowerCase().replace(/\.$/, "");
  const suffix = "." + domain.value;
  return (text.endsWith(suffix) ? text.slice(0, -suffix.length) : text) + suffix;
});
const recordNameError = computed(() => {
  const label = recordName.value.slice(0, -(domain.value.length + 1));
  if (!label) return "Adı yazın (ör. yazici).";
  if (!LABEL_RE.test(label)) return "Küçük harf, rakam ve tire; noktayla ayrılmış parçalar.";
  const taken = nameRows.value.some((r) => r.ad === recordName.value) ||
    (dns.value?.records ?? []).some((r) => r.name === recordName.value && r.name !== recordEditing.value);
  return taken ? "Bu ad zaten kullanılıyor." : "";
});
const recordIpError = computed(() => {
  if (recordTarget.value !== "ip") return "";
  const ip = recordIp.value.trim();
  if (!ip) return "IPv4 ya da IPv6 adresini yazın.";
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) || /^[0-9a-f]*:[0-9a-f:.]*$/i.test(ip) ? "" : "Geçerli bir IPv4 ya da IPv6 adresi yazın.";
});

function openRecord(r: DnsKaydi | null): void {
  recordEditing.value = r?.name ?? null;
  recordLabel.value = r ? r.name.slice(0, -(domain.value.length + 1)) : "";
  recordTarget.value = r && r.target !== "tailscale" ? "ip" : "tailscale";
  recordIp.value = r && r.target !== "tailscale" ? r.target : "";
  recordTried.value = false;
  recordOpen.value = true;
}

function saveRecord(): void {
  recordTried.value = true;
  if (recordNameError.value || recordIpError.value) return;
  const value: DnsKaydi = { name: recordName.value, target: recordTarget.value === "tailscale" ? "tailscale" : recordIp.value.trim(), enabled: true };
  const editing = recordEditing.value;
  editDraft((d) => {
    const old = editing ? d.records.find((x) => x.name === editing) : undefined;
    if (old) {
      value.enabled = old.enabled;
      d.records = d.records.map((x) => (x.name === editing ? value : x));
    } else d.records.push(value);
  });
  recordOpen.value = false;
}

// Forwarding of other names: a provider's servers or the operator's own (at most four).
const PROVIDERS = [
  { id: "cloudflare", name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"] },
  { id: "google", name: "Google", servers: ["8.8.8.8", "8.8.4.4"] },
  { id: "quad9", name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"] },
] as const;
const provider = computed(() => {
  const servers = JSON.stringify(dns.value?.servers ?? []);
  return PROVIDERS.find((p) => JSON.stringify(p.servers) === servers)?.id ?? "ozel";
});
const customServers = ref("");
watch(
  () => dns.value?.servers,
  (servers) => {
    if (provider.value === "ozel") customServers.value = (servers ?? []).join(", ");
  },
  { immediate: true },
);
function setForward(on: boolean): void {
  editDraft((d) => {
    d.forward = on;
    if (on && !d.servers.length) d.servers = [...PROVIDERS[0].servers];
  });
}
function chooseProvider(id: string): void {
  const p = PROVIDERS.find((x) => x.id === id);
  editDraft((d) => {
    d.servers = p ? [...p.servers] : [];
  });
  if (!p) customServers.value = "";
}
function setCustomServers(): void {
  const list = customServers.value.split(",").map((x) => x.trim()).filter(Boolean).slice(0, 4);
  editDraft((d) => {
    d.servers = list;
  });
}
const serversError = computed(() => {
  const d = dns.value;
  if (!d?.forward) return "";
  if (!d.servers.length) return "Yönlendirme için en az bir DNS sunucusu seçin.";
  if (customServers.value.split(",").filter((x) => x.trim()).length > 4) return "En çok dört sunucu yazılabilir.";
  return "";
});

// ---- the local domain
const domainInput = ref("");
const domainTried = ref(false);
const newDomain = computed(() => domainInput.value.trim().toLowerCase());
const domainError = computed(() => {
  if (!newDomain.value) return "Yeni alan adını yazın (ör. ev).";
  if (!DOMAIN_RE.test(newDomain.value)) return "Küçük harf, rakam ve tire; en çok 63 karakter, tireyle başlamaz ya da bitmez.";
  if (newDomain.value === domain.value) return "Alan adı zaten bu değerde.";
  return "";
});
function reviewDomain(): void {
  domainTried.value = true;
  if (domainError.value || !names.value) return;
  note.value = "";
  sheet.value = {
    kind: "alan",
    title: "Yerel alan adı değişsin mi?",
    description: `${domain.value} → ${newDomain.value}`,
    request: { revision: names.value.revizyon, domain: newDomain.value },
    applyLabel: "Alan adını değiştir",
    danger: false,
  };
}
// Closing or reloading the browser tab with a DNS draft or a typed new domain asks first (DD-266).
useLeaveGuard(() => dirty.value || newDomain.value !== "");
const pendingDomain = computed(() => live.bekleyen?.domain ?? null);
const dnsAdmin = tailscaleAdmin("dns");
const pendingDomainNew = computed(() => (pendingDomain.value ? tailnetKonsol(pendingDomain.value.new, "#/erisim?sekme=adresler") : ""));
const sheetDomain = computed(() => (sheet.value?.kind === "alan" ? newDomain.value : ""));
const panelAddress = (d: string) => tailnetKonsol(d);
</script>

<template>
  <div class="access-tab addresses" data-testid="addresses">
    <p class="sr-only" role="status">{{ note }}</p>
    <p v-if="note" class="action-note" aria-hidden="true" data-testid="addresses-note">{{ note }}</p>
    <p v-if="locked" class="notice" role="note" data-testid="addresses-locked">
      <Icon name="clock" class="notice-icon" />
      <span>Bekleyen bir ayar değişikliği var; onaylanana ya da geri alınana kadar yeni değişiklik uygulanamaz.</span>
    </p>

    <!-- the access rows -->
    <section class="card table-card" aria-labelledby="adres-baslik" data-testid="access-rows">
      <div class="card-head">
        <h2 id="adres-baslik" class="card-title">Adresler ve ham portlar</h2>
      </div>
      <p class="meter-note">Bir konteyner portuna dışarıdan yalnız buradan ulaşılır: bir adres (Tailscale adı, isteğe bağlı Tailscale portu ve internet adı) ya da bir ham port (kapalı, Tailscale ya da internet).</p>
      <p v-if="missingRow" class="notice notice-warning" role="note" data-testid="row-missing">
        <Icon name="alert" class="notice-icon" /><span>Bu erişim satırı bulunamadı ya da düzenlenemiyor: <span class="mono">{{ satir }}</span></span>
      </p>
      <ul v-if="e?.hatalar.length" class="notice-list">
        <li v-for="(x, i) in e.hatalar" :key="i" class="warn-text">{{ x }}</li>
      </ul>
      <div v-if="accessRows.length" class="table-wrap">
        <table class="data-table address-table">
          <thead>
            <tr>
              <th scope="col">Adres</th>
              <th v-for="c in COLUMNS" :key="c.key" scope="col">{{ c.title }}</th>
              <th scope="col"><span class="sr-only">Eylemler</span></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="h in accessRows" :key="h.id" :data-satir="h.id">
              <th scope="row" class="col-main">
                <strong>{{ h.ad }}</strong>
                <span class="cell-sub">{{ kindOf(h) }}</span>
                <RouterLink v-if="h.tur === 'paylasim'" :to="filesRoute('paylasimlar')" class="cell-note" data-testid="share-folders">Klasör izinleri ve süreler: Dosyalar → Paylaşımlar</RouterLink>
              </th>
              <td v-for="c in COLUMNS" :key="c.key" :data-label="c.title" :data-hucre="c.key">
                <span class="cell-stack">
                  <StatusPill :tone="cellTone(h[c.key])">{{ cellText(h[c.key]) }}</StatusPill>
                  <span v-for="a in h[c.key].adresler" :key="a" class="mono cell-addr">{{ a }}</span>
                  <span v-if="h[c.key].uyari" class="cell-note warn-text">{{ h[c.key].uyari }}</span>
                  <span v-if="h[c.key].not" class="cell-note">{{ h[c.key].not }}</span>
                </span>
              </td>
              <td class="col-act">
                <span class="row-actions">
                  <button
                    type="button"
                    class="btn btn-secondary btn-sm"
                    :disabled="locked || !editable(h)"
                    :aria-label="`${h.ad}: düzenle`"
                    data-eylem="duzenle"
                    @click="edit(h)"
                  >
                    Düzenle
                  </button>
                  <button
                    v-if="canOpenAddress(h)"
                    type="button"
                    class="btn btn-secondary btn-sm"
                    :disabled="locked"
                    :aria-label="`${h.ad}: adres aç`"
                    data-eylem="adres-ac"
                    @click="edit(h, 'adres-ac')"
                  >
                    Adres aç
                  </button>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else-if="e" title="Erişim satırı yok" icon="globe" />
      <p v-else class="meter-note">Okunuyor…</p>
      <p class="meter-note" data-testid="dns-hint">
        İnternet adları için alan adı sağlayıcınızda bir A kaydı gerekir: ad → <span class="mono">{{ wanV4 || "sunucunun internet IPv4 adresi" }}</span>, proxy kapalı (DNS only), AAAA kaydı yok.
      </p>
    </section>

    <!-- local DNS names -->
    <section class="card table-card" aria-labelledby="adlar-baslik" data-testid="names">
      <div class="card-head">
        <h2 id="adlar-baslik" class="card-title">Yerel adlar</h2>
        <button type="button" class="btn btn-secondary btn-sm" :disabled="locked || !names" data-testid="add-record" @click="openRecord(null)">
          <Icon name="plus" :size="16" />Kayıt ekle
        </button>
      </div>
      <p class="meter-note">.{{ domain || UNKNOWN }} altındaki adları sunucunun DNS'i yanıtlar. Bir adı kapatmak hizmeti durdurmaz; Konsol'un kendi adı kapatılamaz, bir uygulamanın adı kendi satırında değişir.</p>
      <p v-if="namesError" class="form-error" role="alert">{{ namesError }}</p>
      <ul v-if="names?.hatalar.length" class="notice-list">
        <li v-for="(x, i) in names.hatalar" :key="i" class="warn-text">{{ x }}</li>
      </ul>
      <div v-if="names" class="table-wrap">
        <table class="data-table names-table">
          <thead>
            <tr>
              <th scope="col">Ad</th>
              <th scope="col">Yanıt</th>
              <th scope="col">Sahibi</th>
              <th scope="col">Açık</th>
              <th scope="col"><span class="sr-only">Eylemler</span></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in nameRows" :key="r.ad" :data-ad="r.ad">
              <th scope="row" class="col-main"><strong class="mono">{{ r.ad }}</strong></th>
              <td data-label="Yanıt">{{ r.hedef || UNKNOWN }}</td>
              <td data-label="Sahibi">{{ r.kaynak }}</td>
              <td data-label="Açık">
                <Switch
                  :model-value="!isOff(r.ad)"
                  :label="`${r.ad} açık`"
                  hide-label
                  :disabled="locked || r.kilitli"
                  @update:model-value="setName(r.ad, $event)"
                />
                <RouterLink v-if="r.kilitli && nameRow(r)" :to="accessRoute('adresler', nameRow(r))" class="cell-note" data-testid="name-row">Uygulamanın adı · Adresler'de değişir</RouterLink>
                <span v-else-if="r.kilitli" class="cell-note">Konsol'un adı · kapatılamaz</span>
              </td>
              <td class="col-act"></td>
            </tr>
            <tr v-for="r in dns?.records ?? []" :key="'k:' + r.name" :data-kayit="r.name">
              <th scope="row" class="col-main"><strong class="mono">{{ r.name }}</strong></th>
              <td data-label="Yanıt">{{ r.target === "tailscale" ? `Tailscale adresi${tailscaleV4 ? " · " + tailscaleV4 : ""}` : r.target }}</td>
              <td data-label="Sahibi">Sizin kaydınız</td>
              <td data-label="Açık">
                <Switch :model-value="r.enabled" :label="`${r.name} açık`" hide-label :disabled="locked" @update:model-value="setRecord(r.name, $event)" />
              </td>
              <td class="col-act">
                <span class="row-actions">
                  <button type="button" class="btn btn-secondary btn-sm" :disabled="locked" :aria-label="`${r.name} kaydını düzenle`" @click="openRecord(r)">Düzenle</button>
                  <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="locked" :aria-label="`${r.name} kaydını sil`" @click="dropRecord(r.name)">Sil</button>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div v-if="dns" class="forward" data-testid="forward">
        <Switch :model-value="dns.forward" label="Diğer adları üst DNS'e gönder" :disabled="locked" @update:model-value="setForward" />
        <p class="meter-note">.{{ domain }} dışındaki adlar seçtiğiniz sunuculara sorulur. .{{ domain }} içindeki adlar dışarı gönderilmez; bağlantı şifrelenmez (DoH/DoT yok).</p>
        <template v-if="dns.forward">
          <Field label="Sunucular" group>
            <div class="choice-chips" role="presentation">
              <label v-for="p in PROVIDERS" :key="p.id" class="choice-chip">
                <input type="radio" name="dns-saglayici" :value="p.id" :checked="provider === p.id" :disabled="locked" @change="chooseProvider(p.id)" />
                <span>{{ p.name }}</span>
              </label>
              <label class="choice-chip">
                <input type="radio" name="dns-saglayici" value="ozel" :checked="provider === 'ozel'" :disabled="locked" @change="chooseProvider('ozel')" />
                <span>Özel</span>
              </label>
            </div>
          </Field>
          <Field
            v-if="provider === 'ozel'"
            v-slot="{ id, describedby, invalid }"
            label="DNS sunucuları"
            hint="En çok dört genel DNS adresi; virgülle ayırın."
            :error="serversError"
          >
            <input :id="id" v-model="customServers" class="input" type="text" placeholder="1.1.1.1, 1.0.0.1" autocomplete="off" spellcheck="false"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" :disabled="locked" @change="setCustomServers" />
          </Field>
          <p v-else class="meter-note mono">{{ dns.servers.join(", ") }}</p>
        </template>
      </div>
    </section>

    <!-- the draft bar -->
    <div v-if="dirty" class="draft-bar" role="region" aria-label="Taslak" data-testid="dns-draft">
      <div>
        <strong>{{ changes }} değişiklik taslakta</strong>
        <span class="meter-note">İnceleyip uygulayana kadar sunucu değişmez; uygulayınca hemen kaydedilir.</span>
      </div>
      <div class="draft-actions">
        <button type="button" class="btn btn-secondary" @click="discardDraft">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="locked || Boolean(serversError)" data-testid="review-dns" @click="reviewDns">İncele</button>
      </div>
    </div>

    <!-- the local domain -->
    <Card title="Yerel alan adı" data-testid="domain">
      <p class="card-text">Geçerli adres: <span class="mono">panel.{{ domain || UNKNOWN }}</span>. Panel, paylaşım, uygulama ve özel DNS adlarının son eki birlikte değişir; HTTPS alan adları değişmez.</p>
      <div v-if="pendingDomain" class="notice" role="note" data-testid="domain-pending">
        <Icon name="clock" class="notice-icon" />
        <span>
          {{ pendingDomain.old }} → {{ pendingDomain.new }} bekliyor. Yeni Konsol'u açıp onaylayın:
          <a :href="pendingDomainNew" target="_blank" rel="noopener">panel.{{ pendingDomain.new }}</a>. Açılmazsa 5 dakika içinde eski ad geri gelir.
        </span>
      </div>
      <form class="domain-form" novalidate @submit.prevent="reviewDomain">
        <Field
          v-slot="{ id, describedby, invalid }"
          label="Yeni yerel alan adı"
          hint="Örn. ev · küçük harf, rakam ve tire."
          :error="domainTried ? domainError : ''"
        >
          <input :id="id" v-model="domainInput" class="input" type="text" maxlength="63" autocapitalize="none" autocomplete="off" spellcheck="false"
            :placeholder="domain" :aria-describedby="describedby" :aria-invalid="invalid || undefined" :disabled="locked || dirty" data-testid="domain-input" />
        </Field>
        <button type="submit" class="btn btn-primary fit" :disabled="locked || dirty || !names" data-testid="review-domain">İncele</button>
      </form>
      <p v-if="dirty" class="meter-note warn-text">Alan adını değiştirmeden önce yerel ad taslağını uygulayın ya da vazgeçin.</p>
      <details class="guide">
        <summary>Tailscale yönetim paneli · DNS tanımı</summary>
        <ol class="guide-steps">
          <li><a :href="dnsAdmin" target="_blank" rel="noopener noreferrer">Tailscale Admin → DNS</a> sayfasında Nameservers → Add nameserver → Custom seçin.</li>
          <li>Nameserver IP: <span class="mono">{{ tailscaleV4 || "Tailscale IP okunamadı" }}</span></li>
          <li>Restrict to search domain (Split DNS) seçeneğini açın. Alan adı: <span class="mono">{{ domain }}</span></li>
          <li>Save ile kaydedin. Bağlanan cihazda Tailscale DNS ayarlarını kullanma seçeneği açık olsun.</li>
        </ol>
      </details>
    </Card>

    <SettingsPlanSheet
      :open="sheet !== null"
      :title="sheet?.title ?? ''"
      :description="sheet?.description"
      :request="sheet?.request ?? null"
      :apply-label="sheet?.applyLabel"
      :danger="sheet?.danger"
      @close="sheet = null"
      @applied="applied"
    >
      <template v-if="sheet?.kind === 'alan'">
        <ul class="modal-list">
          <li><Icon name="tailnet" :size="18" /><span>Önce Tailscale Admin → DNS'te {{ tailscaleV4 || "sunucunun Tailscale" }} sunucusuna “Restrict to domain” ile {{ sheetDomain }} alanını ekleyin. Onay bitene kadar eski {{ domain }} eşleştirmesini de koruyun.</span></li>
          <li><Icon name="clock" :size="18" /><span>Uygulamadan sonra yeni adresi açıp 5 dakika içinde onaylayın; aksi hâlde sunucu eski ada döner.</span></li>
          <li><Icon name="folder" :size="18" /><span>Dosya yöneticisi açıksa kısa süre yeniden başlar; devam eden dosya aktarımlarını önce bitirin.</span></li>
        </ul>
        <p class="mono plan-address">{{ panelAddress(sheetDomain) }}</p>
      </template>
    </SettingsPlanSheet>

    <AccessRowSheet
      :row="sheetRow"
      :mode="mode"
      :rows="accessRows"
      :names="names"
      :revision="e?.revizyon ?? ''"
      :domain="domain"
      :wan="wanV4"
      :tailscale-ip="tailscaleV4"
      :locked="locked"
      @close="closeRow"
      @mode="mode = $event"
      @applied="rowApplied"
    />

    <Modal :open="recordOpen" variant="sheet" :title="recordEditing ? 'Kaydı düzenle' : 'Yerel ad ekle'" :description="`.${domain} altında bir ad; sunucunun DNS'i yanıtlar.`" @close="recordOpen = false">
      <form id="kayit-formu" class="form-stack" novalidate @submit.prevent="saveRecord">
        <Field v-slot="{ id, describedby, invalid }" label="Ad" :suffix="'.' + domain" :error="recordTried ? recordNameError : ''">
          <input :id="id" v-model="recordLabel" class="input" type="text" maxlength="200" autocapitalize="none" autocomplete="off" spellcheck="false"
            placeholder="yazici" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
        </Field>
        <Field label="Yanıt" group>
          <label class="check-row"><input v-model="recordTarget" type="radio" name="kayit-hedef" value="tailscale" /><span>Sunucunun Tailscale adresi (değişse de izler)</span></label>
          <label class="check-row"><input v-model="recordTarget" type="radio" name="kayit-hedef" value="ip" /><span>Sabit bir IP adresi</span></label>
        </Field>
        <Field v-if="recordTarget === 'ip'" v-slot="{ id, describedby, invalid }" label="IP adresi" :error="recordTried ? recordIpError : ''">
          <input :id="id" v-model="recordIp" class="input" type="text" autocomplete="off" spellcheck="false" placeholder="100.64.0.7"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <p class="meter-note">Yeni bir ad Caddy'de site açmaz; yalnız DNS yanıtı verir. Taslağa eklenir; İncele ile uygulanır.</p>
      </form>
      <template #actions>
        <button type="button" class="btn btn-secondary" @click="recordOpen = false">Vazgeç</button>
        <button type="submit" form="kayit-formu" class="btn btn-primary">{{ recordEditing ? "Taslağa yaz" : "Taslağa ekle" }}</button>
      </template>
    </Modal>
  </div>
</template>
