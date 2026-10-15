<!-- Erişim → WireGuard (DD-258's approved layout; every function of magaza/wireguard/sayfa.js): the networks
     as tabs (?ag=wg0) with "Ağ ekle"; a network card with its on/off switch (turning it off asks first), its
     summary and its devices (on/off, state, DNS and keepalive, addresses, last seen, traffic, QR, profile,
     edit, delete); one side panel for adding a device, a device's DNS and keepalive, the network's name and
     default DNS, regenerating its key, removing it and adding a network (typed "onayla" where it cannot be
     undone). GET /state is read every 10 s while this tab is shown and the browser tab visible. QR codes and
     profiles carry a private key: fetched only on a click, never cached, their object URL revoked after use. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink, useRouter } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Switch from "../../components/ui/Switch.vue";
import Tabs from "../../components/ui/Tabs.vue";
import type { Tone } from "../../components/ui/types";
import DnsChoice from "./DnsChoice.vue";
import {
  DEVICE_STATE, DNS_PRESETS, NAME_RE, deviceState, keepaliveProblem, keepaliveText, labelOf, labelProblem, nextNetwork, onlineCount, portProblem,
  providerOf, suggestPort, type DeviceState,
} from "./wg";
import {
  addDevice, addNetwork, fetchProfile, fetchQr, readWgState, regenerateNetwork, removeDevice, removeNetwork, saveNetworkSettings, setDevice,
  setDeviceDns, setDeviceKeepalive, setNetwork, type WgNetwork, type WgPeer, type WgState,
} from "../../api/wireguard";
import { ApiError } from "../../api/http";
import { live, refreshApps } from "../../live";
import { updateQuery, useQueryParam } from "../../query";
import { appRoute } from "../../router";
import { UNKNOWN, bytes, since } from "../../format";

const POLL_MS = 10000;
const router = useRouter();

// ---- the package and its state
const pkg = computed(() => live.uygulamalar?.items.find((a) => a.id === "paket:wireguard") ?? null);
/** null while the application list is not read yet. */
const installed = computed(() => (live.uygulamalar ? Boolean(pkg.value) : null));
const stopped = computed(() => pkg.value?.durum === "durduruldu");
const writable = computed(() => !stopped.value && !working.value);

const state = ref<WgState | null>(null);
const loadError = ref("");
const missing = ref(false);
const now = ref(Date.now() / 1000);
let offset = 0;
let loading = false;
let timer: number | undefined;

async function load(): Promise<void> {
  if (loading) return;
  loading = true;
  try {
    const value = await readWgState();
    offset = value.now - Date.now() / 1000;
    now.value = value.now;
    state.value = value;
    loadError.value = "";
    missing.value = false;
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) missing.value = true;
    else loadError.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading = false;
  }
}

function tick(): void {
  now.value = Date.now() / 1000 + offset;
  if (!document.hidden && installed.value !== false) void load();
}
function onVisibility(): void {
  if (!document.hidden && installed.value !== false) void load();
}
// The package's API is asked only once the application list says it is installed (or, should that list
// stay unread, at the next tick).
onMounted(() => {
  void refreshApps();
  if (installed.value) void load();
  timer = window.setInterval(tick, POLL_MS);
  document.addEventListener("visibilitychange", onVisibility);
});
onBeforeUnmount(() => {
  clearInterval(timer);
  document.removeEventListener("visibilitychange", onVisibility);
  forgetQr();
});
watch(installed, (on, before) => {
  if (on && !before) void load();
});

// ---- networks
const networks = computed(() => state.value?.networks ?? []);
const netOf = (iface: string) => networks.value.find((n) => n.iface === iface) ?? null;
const ids = computed(() => networks.value.map((n) => n.iface));
const selected = useQueryParam<string>("ag", () => ids.value, () => ids.value[0] ?? "");
const current = computed(() => netOf(selected.value));
const tabs = computed(() =>
  networks.value.map((n) => ({
    id: n.iface,
    label: `${n.iface} · ${labelOf(n)}`,
    hint: n.active ? `${onlineCount(n, now.value)}/${n.peers.length} bağlı · UDP ${n.port}` : `Kapalı · UDP ${n.port}`,
  })),
);
const next = computed(() => (state.value ? nextNetwork(state.value) : null));

const stateTone: Record<DeviceState, Tone> = { ok: "ok", idle: "accent", never: "neutral", off: "neutral", netoff: "neutral" };
const devices = (n: WgNetwork) =>
  n.peers.map((p) => {
    const st = deviceState(n, p, now.value);
    return { p, st, label: DEVICE_STATE[st], tone: stateTone[st], cut: st === "off" || st === "netoff" };
  });
function summary(n: WgNetwork) {
  const total = n.peers.length;
  const off = n.peers.filter((p) => !p.enabled).length;
  return {
    connected: n.active ? `${onlineCount(n, now.value)} / ${total} cihaz${off ? ` · ${off} kapalı` : ""}` : `Kapalı · ${total} cihaz bekliyor`,
    port: `${n.port} · ${n.active ? "UDP açık" : "UDP dinlenmiyor"}`,
    address: n.server4 ? `${n.server4}/24` : n.subnet4,
  };
}
const seen = (p: WgPeer) => (p.handshake ? since(p.handshake, now.value) : "hiç");

