# Instrucciones para Cambiar el Icono de la App

Para cambiar el icono de NovaApp por el nuevo diseño (burbuja de chat con letra "N" y candado):

## Pasos:

1. **Prepara la imagen del icono:**
   - La imagen debe ser un archivo PNG cuadrado (1024x1024 píxeles recomendado)
   - Guárdala como `assets/icon.png` (reemplazando el archivo existente)

2. **Regenera los iconos:**
   Ejecuta el siguiente comando en la terminal:
   ```bash
   flutter pub run flutter_launcher_icons
   ```

3. **Verifica los cambios:**
   - Android: El icono se generará en `android/app/src/main/res/mipmap-*`
   - iOS: El icono se generará en `ios/Runner/Assets.xcassets/AppIcon.appiconset`

## Nota:
El archivo `pubspec.yaml` ya está configurado con `flutter_launcher_icons` para generar automáticamente los iconos a partir de `assets/icon.png`.
