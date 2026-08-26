# MEDIA_ENCRYPTION.md — FASE 1

Imágenes, vídeo, audio, notas de voz y documentos (§23–§26).

Fecha: 2026-08-25

---

## 1. Regla

> Nunca se envía un archivo grande por Socket.IO, y nunca se sube un
> archivo en claro.

Socket.IO es el canal de **control**. Un archivo de 50 MB en base64 (≈67
MB) lo bloquea, retrasa los mensajes de texto, y presiona la memoria de
un Android de gama media.

---

## 2. Flujo

### Subida

```
1. archivo original (local)
2. miniatura generada LOCALMENTE          ← antes de cifrar (§25)
3. object_key   = AES-256 aleatoria       ← por objeto
   object_id    = 256 bits aleatorios
4. ciphertext   = AES-256-GCM(archivo, object_key, nonce_1)
   thumb_ct     = AES-256-GCM(miniatura, object_key, nonce_2)   ← nonce DISTINTO
5. sha256(ciphertext)
6. subir SOLO los bytes cifrados a Supabase Storage
7. el mensaje lleva {object_id, key, nonce, sha256, size, tipo}
   DENTRO del ciphertext del mensaje
```

### Descarga

```
1. descifrar el mensaje → MediaReference
2. pedir URL firmada y caduca
3. descargar el ciphertext
4. VERIFICAR sha256(ciphertext)     ← ANTES de descifrar
5. AES-256-GCM abrir con la clave del mensaje
6. cachear en local (cifrado en reposo: PENDIENTE)
```

---

## 3. Decisiones

### Clave por objeto, no la del ratchet

Una clave AES-256 nueva por archivo. Reenviar un archivo a otra
conversación se hace compartiendo la clave del objeto, sin tocar la
sesión. Y comprometer un archivo no compromete la conversación.

### La clave viaja dentro del ciphertext del mensaje

Es la pieza central: **el servidor almacena el objeto pero nunca la
clave**. Los blobs son ruido para él. Poner la clave en la metadata del
mensaje anularía todo el esquema.

### El digest se calcula sobre el CIPHERTEXT y se verifica ANTES de descifrar

Sobre el plaintext obligaría a descifrar datos aún no verificados,
exponiendo el parser a bytes manipulados. Verificar antes permite
rechazar un blob corrupto sin tocarlo.

### Nonce distinto para la miniatura

Comparten clave pero **nunca** nonce. Reutilizar (clave, nonce) en
AES-GCM es catastrófico: filtra el XOR de ambos textos y permite forjar
etiquetas. Un fallo silencioso y fatal si se descuida.

### `object_id` aleatorio y sin estructura

No deriva de la conversación, la cuenta ni el nombre. Una ruta
predecible permitiría enumerar objetos o inferir el grafo social desde
los nombres de archivo.

### Metadata mínima en el servidor

Se guarda: `object_id`, propietario, conversación, **tamaño del cifrado**,
fechas. No se guarda: nombre real, MIME real, dimensiones, duración. Todo
eso es contenido y viaja cifrado. "vacaciones_divorcio.pdf" filtra tanto
como el archivo.

**Residual honesto:** el **tamaño** es visible y permite inferencias
(sticker vs. vídeo largo). Ocultarlo exigiría padding, con su coste.

### URLs firmadas y caducas (§26)

Nunca URLs públicas permanentes. Una URL permanente filtrada es acceso
perpetuo sin autenticación. Se firma por petición, con caducidad corta, y
se comprueba la pertenencia antes de firmar.

---

## 4. Notas de voz (§26)

Mismo camino, sin excepciones: grabar → cifrar local → subir cifrado →
referencia dentro del mensaje. La forma de onda se calcula **antes** de
cifrar y viaja dentro del ciphertext: es contenido (delata el ritmo del
habla), no metadata.

---

## 5. `MediaReference`

Vive **sólo** dentro del `MessageBody` cifrado:

```dart
MediaReference(
  objectId, keyBase64, nonceBase64, sha256Base64,
  sizeBytes, mediaType,
  thumbnailNonceBase64, durationMs, width, height,
)
```

`toString()` **redacta la clave**. Un log de depuración con la clave
completa la deja en disco sin cifrar, o en un servicio de crash
reporting. La redacción es deliberada.

---

## 6. Almacenamiento y retención

`realtime_media_objects` (migración 002), RLS **deny-by-default**.

- El borrado es **lógico** (`deleted = true`); el físico lo hace un
  worker. PostgREST no borra blobs de Storage: hacerlo aquí daría una
  falsa sensación de completitud.
- `nova_expire_media_objects()` marca lo caducado. **Sólo `service_role`**
  puede ejecutarla.
- Cuotas por tamaño de ciphertext.

Como en §22: esto borra la copia del **servidor**. No puede borrar lo que
alguien ya descargó.

---

## 7. Límites

- **Sin streaming**: se descarga el objeto completo antes de descifrar.
  Un vídeo largo tarda. El streaming autenticado por bloques queda para
  después.
- **La caché local todavía no está cifrada en reposo** (SQLCipher
  PENDIENTE): un archivo descifrado y cacheado es legible con acceso
  físico al dispositivo. **No se simula que esté hecho.**
- **Sin deduplicación** entre destinatarios: cada envío es un objeto
  nuevo. Deduplicar por hash filtraría qué usuarios comparten archivo.
- **Sin escaneo antivirus**: es imposible por diseño; el servidor no
  puede leer el contenido. Es el precio del E2EE.
