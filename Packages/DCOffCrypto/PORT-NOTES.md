# DCOffCrypto — notes

Opening password-protected OOXML, from [MS-OFFCRYPTO] v20260217 (in `../OfficeFileFormatsProtocols`). **Not a
port**: deckcraft can't open these files. It depends on DCCFB, the compound file a protected `.pptx` is wrapped in,
and uses CommonCrypto for AES, SHA-1 and SHA-2, and HMAC. Writing comes in E3 of
`Docs/plans/Legacy-PPT-and-Encryption.md`.

## What it reads

- **Agile encryption** (version 4.4; Office 2010 and later). `keyData` and the password key encryptor come from the
  XML, by local name, because writers use different namespace prefixes. The rest:
  - The password is hashed with the salt and iterated `spinCount` times (at most 10,000,000, the specification's
    cap).
  - Three keys come from three fixed block keys: the verifier input, the verifier hash, and the key.
  - The intermediate key decrypts the package in 4096-byte segments. Each segment's IV is the hash of the salt and
    the segment's number.
  - Cipher AES-128, -192 or -256 in CBC mode; hash SHA-1, -256, -384 or -512.
- **The integrity check:** Agile's HMAC covers the whole `EncryptedPackage` stream, size field included. It's
  checked before anything is decrypted, so a changed byte is reported as damage rather than surfacing later as a
  bad zip. The HMAC key is the decrypted `encryptedHmacKey` cut to the hash's size, which is what Office writes
  (the specification's wording says the salt's size).
- **Standard encryption** (versions 2.2, 3.2 and 4.2; Office 2007):
  - SHA-1 iterated 50,000 times, then CryptDeriveKey's 0x36 and 0x5C pads.
  - AES in ECB mode, with no integrity check.
- **Refused by name:** Extensible encryption (x.3), rights-managed files (`\x09DRMContent`, or a DRM transform under
  `\x06DataSpaces`), certificate-only Agile files, and other ciphers and chaining modes.

## Never crashing, never leaking

- **Bounded input:** sizes, counts, salts and the spin count are bounded before use, and every read past the end
  of a field gives zeros rather than trapping.
- **Cancellable:** the key derivation polls `isCancelled` every 16,384 rounds.
- **Errors carry no secrets:** an error says what failed. It never includes the password, a key or plaintext.

## Checked against

- **The legacy fixtures:** every encrypted `.pptx`, 36 in all, decrypts to the exact bytes it was made from. They
  cover Apache POI's Agile AES-256/SHA-512 and AES-128/SHA-1 and its Standard AES-128, and msoffcrypto-tool's
  Agile. The passwords are ASCII, accented, outside the BMP, and 255 characters long.
- **PowerPoint 16's own files:** its 9 protected copies (local only) decrypt to the same bytes msoffcrypto-tool
  gets. PowerPoint writes Agile AES-256/SHA-512 with 100,000 rounds.
- **Failure cases:** a wrong password, or the right one in the wrong case, is `wrongPassword`; a flipped byte in
  the package fails the HMAC; cancelling stops the derivation; the hostile fixtures and 300 seeded corruptions end
  in an error.

## In the engine and the app (E2)

- **The engine:** `FileCommands.openProtected(name, bytes, password:)` reads a protected file. The commands:
  - `file.open` and `file.openBytes` take `password`.
  - Without a password the error is `EngineError.passwordRequired`; with a wrong one, `wrongPassword`.
  - The password is kept with the open document (`DocState.protection`) and nowhere else: not in the
    presentation, not in the journal (the engine drops a `password` parameter before journaling), not in
    AutoRecover, and not in a reply.
- **Saving:** until saving with a password arrives (E3), Save, Save As and `file.saveBytes` refuse a protected
  presentation rather than write it without its password, and AutoRecover leaves it out. Exports still work.
- **The app:** `PasswordPrompt` asks the way PowerPoint's *Password to Open* does, before the document's window,
  and asks again after a wrong password. The control channel's `app.open {path, password}` never prompts: a
  missing or wrong password comes back as an error.
- **dccli:** reads the password of a protected input from `DCCLI_PASSWORD`, keeping it out of the command line.
