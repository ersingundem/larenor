# Managed volume — tam Core birleşim kontrolü

Kalıcı volume create protokolü ve önceki bütün Core özellikleri, `72af39999d31ba146a0821929e0a976441db85e9` kaynağında tek tam pytest koşumuyla doğrulandı: **3435 PASS / 12 Linux-only skip / 0 hata**. JUnit toplamı3447; pytest431,65 saniye, bütün süreç439,17 saniye. Önceki887 ilgili test bu toplamın altkümesidir, üzerine eklenmez.

Koşum izole worktree'nin `server` dizininde Python3.12.14 ile yapıldı; gerçek modül import yolları bu worktree'ye aitti. Java17 ve SHA256 ile pinlenen apksig9.1.0 kullanıldı. Gerçek AOSP imza/binary manifest, APK bozulması, bozuk/tekrarlanan manifest ve yanlış verifier pini için dört test de geçti. Yeni dört volume dosyası135 PASS/1 Linux skip içeriyor.

Atlanan12 vaka gerçek Linux peer credentials, pidfd/procfs, native thread kimliği, mount/fd gözlemi ve Unix stream kapanış davranışları içindir. Adları ve gerekçeleri JUnit'ten makbuza çıkarıldı. Bu Mac koşumu Linux veya gerçek Docker kurulum kabulü diye sunulmaz; yeni Linux CI'da3447 vakanın kendi sonucu izlenir.

| Kaynak ağacı | Doğrulanan Git nesnesi |
| --- | --- |
| server | `48216cacbdb927f538df9884894c5ad7564209eb` |
| contracts | `8eb1430790b63588046b362f6d1b643eb448d836` |
| android | `df7282547f4c06830e9028cea7518ed81c8dcdba` |
| server/larenor_server/releases | `3b5979004d2e5e3a1618c33c6607c7fba8c36d01` |
| server/larenor_server/releases/java | `4dacb16ddfda67a34d83503de07a69b75b29d9e2` |

Ana daldaki non-squash birleşimde bu beş ağaç test edilen kaynakla birebir eşleşti. Test sonrasında çalışma dalı temiz ve kaynağı aynıydı. Root, makbuz/günlük/XML SHA256 değerlerini, JUnit sayılarını ve ana dal ağaçlarını ayrıca okudu; ikinci tam Core koşumu başlatmadı. Koordinatör41588 çıkış0 ile toplandı.

Kanıt dizini `/private/tmp/larenor-volume-full-core-72af399-5i12w6jc/`:

- `receipt.json`: SHA256 `971aefc0f0c97d8aaeee6d95e1f8870bb01c9a5745d151231001667a5608c727`.
- `pytest.xml`: SHA256 `7b23bbe161b2ba1763df3b30543ce41b2a7b00abe2286b8f2eb879254aaafd17`.
- `pytest.log`: SHA256 `e84029693d741910f7d2ce85518633bfcd0f5cf4afdec8de88fd4a01e89bb426`.

İki bağımsız inceleme yeni journal, kapalı POST gövdesi, durable-before-effect, tek literal-True gate, restart sonrası POST tekrarlamama ve ACK/taze GET ayrımını temiz buldu. [Uygulama ve açık kurulum kapıları](managed-volume-create-implementation-2026-09-06.md) aynen geçerlidir. `installAvailable=false`; gerçek ev Engine işlemi, deployment veya cihaz kurulumu yapılmadı. Bu yerel sonuç S06.3d/S06.3f tamamlanması veya Client yayın kabulü değildir.