// ---- actions with a result line
const working = ref(false);
const note = ref("");
const error = ref("");
const qrOffer = ref<{ iface: string; name: string } | null>(null);

async function act(run: () => Promise<unknown>, done: () => string): Promise<boolean> {
  if (working.value) return false;
  working.value = true;
  error.value = "";
  note.value = "";
  qrOffer.value = null;
  try {
    await run();
    await load();
    note.value = done();
    return true;
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
    void load();
    return false;
  } finally {
    working.value = false;
  }
}

// Turning a network on is safe; turning it off cuts every device and asks first.
const askOff = ref<WgNetwork | null>(null);
function toggleNetwork(n: WgNetwork, on: boolean): void {
  if (!on) {
    askOff.value = n;
    return;
  }
  void act(() => setNetwork(n.iface, true), () => `${n.iface} açıldı: UDP ${n.port} dinleniyor, cihazlar birkaç saniye içinde bağlanır.`);
}
const offOnline = computed(() => (askOff.value ? onlineCount(askOff.value, now.value) : 0));
async function confirmOff(): Promise<void> {
  const n = askOff.value;
  if (!n) return;
  if (await act(() => setNetwork(n.iface, false), () => `${n.iface} kapatıldı: ${n.peers.length} cihazın bağlantısı kesildi.`)) askOff.value = null;
}

function toggleDevice(n: WgNetwork, p: WgPeer, on: boolean): void {
  void act(() => setDevice(n.iface, p.name, on), () =>
    on ? `${p.name} açıldı: cihaz birkaç saniye içinde kendiliğinden bağlanır.` : `${p.name} kapatıldı: bağlantısı kesildi, profili ve adresi duruyor.`);
}

const askDelete = ref<{ n: WgNetwork; p: WgPeer } | null>(null);
async function confirmDelete(): Promise<void> {
  const target = askDelete.value;
  if (!target) return;
  if (await act(() => removeDevice(target.n.iface, target.p.name), () => `“${target.p.name}” silindi.`)) askDelete.value = null;
}

// ---- the QR code and the profile (secrets: fetched on a click, no cache, object URLs revoked)
const qr = ref<{ iface: string; name: string; ipv4: string; dns: string; fresh: boolean } | null>(null);
const qrUrl = ref("");
const qrError = ref("");
let qrRevoked = true;
let qrSeq = 0;

function forgetQr(): void {
  if (qrUrl.value && !qrRevoked) URL.revokeObjectURL(qrUrl.value);
  qrUrl.value = "";
  qrRevoked = true;
}

async function openQr(n: WgNetwork, p: WgPeer, fresh = false): Promise<void> {
  forgetQr();
  qrSeq += 1;
  const mine = qrSeq;
  qr.value = { iface: n.iface, name: p.name, ipv4: p.ipv4, dns: providerOf(p.dns, p.provider), fresh };
  qrError.value = "";
  try {
    const blob = await fetchQr(n.iface, p.name);
    if (mine !== qrSeq || !qr.value) return;
    qrUrl.value = URL.createObjectURL(blob);
    qrRevoked = false;
  } catch (err) {
    if (mine === qrSeq) qrError.value = err instanceof Error ? err.message : String(err);
  }
}

/** The image is decoded: the URL is not needed any more. */
function onQrLoad(): void {
  if (qrUrl.value && !qrRevoked) {
    URL.revokeObjectURL(qrUrl.value);
    qrRevoked = true;
  }
}

function closeQr(): void {
  qrSeq += 1;
  qr.value = null;
  forgetQr();
}

