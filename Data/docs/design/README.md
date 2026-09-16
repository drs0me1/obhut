# Konsol — design mockups

Frozen HTML mockups of **Konsol**, the single admin console at
`http://panel.<domain>` that replaces the separate WireGuard (`wg.`) and
file (`dosya.`) panels. Each file is a self-contained page with sample
data and no backend; open it in a browser to see the agreed design.

Mockups are references, not code. They are frozen: iterate in a new
`konsol-vNN.html`, never edit a saved one. The behaviour they imply is
recorded in `../design-decisions.md`; the mockup only shows it.

| File | Date | Covers |
|------|------|--------|
| `konsol-v01.html` | 2026-09-16 | Sidebar and pages (Genel bakış, WireGuard, Dosyalar, Günlük); server card with CPU/RAM graphs and a disk bar; WireGuard network cards with lever switches, peer rows with on/off, QR, delete and an edit dialog; "Arayüz ekle" as its own page; file browser with a trash card; share links over a single read-only WebDAV account |
| `konsol-dosyalar-v02.html` | 2026-09-16 | Dosyalar sekmesinin FileBrowser'ı gereksiz kılan hâli: kısayol sütunu (Sunucu, downloads, media, Paylaşımlar, Çöp) ve disk göstergesi, arama ve görünüm anahtarı olan araç çubuğu, seçim modunda eylem çubuğuna dönüşen üst çubuk, ızgara görünümü + önizleme paneli, listenin içine sürükle-bırak yükleme (ilerleme satırın içinde, ayrı kuyruk alanı yok); sonunda davranış notları ve gereken API uçları |
| `konsol-hesaplar-v03.html` | 2026-09-16 | Hesaplar page inside the real console shell (the live `konsol.css` embedded): the Konsol admin card (from `kurulum.env`, not editable in the console) and one card per service account — share WebDAV, Dozzle, qBittorrent — with copy, reveal (hides after 30 s), generate a new password (confirm dialog → applying → revealed once) and set user/password with validation; the WireGuard note on Dozzle and qBittorrent; light and dark. Interactive, sample data |
| `konsol-moduller-v04.html` | 2026-09-16 | Faz A: the Modüller page that replaces Hesaplar (real `konsol.css` embedded). A "Temel" card lists what the installer brings and nothing removes (Konsol, Tailscale, DNS + Caddy, firewall, WireGuard layer, Docker). One card per module — Paylaşım, qBittorrent, Arşiv açıcı (unpackerr), Dozzle — with states Kurulu değil → Kuruluyor (step list) → Çalışıyor ⇄ Durduruldu → Kaldır (confirm, optional "ayarları ve hesabı da sil", `/srv` never touched). The v03 account block moves inside each module card; a new account is revealed once after install. Sidebar links follow installed modules. Interactive, sample data |
| `konsol-moduller-v05.html` | 2026-09-16 | The modules model the user chose after v04: qBittorrent runs **on the host** (Debian `qbittorrent-nox` 5.1.0, systemd, profile `/var/lib/qbittorrent`); Docker stays in the base and runs only Paylaşım (rclone) and Arşiv açıcı (unpackerr); **Dozzle is dropped**. Each card carries a Host/Docker chip, host-specific install steps (apt → account → settings → name and firewall → systemd) and a Günlük panel reading `journalctl` or `docker logs`, which replaces the log viewer. Interactive, sample data |
| `konsol-moduller-v06.html` | 2026-09-16 | The agreed Faz A model. A clean install brings only the base (Konsol core, Tailscale, DNS + Caddy, firewall, an empty Docker engine); **WireGuard** and the **Dosya yöneticisi** become modules too, next to qBittorrent (host package, **no settings managed**: only `torrent.ayc` → `127.0.0.1:8080`, first login from the temporary password in its log), Paylaşım (rclone, requires Dosya yöneticisi and installs it along) and Arşiv açıcı (unpackerr). Sidebar pages appear with their modules; removing a module that others need removes them too. Demo switch: clean install ⇄ installed sample |
