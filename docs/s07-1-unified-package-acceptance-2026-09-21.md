# S07.1 birleşik medya paketi kabul kapanışı

21 Eylül 2026. S07.1, `4e6236e88b505d7fc22605cbf1b29a82992fe01f`
main commitinde **tamamlandı**. Bu kapanış yalnız yazılım paketini ve
GitHub-hosted iki mimarili kabulü kapsar. CasaOS/Proxmox kurulumu, gerçek
sağlayıcı hesapları ve HomePod/Cast kabulü MANUAL işlerinde kalır.

## Üç kabul grubu

1. **Tek ve secret-free paket.** Larenor Core ile Jellyfin, Seerr, Sonarr,
   Radarr, qBittorrent ve Music Assistant tek canonical Compose/bundle
   tanımından üretilir. OCI digest, sürüm, lisans, mimari, volume, tmpfs,
   container ve DNS kimlikleri deterministiktir. Kullanıcıdan dahili URL,
   token, parola veya credential kopyalaması istenmez.
2. **Fail-closed kurulum sınırı.** Owned path, sahip/izin, disk, mimari,
   manifest ve runtime kimlikleri pull/up öncesi doğrulanır. Eksik veya
   değiştirilmiş servis, symlink/path kaçışı, belirsiz receipt ve başarısız
   authenticated readback başarıya yükseltilmez. Cleanup yalnız exact private
   ownership receipt kapsamını kaldırır; otomatik retry yapmaz.
3. **Gerçek iki mimarili yaşam döngüsü.** Aynı PR headinde unified stack ile
   altı bileşenin amd64/arm64 karakterizasyonu geçti. Create, start, restart,
   mount/network/DNS ve container kimlikleri gerçek Docker runtime içinde
   doğrulandı; authenticated servis sonucu container makbuzundan ayrı kaldı.

## Kanıt

- Yerel exact-main politika paketi: unified bundle, deployment, runtime,
  managed-CI, workflow ve native-scope için **34/34 PASS**.
- PR #182 headi `b0f778dcb192e25bcfdd6893c039af984266390e`
  üzerinde **41 zorunlu check PASS**, başarısız veya bekleyen check yoktu.
- [Unified stack amd64/arm64](https://github.com/ersingundem/larenor/actions/runs/35538623984),
  [Android ve Server](https://github.com/ersingundem/larenor/actions/runs/35538624142)
  ve [Security](https://github.com/ersingundem/larenor/actions/runs/35538624021)
  kapıları geçti.
- Bağımsız kapanış incelemesi canonical paket, iki mimarili receipt ve altı
  bileşen kapsamını temiz buldu; kalan tek engel olan CI tamamlanınca PR #182
  otomatik birleşti.

S07.1 kapanışı kuyruk sayacını **18/125 (%14,4)** yapar. Seçili özellik
sayacı **0/63** kalır; bu paket tek başına gerçek ev veya fiziksel oynatıcı
kabulü değildir.