async function downloadProfile(iface: string, name: string): Promise<void> {
  error.value = "";
  try {
    const blob = await fetchProfile(iface, name);
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${name}.conf`;
    document.body.append(a);
    a.click();
    a.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 10000);
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
  }
}

function showOfferedQr(): void {
  const offer = qrOffer.value;
  const n = offer ? netOf(offer.iface) : null;
  const p = n?.peers.find((x) => x.name === offer?.name);
  if (n && p) void openQr(n, p);
}

// ---- the side panel
type Panel =
  | { kind: "cihaz-ekle"; iface: string }
  | { kind: "cihaz"; iface: string; name: string }
  | { kind: "ag-ayar"; iface: string }
  | { kind: "yeniden-uret"; iface: string }
  | { kind: "kaldir"; iface: string }
  | { kind: "ag-ekle" };
const panel = ref<Panel | null>(null);
const panelError = ref("");
const tried = ref(false);
const confirmed = ref(false);
const panelNet = computed(() => (panel.value && "iface" in panel.value ? netOf(panel.value.iface) : null));
const panelPeer = computed(() => (panel.value?.kind === "cihaz" ? panelNet.value?.peers.find((p) => p.name === (panel.value as { name: string }).name) ?? null : null));

// form values
const fName = ref("");
const fDns = ref("");
const fKa = ref("21");
const fLabel = ref("");
const fPort = ref("");
const fRevision = ref("");
const fIndex = ref<number | null>(null);
const KEEPALIVES = [["0", "Kapalı"], ["21", "21 sn · önerilen"], ["25", "25 sn"]] as const;

function open(p: Panel): void {
  panelError.value = "";
  tried.value = false;
  confirmed.value = false;
  error.value = "";
  const s = state.value;
  const n = "iface" in p ? netOf(p.iface) : null;
  if (p.kind === "cihaz-ekle" && n && s) {
    fName.value = "";
    fDns.value = n.dns || s.defaults.dns || DNS_PRESETS[0].ips;
    fKa.value = String(s.defaults.keepalive || 21);
  } else if (p.kind === "cihaz" && n) {
    const peer = n.peers.find((x) => x.name === p.name);
    if (!peer) return;
    fDns.value = peer.dns;
    fKa.value = String(peer.keepalive);
  } else if (p.kind === "ag-ayar" && n) {
    fLabel.value = n.label;
    fDns.value = n.dns || DNS_PRESETS[0].ips;
    fRevision.value = n.revision;
  } else if (p.kind === "ag-ekle" && s) {
    fIndex.value = nextNetwork(s);
    if (fIndex.value === null) return;
    fLabel.value = "";
    fPort.value = String(suggestPort(s));
    fDns.value = DNS_PRESETS[0].ips;
  }
  const switching = panel.value !== null;
  panel.value = p;
  // Another view of the open panel (settings → regenerate): focus its first field, as a newly opened one.
  if (switching) void nextTick(() => document.querySelector<HTMLElement>(".modal-sheet [data-autofocus], .modal-sheet .modal-body input")?.focus());
}

function closePanel(): void {
  if (working.value) return;
  panel.value = null;
}

const nameError = computed(() => {
  const name = fName.value.trim();
  if (!name) return tried.value ? "Cihaza bir ad verin." : "";
  if (!NAME_RE.test(name)) return "Harf, rakam, nokta, alt çizgi ve tire; en çok 32 karakter.";
  if (panelNet.value?.peers.some((p) => p.name === name)) return "Bu ağda aynı adlı bir cihaz zaten var.";
  return "";
});
const kaError = computed(() => keepaliveProblem(fKa.value));
const labelError = computed(() => labelProblem(fLabel.value));
const portError = computed(() => (state.value ? portProblem(state.value, fPort.value) : ""));

const canSave = computed(() => {
  const p = panel.value;
  if (!p || !writable.value) return false;
  switch (p.kind) {
    case "cihaz-ekle":
      return Boolean(fName.value.trim()) && !nameError.value && Boolean(fDns.value) && !kaError.value;
    case "cihaz": {
      const peer = panelPeer.value;
      return Boolean(peer && fDns.value && !kaError.value && (fDns.value !== peer.dns || Number(fKa.value.trim()) !== peer.keepalive));
    }
    case "ag-ayar": {
      const n = panelNet.value;
      return Boolean(n && fDns.value && !labelError.value && (fDns.value !== n.dns || fLabel.value !== n.label));
    }
    case "yeniden-uret":
    case "kaldir":
      return confirmed.value;
    case "ag-ekle":
      return fIndex.value !== null && !portError.value && Boolean(fDns.value) && !labelError.value;
  }
  return false;
});

async function submit(): Promise<void> {
  tried.value = true;
  const p = panel.value;
  const s = state.value;
  if (!p || !s || !canSave.value || working.value) return;
  working.value = true;
  panelError.value = "";
  note.value = "";
  error.value = "";
  qrOffer.value = null;
  try {
    if (p.kind === "cihaz-ekle") {
      const name = fName.value.trim();
      await addDevice(p.iface, name, fDns.value, Number(fKa.value.trim()), s.defaults.mtu || 1420);
      panel.value = null;
      await load();
      note.value = `“${name}” eklendi.`;
      const n = netOf(p.iface);
      const peer = n?.peers.find((x) => x.name === name);
      if (n && peer) void openQr(n, peer, true);
    } else if (p.kind === "cihaz") {
      const peer = panelPeer.value;
      if (!peer) return;
      const dns = fDns.value;
      const ka = Number(fKa.value.trim());
      if (dns !== peer.dns) await setDeviceDns(p.iface, p.name, dns);
      if (ka !== peer.keepalive) await setDeviceKeepalive(p.iface, p.name, ka);
      panel.value = null;
      await load();
      note.value = `${p.name} güncellendi: DNS ${providerOf(dns)}, keepalive ${keepaliveText(ka)}. Cihazda yeni QR'ı okutun.`;
      qrOffer.value = { iface: p.iface, name: p.name };
    } else if (p.kind === "ag-ayar") {
      await saveNetworkSettings(p.iface, fDns.value, fRevision.value, fLabel.value);
      panel.value = null;
      await load();
      note.value = `${p.iface} ayarları kaydedildi. Mevcut anahtarlar ve cihaz profilleri korundu.`;
    } else if (p.kind === "yeniden-uret") {
      const r = await regenerateNetwork(p.iface);
      panel.value = null;
      await load();
      note.value = `${p.iface} yeniden üretildi: ${r.peers} cihaz silindi, yeni sunucu anahtarı etkin.`;
    } else if (p.kind === "kaldir") {
      const port = netOf(p.iface)?.port;
      const r = await removeNetwork(p.iface);
      panel.value = null;
      if (selected.value === p.iface) updateQuery(router, { ag: null });
      await load();
      note.value = `${p.iface} kaldırıldı: ${r.peers} cihaz silindi${port ? `, UDP ${port} kapandı` : ""}.`;
    } else if (p.kind === "ag-ekle") {
      const port = Number(fPort.value.trim());
      const r = await addNetwork(port, fDns.value, fLabel.value);
      panel.value = null;
      await load();
      updateQuery(router, { ag: r.iface === ids.value[0] ? null : r.iface });
      note.value = `${r.iface} oluşturuldu: UDP ${r.port || port} açık. Şimdi Cihaz ekle ile cihaz ekleyin.`;
    }
  } catch (err) {
    panelError.value = err instanceof Error ? err.message : String(err);
    void load();
  } finally {
    working.value = false;
  }
}

const panelText = computed(() => {
  const p = panel.value;
  const n = panelNet.value;
  if (!p) return { title: "", description: "", go: "" };
  const where = n ? `${labelOf(n)} · UDP ${n.port} · ${n.subnet4}` : "";
  switch (p.kind) {
    case "cihaz-ekle":
      return { title: `${p.iface} ağına cihaz ekle`, description: n ? `${labelOf(n)} · ${n.subnet4} · anahtarlar sunucuda üretilir` : "", go: "Cihaz ekle" };
    case "cihaz": {
      const peer = panelPeer.value;
      return {
        title: `${p.name} · düzenle`,
        description: peer ? `${p.iface} · ${peer.ipv4} · şu an DNS ${providerOf(peer.dns, peer.provider)}, keepalive ${keepaliveText(peer.keepalive)}` : "",
        go: "Kaydet",
      };
    }
    case "ag-ayar":
      return { title: `${p.iface} · ağ ayarları`, description: where, go: "Ayarları kaydet" };
    case "yeniden-uret":
      return { title: `${p.iface} · ${n ? labelOf(n) : ""} yeniden üretilsin mi?`, description: where + " · Yalnız internet", go: "Yeniden üret" };
    case "kaldir":
      return { title: `${p.iface} · ${n ? labelOf(n) : ""} kaldırılsın mı?`, description: where + " · Yalnız internet", go: "Ağı kaldır" };
    case "ag-ekle":
      return { title: networks.value.length ? "Ağ ekle" : "WireGuard'ı yapılandır", description: "Sıradaki boş ağ seçildi", go: "Ağı oluştur" };
  }
  return { title: "", description: "", go: "" };
});
const danger = computed(() => panel.value?.kind === "yeniden-uret" || panel.value?.kind === "kaldir");
const peerNames = computed(() => (panelNet.value?.peers ?? []).map((p) => p.name));
const lastNetwork = computed(() => networks.value.length === 1);
const addWill = computed(() => [
  "Yeni sunucu anahtarı üretilir.",
  `UDP ${/^\d+$/.test(fPort.value.trim()) ? fPort.value.trim() : "…"} internete açılır; güvenlik duvarı kuralları kurulur.`,
  `Yeni cihazlara ${fDns.value ? providerOf(fDns.value) : "seçilen"} DNS önerilir.`,
]);

const addBadge = (ips: string | null) => (ips === panelNet.value?.dns ? "ağın varsayılanı" : ips === DNS_PRESETS[0].ips ? "önerilen" : "");
function editBadge(ips: string | null): string {
  const peer = panelPeer.value;
  if (!peer) return "";
  const preset = DNS_PRESETS.some((d) => d.ips === peer.dns);
  if (ips === null) return preset ? "" : "şu an";
  return ips === peer.dns ? "şu an" : ips === panelNet.value?.dns ? "ağın varsayılanı" : "";
}
const netBadge = (ips: string | null) => (ips !== null && ips === panelNet.value?.dns ? "kayıtlı" : "");
const newBadge = (ips: string | null) => (ips === DNS_PRESETS[0].ips ? "önerilen" : "");
</script>

<template>
  <div class="access-tab wireguard" data-testid="wireguard">
    <section v-if="installed === false || missing" class="card" aria-label="WireGuard" data-testid="wg-missing">
      <EmptyState title="WireGuard kurulu değil" text="Cihazlarınızın bu sunucu üzerinden internete çıkması için WireGuard'ı App Store'dan kurun." icon="shield">
        <RouterLink to="/uygulamalar" class="btn btn-secondary">Uygulamalar → Uygulama ekle</RouterLink>
      </EmptyState>
    </section>

    <template v-else>
      <div v-if="stopped" class="notice notice-warning" role="note" data-testid="wg-stopped">
        <Icon name="stop" class="notice-icon" />
        <div>
          <p class="notice-title">WireGuard durduruldu</p>
          <p class="notice-list">Cihazlar bağlanamaz; ağlar ve cihazlar değiştirilemez. Anahtarlar, cihazlar ve profiller duruyor.
            <RouterLink :to="appRoute('paket:wireguard')">Uygulamanın sayfasından başlatın.</RouterLink></p>
        </div>
      </div>
      <p v-if="loadError" class="form-error" role="alert" data-testid="wg-load-error">{{ loadError }}</p>
      <p class="sr-only" role="status">{{ note }}</p>
      <div v-if="note" class="action-line" data-testid="wg-note">
        <span class="action-note" aria-hidden="true">{{ note }}</span>
        <button v-if="qrOffer" type="button" class="btn btn-secondary btn-sm" data-testid="qr-offer" @click="showOfferedQr"><Icon name="qr" :size="16" />QR'ı göster</button>
      </div>
      <p v-if="error" class="form-error" role="alert" data-testid="wg-error">{{ error }}</p>

      <template v-if="state">
        <section v-if="!networks.length" class="card" aria-label="WireGuard ağı yok" data-testid="wg-empty">
          <EmptyState title="WireGuard yapılandırılmadı" text="Kurulum WireGuard ağı oluşturmaz. İlk ağı burada kurarsınız: anahtar sunucuda üretilir, UDP portu açılır ve cihaz eklemeye hazır olur." icon="shield">
            <ul class="modal-list wg-empty-list">
              <li><Icon name="shield" :size="18" /><span>wg0 · 10.8.0.0/24 · sunucu 10.8.0.1</span></li>
              <li><Icon name="lock" :size="18" /><span>Cihazlar yalnız internete çıkar; sunucu servislerine ve diğer ağlara erişemez.</span></li>
              <li><Icon name="plus" :size="18" /><span>Kurduktan sonra cihaz eklersiniz; QR hemen hazır olur.</span></li>
            </ul>
            <button type="button" class="btn btn-primary" :disabled="!writable" data-testid="wg-setup" @click="open({ kind: 'ag-ekle' })"><Icon name="plus" :size="18" />Yapılandır</button>
          </EmptyState>
        </section>

        <Tabs v-else :tabs="tabs" label="WireGuard ağları" param="ag">
          <template #end>
            <button
              type="button"
              class="btn btn-secondary btn-sm"
              :disabled="next === null || !writable"
              :aria-describedby="next === null ? 'wg-sinir' : undefined"
              data-testid="wg-add-net"
              @click="open({ kind: 'ag-ekle' })"
            >
              <Icon name="plus" :size="16" />Ağ ekle
            </button>
            <span v-if="next === null" id="wg-sinir" class="meter-note">En çok {{ state.max }} ağ</span>
          </template>
          <template #default>
            <section v-if="current" class="card wg-net" :class="{ 'wg-net-off': !current.active }" :aria-labelledby="'wg-baslik-' + current.iface" :data-ag="current.iface">
              <div class="card-head">
                <div class="wg-net-title">
                  <h2 :id="'wg-baslik-' + current.iface" class="card-title">{{ current.iface }} · {{ labelOf(current) }}</h2>
                  <span class="meter-note">UDP {{ current.port }} · {{ current.subnet4 }} · Yalnız internet</span>
                </div>
                <div class="card-actions">
                  <Switch
                    :model-value="current.active"
                    :label="`${current.iface} ağı açık`"
                    :disabled="!writable"
                    data-testid="wg-net-switch"
                    @update:model-value="toggleNetwork(current, $event)"
                  />
                  <button type="button" class="btn btn-secondary btn-sm" data-testid="wg-net-settings" @click="open({ kind: 'ag-ayar', iface: current.iface })">
                    <Icon name="sliders" :size="16" />Ağ ayarları
                  </button>
                </div>
              </div>
              <div v-if="!current.active" class="notice" role="note" data-testid="wg-off">
                <Icon name="power" class="notice-icon" />
                <span><strong>{{ current.iface }} kapalı.</strong> Cihazlar bağlanamaz. Anahtarlar, cihazlar ve profiller duruyor; açınca kendiliğinden bağlanırlar.</span>
                <button type="button" class="btn btn-primary btn-sm" :disabled="!writable" @click="toggleNetwork(current, true)">Ağı aç</button>
              </div>
              <dl class="wg-summary" data-testid="wg-summary">
                <div><dt>Bağlı</dt><dd>{{ summary(current).connected }}</dd></div>
                <div><dt>Port</dt><dd>{{ summary(current).port }}</dd></div>
                <div><dt>Erişim</dt><dd>Yalnız internet</dd></div>
                <div><dt>Adres</dt><dd class="mono">{{ summary(current).address }}</dd></div>
              </dl>
              <div v-if="current.peers.length" class="table-wrap">
                <table class="data-table wg-table">
                  <thead>
                    <tr>
                      <th scope="col">Cihaz</th>
                      <th scope="col">Açık</th>
                      <th scope="col">Durum</th>
                      <th scope="col">Adres</th>
                      <th scope="col">Son görülme</th>
                      <th scope="col">Trafik</th>
                      <th scope="col"><span class="sr-only">Eylemler</span></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr v-for="d in devices(current)" :key="d.p.name" :class="{ 'row-off': d.cut }" :data-cihaz="d.p.name">
                      <th scope="row" class="col-main">
                        <strong>{{ d.p.name }}</strong>
                        <span class="cell-sub">DNS {{ providerOf(d.p.dns, d.p.provider) }} · keepalive {{ keepaliveText(d.p.keepalive) }}</span>
                      </th>
                      <td data-label="Açık">
                        <Switch
                          :model-value="d.p.enabled"
                          :label="`${d.p.name} bağlantısı`"
                          hide-label
                          :disabled="!writable || !current.active"
                          @update:model-value="toggleDevice(current, d.p, $event)"
                        />
                      </td>
                      <td data-label="Durum"><StatusPill :tone="d.tone" :dot="d.st === 'ok'" data-testid="device-state">{{ d.label }}</StatusPill></td>
                      <td data-label="Adres"><span class="cell-stack"><span class="mono">{{ d.p.ipv4 }}</span><span class="mono cell-note">{{ d.p.ipv6 }}</span></span></td>
                      <td data-label="Son görülme">{{ d.cut ? UNKNOWN : seen(d.p) }}</td>
                      <td data-label="Trafik"><span class="traffic"><span>↓ {{ bytes(d.p.rx) }}</span><span>↑ {{ bytes(d.p.tx) }}</span></span></td>
                      <td class="col-act">
                        <span class="row-actions">
                          <button type="button" class="icon-btn" :disabled="!d.p.profile" :aria-label="`${d.p.name} QR kodu`" :title="`${d.p.name} QR kodu`" data-eylem="qr" @click="openQr(current, d.p)"><Icon name="qr" :size="18" /></button>
                          <button type="button" class="icon-btn" :disabled="!d.p.profile" :aria-label="`${d.p.name} profilini indir (gizli anahtar içerir)`" :title="`${d.p.name} profilini indir (gizli anahtar içerir)`" data-eylem="profil" @click="downloadProfile(current.iface, d.p.name)"><Icon name="download" :size="18" /></button>
                          <button type="button" class="icon-btn" :disabled="!writable" :aria-label="`${d.p.name} düzenle`" :title="`${d.p.name} düzenle`" data-eylem="duzenle" @click="open({ kind: 'cihaz', iface: current.iface, name: d.p.name })"><Icon name="pencil" :size="18" /></button>
                          <button type="button" class="icon-btn icon-btn-danger" :disabled="!writable" :aria-label="`${d.p.name} sil`" :title="`${d.p.name} sil`" data-eylem="sil" @click="askDelete = { n: current, p: d.p }"><Icon name="trash" :size="18" /></button>
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <EmptyState v-else title="Bu ağda henüz cihaz yok" text="Cihaz ekle ile ilk cihazı ekleyin; QR hemen hazır olur." icon="shield" />
              <button type="button" class="btn btn-primary fit" :disabled="!writable" data-testid="wg-add-device" @click="open({ kind: 'cihaz-ekle', iface: current.iface })">
                <Icon name="plus" :size="18" />Cihaz ekle
              </button>
            </section>
          </template>
        </Tabs>
      </template>
      <section v-else-if="!loadError" class="card" aria-label="WireGuard">
        <EmptyState title="WireGuard okunuyor" icon="shield" />
      </section>
    </template>

    <!-- the one side panel -->
    <Modal :open="panel !== null" variant="sheet" :title="panelText.title" :description="panelText.description" @close="closePanel">
      <form id="wg-form" class="form-stack" novalidate @submit.prevent="submit">
        <template v-if="panel?.kind === 'cihaz-ekle'">
          <Field v-slot="{ id, describedby, invalid }" label="Cihaz adı" hint="Profil dosyasının adı da bu olur." :error="nameError">
            <input :id="id" v-model="fName" class="input" type="text" maxlength="32" autocomplete="off" spellcheck="false" placeholder="ör. iphone, macbook, tv-salon"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
          </Field>
          <DnsChoice v-model="fDns" label="DNS sunucuları" :badge="addBadge" />
        </template>
        <template v-if="panel?.kind === 'cihaz'">
          <DnsChoice v-model="fDns" label="DNS sunucuları" :badge="editBadge" />
        </template>
        <template v-if="panel?.kind === 'cihaz-ekle' || panel?.kind === 'cihaz'">
          <Field v-slot="{ id, describedby, invalid }" label="PersistentKeepalive (saniye)" hint="Cihaz boştayken bağlantıyı açık tutmak için kaç saniyede bir paket yollasın. 0 = kapalı; mobil ağlarda 21 önerilir." :error="kaError">
            <div class="ka-row">
              <input :id="id" v-model="fKa" class="input ka-input" type="text" inputmode="numeric" maxlength="5" autocomplete="off"
                :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
              <span class="choice-chips" role="group" aria-label="Hazır değerler">
                <button v-for="[value, text] in KEEPALIVES" :key="value" type="button" class="filter-chip" :aria-pressed="fKa.trim() === value" @click="fKa = value">{{ text }}</button>
              </span>
            </div>
          </Field>
          <p v-if="panel?.kind === 'cihaz-ekle'" class="meter-note">MTU {{ state?.defaults.mtu || 1420 }} · anahtarlar sunucuda üretilir; QR eklenince açılır.</p>
          <p v-else class="notice" role="note"><Icon name="info" class="notice-icon" /><span>Anahtar ve adres değişmez. Kaydedince cihazda yeni QR'ı okutun: eski tüneli silip yenisini ekleyin.</span></p>
        </template>

        <template v-if="panel?.kind === 'ag-ayar' && panelNet">
          <Field v-slot="{ id, describedby, invalid }" label="Ağın adı" hint="Yalnız Konsol'da görünür; boş bırakılabilir." :error="labelError">
            <input :id="id" v-model="fLabel" class="input" type="text" maxlength="64" autocomplete="off" :placeholder="panelNet.iface === 'wg0' ? 'Ana ağ' : 'ör. Misafir, İş'"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
          </Field>
          <DnsChoice v-model="fDns" label="Varsayılan DNS" :badge="netBadge" />
          <p class="meter-note">Varsayılan DNS yalnız yeni eklenecek cihazlara önerilir; mevcut cihazların DNS'i ve QR/profili değişmez. Kaydetmek anahtarları, cihazları, portu ve adresleri değiştirmez; kapalı bir ağı başlatmaz.</p>
          <div class="danger-zone">
            <p class="meter-note">Yeniden üretmek bütün cihaz profillerini siler ve sunucu anahtarını değiştirir; kaldırmak ağı ve cihazlarını siler.</p>
            <div class="row-actions">
              <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="!writable" data-testid="wg-regen" @click="open({ kind: 'yeniden-uret', iface: panelNet.iface })"><Icon name="refresh" :size="16" />Anahtarı yeniden üret…</button>
              <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="!writable" data-testid="wg-remove" @click="open({ kind: 'kaldir', iface: panelNet.iface })"><Icon name="trash" :size="16" />Ağı kaldır…</button>
            </div>
          </div>
        </template>

        <template v-if="panel?.kind === 'yeniden-uret' && panelNet">
          <ul class="modal-list">
            <li><Icon name="refresh" :size="18" /><span>Yeni sunucu anahtarı üretilir; port, adresler ve erişim aynı kalır.</span></li>
            <li><Icon name="shield" :size="18" /><span>{{ peerNames.length ? `${peerNames.length} cihazın profili ve QR kodu silinir (${peerNames.join(", ")}); eski profillerle bağlanılamaz.` : "Bu ağda cihaz yok." }}</span></li>
            <li><Icon name="plus" :size="18" /><span>Cihazları Cihaz ekle ile yeniden eklemek gerekir. Geri alınamaz.</span></li>
          </ul>
          <ConfirmWord v-model:confirmed="confirmed" />
        </template>

        <template v-if="panel?.kind === 'kaldir' && panelNet">
          <ul class="modal-list">
            <li><Icon name="shield" :size="18" /><span>{{ peerNames.length ? `${peerNames.length} cihazın bağlantısı kesilir; profilleri ve QR kodları silinir (${peerNames.join(", ")}).` : "Bu ağda cihaz yok." }}</span></li>
            <li><Icon name="lock" :size="18" /><span>UDP {{ panelNet.port }} kapanır; bu ağın güvenlik duvarı kuralları kaldırılır.</span></li>
            <li><Icon name="trash" :size="18" /><span>Sunucu anahtarı silinir. Geri alınamaz; aynı ağ yeniden eklenirse cihazlara yeni profil gerekir.</span></li>
            <li v-if="lastNetwork" data-testid="wg-last"><Icon name="alert" :size="18" /><span>Bu son ağ: kaldırınca WireGuard yapılandırılmamış duruma döner; yeni ağı Yapılandır ile kurarsınız.</span></li>
          </ul>
          <ConfirmWord v-model:confirmed="confirmed" />
        </template>

        <template v-if="panel?.kind === 'ag-ekle' && fIndex !== null">
          <p class="wg-ident" data-testid="wg-ident">
            <strong>wg{{ fIndex }}</strong><span class="mono">10.8.{{ fIndex }}.0/24</span><span class="mono">sunucu 10.8.{{ fIndex }}.1</span><span>Yalnız internet</span>
          </p>
          <Field v-slot="{ id, describedby, invalid }" label="Ağın adı" optional hint="Yalnız Konsol'da görünür." :error="labelError">
            <input :id="id" v-model="fLabel" class="input" type="text" maxlength="64" autocomplete="off" placeholder="ör. Misafir, İş"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
          </Field>
          <Field v-slot="{ id, describedby, invalid }" label="UDP portu" hint="1024–65535; kullanılmayan bir port." :error="portError">
            <input :id="id" v-model="fPort" class="input" type="text" inputmode="numeric" maxlength="5" autocomplete="off"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
          </Field>
          <DnsChoice v-model="fDns" label="Varsayılan DNS" :badge="newBadge" />
          <ul class="modal-list">
            <li v-for="(w, i) in addWill" :key="i"><Icon name="check" :size="18" /><span>{{ w }}</span></li>
          </ul>
          <p class="notice" role="note"><Icon name="info" class="notice-icon" /><span>Cihazlar yalnız internete çıkar; sunucu servisleri, özel ağlar ve diğer cihazlar erişime kapalıdır.</span></p>
        </template>
        <p v-if="panelError" class="form-error" role="alert" data-testid="panel-error">{{ panelError }}</p>
      </form>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="working" @click="closePanel">Vazgeç</button>
        <button type="submit" form="wg-form" class="btn" :class="danger ? 'btn-danger' : 'btn-primary'" :disabled="!canSave || working" data-testid="panel-go">
          {{ working ? "Gönderiliyor…" : panelText.go }}
        </button>
      </template>
    </Modal>

    <!-- turning a network off -->
    <Modal :open="askOff !== null" :title="askOff ? `${askOff.iface} · ${labelOf(askOff)} kapatılsın mı?` : ''" :description="askOff ? `UDP ${askOff.port} · ${askOff.subnet4} · Yalnız internet` : ''" @close="askOff = null">
      <ul v-if="askOff" class="modal-list">
        <li><Icon name="shield" :size="18" /><span>{{ offOnline ? `${offOnline} bağlı cihazın bağlantısı hemen kesilir; ${askOff.peers.length} cihazın hiçbiri bağlanamaz.` : `Bu ağdaki ${askOff.peers.length} cihaz bağlanamaz.` }}</span></li>
        <li><Icon name="lock" :size="18" /><span>Ağ durdurulur; açınca aynı anahtar ve adreslerle geri gelir.</span></li>
        <li><Icon name="refresh" :size="18" /><span>Anahtar, cihazlar ve profiller silinmez. Sunucu yeniden başlasa da kapalı kalır.</span></li>
      </ul>
      <p v-if="error" class="form-error" role="alert">{{ error }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus :disabled="working" @click="askOff = null">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="working" data-onay="kapat" @click="confirmOff">Ağı kapat</button>
      </template>
    </Modal>

    <!-- deleting a device -->
    <Modal :open="askDelete !== null" :title="askDelete ? `“${askDelete.p.name}” silinsin mi?` : ''" :description="askDelete ? `${askDelete.n.iface} · ${askDelete.p.ipv4} · ${askDelete.p.ipv6}` : ''" @close="askDelete = null">
      <ul v-if="askDelete" class="modal-list">
        <li><Icon name="shield" :size="18" /><span>Bağlantısı hemen kesilir.</span></li>
        <li><Icon name="qr" :size="18" /><span>Profili ve QR kodu silinir; bu cihazı yeniden bağlamak için yeniden eklemek gerekir.</span></li>
        <li><Icon name="refresh" :size="18" /><span>{{ askDelete.p.ipv4 }} adresi boşa çıkar ve yeni cihazlara verilebilir.</span></li>
      </ul>
      <p v-if="error" class="form-error" role="alert">{{ error }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus :disabled="working" @click="askDelete = null">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="working" data-onay="sil" @click="confirmDelete">Cihazı sil</button>
      </template>
    </Modal>

    <!-- the QR code -->
    <Modal :open="qr !== null" :title="qr ? `${qr.name} · QR` : ''" :description="qr ? `${qr.iface} · ${qr.ipv4} · ${qr.dns} DNS` : ''" @close="closeQr">
      <div class="qr-box" data-testid="qr-box">
        <img v-if="qrUrl" :src="qrUrl" :alt="`${qr?.name} için WireGuard QR kodu`" width="240" height="240" @load="onQrLoad" />
        <p v-else-if="qrError" class="form-error" role="alert">{{ qrError }}</p>
        <p v-else class="meter-note">QR hazırlanıyor…</p>
      </div>
      <p class="notice notice-warning" role="note">
        <Icon name="lock" class="notice-icon" />
        <span>QR ve profil cihazın gizli anahtarını taşır. Yalnız cihazın kendisine okutun; ekran görüntüsü almayın.</span>
      </p>
      <template #actions>
        <button type="button" class="btn btn-secondary" @click="qr && downloadProfile(qr.iface, qr.name)"><Icon name="download" :size="16" />Profili indir</button>
        <button type="button" class="btn btn-primary" data-autofocus @click="closeQr">{{ qr?.fresh ? "Bitti" : "Kapat" }}</button>
      </template>
    </Modal>
  </div>
</template>
