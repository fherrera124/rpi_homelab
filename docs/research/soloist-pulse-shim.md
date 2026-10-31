# Investigación: reemplazar el `libpulse` de Soloist por un shim

**Estado:** planteo inicial. Nada de esto está implementado ni probado en la Pi.
**Rama:** `research/soloist-pulse-shim`. No se mezcla con `main` hasta cumplir los criterios del final.

## Por qué

Con la cadena actual (Soloist → `pipewire-pulse` → `module-pipe-sink` → FIFO → snapserver),
el slider de volumen de Spotify atenúa el audio **dentro de la Pi**, antes de que llegue a
Snapcast. Por encima del FLAC sin pérdida, eso agrega una multiplicación de las muestras y un
redondeo a 16 bits cada vez que el volumen no está en 100 %.

El objetivo es que el audio llegue intacto a cada cliente sea cual sea la posición del slider,
y que ese slider pueda servir de **maestro proporcional** sobre el volumen de los clientes
(un solo sentido: Spotify → Snapcast). Ver la conversación de diseño resumida abajo.

## Qué se midió (en la Pi `rpi2`, 2026-10-30)

| Dato | Resultado |
|---|---|
| Volumen del stream de Soloist en `pipewire-pulse` con el slider en una posición intermedia | 68 % (−10,15 dB), después 80 % |
| Mismo stream con el slider de la app en 100 | 100 % (0,00 dB) |
| Forzar el stream a 100 % con `pactl set-sink-input-volume` | Soloist emitió `{"type":"volume_changed","volume":100}` y **no** volvió a bajarlo |
| `quirks` de `pipewire-pulse` 1.4.2 | `block-sink-volume` y `block-source-volume` solo cubren sinks y sources, no streams de aplicaciones |

**Conclusión de las mediciones:** para Soloist, el volumen de Spotify *es* el volumen del sink
input. No se puede dejar el stream en 100 % sin que el slider de la app se vaya a 100 con él.
Por eso, sobre PipeWire, la única forma de obtener audio sin alterar es no usar el slider
(estado actual, "opción 1").

## La idea

Soloist hace `dlopen("libpulse.so.0")` y busca 47 símbolos `pa_*`. El proyecto
[`foonerd/alsa_soloist_connect`](https://github.com/foonerd/alsa_soloist_connect) (MIT) trae
un `libpulse.so.0` propio que implementa solo esos símbolos y entrega el audio a ALSA. Con
`APULSE_EXTERNAL_VOLUME=1` el shim **no multiplica las muestras**, pero sigue guardando el volumen
que Soloist le pide y se lo devuelve cuando lo lee. Soloist ve un volumen coherente y el audio
sale a escala completa.

Los cambios de volumen siguen llegando por la WebSocket de Soloist (`volume_changed`, ya
verificado con `soloist ctl trace`), así que un servicio pequeño puede traducirlos a
`Client.SetVolume` de Snapcast.

Ventaja secundaria a evaluar: si el shim reemplaza a PipeWire en el camino de Soloist, se puede
retirar PipeWire y WirePlumber de ese camino (menos paquetes y menos CPU en una Pi 2).

## Preguntas abiertas

1. **Cómo entregar el audio al FIFO con el ritmo correcto.** El shim original escribe a un
   dispositivo ALSA y su lógica de I/O depende de `snd_pcm_avail` y del reloj del dispositivo.
   Opciones: (a) plugin ALSA `file` hacia el FIFO; (b) `snd-aloop` + `arecord`; (c) un backend de
   FIFO propio dentro del shim (es MIT y se puede bifurcar). Snapserver lee el FIFO a ritmo de
   reloj, así que el bloqueo de escritura podría actuar como contrapresión, pero hay que verificarlo.
2. **Cómo elige Soloist el backend.** Su flag `--pipewire-device` sugiere que prefiere PipeWire
   si lo encuentra. Con PipeWire instalado en la Pi hay que forzar la ruta Pulse (el launcher del
   otro proyecto hace `unset PULSE_SERVER` y `unset PIPEWIRE_RUNTIME_DIR`).
3. **La rama MP3 para la Sangean.** `darkice` lee de `soloist_sink.monitor`, un monitor de
   PipeWire. Si PipeWire sale del camino, esa fuente desaparece. Alternativas: alimentar darkice
   desde un `snapclient` local, o conservar PipeWire solo para esa rama. Es el principal riesgo
   transversal.
4. **ABI frágil.** La lista de 47 símbolos corresponde a Soloist 1.3.7. Los builds vencen a los
   90 días y se renuevan por timer: una versión nueva puede pedir un símbolo que el shim no
   tiene. Habría que verificarlo en `update-soloist.sh` (por ejemplo, comparar los `pa_*` del
   binario nuevo contra `ABI.txt`) antes de reiniciar.
5. **Origen del binario.** El repo trae un `libpulse.so.0` precompilado para armhf. No debería
   usarse sin auditar: lo razonable es compilarlo del código fuente con un commit fijado. La Pi
   no tiene `gcc`, `cmake` ni `libasound2-dev` (glibc 2.41, arquitectura ARMv7), así que habría
   que compilar en otro equipo (Docker con qemu, como hace el proyecto) o instalar la
   toolchain de forma temporal.
6. **Qué parte de la ingeniería del shim aplica.** Gran parte de sus correcciones (xruns,
   reaperturas del PCM, `volumioswitch`, ceder el dispositivo) responde a ALSA y a un DAC
   exclusivo. Con una salida a FIFO probablemente no hagan falta.

## Plan de experimentos

Cada paso tiene un criterio de éxito. Si uno falla, se documenta y se decide si seguir.

| # | Experimento | Criterio de éxito |
|---|---|---|
| E0 | Compilar el shim desde el código fuente, con el commit fijado | Hash comparable con el binario precompilado; solo depende de `libasound` y libc |
| E1 | Arrancar Soloist con el shim, sin PipeWire en su camino | Se conecta a Spotify y reproduce, sin tocar `pipewire-pulse` |
| E2 | Llevar el audio al FIFO con la salida elegida | Snapserver recibe el stream sin cortes durante 1 h |
| E3 | Comprobar la transparencia | Capturar el FIFO con el slider en 100 y en otra posición: las muestras deben coincidir |
| E4 | Verificar los eventos de volumen | `volume_changed` llega por la WS al mover el slider |
| E5 | Resolver la fuente de darkice | La rama MP3 de la Sangean sigue funcionando |
| E6 | Servicio puente de volumen | El maestro proporcional mueve los clientes sin efectos cruzados |
| E7 | Prueba de varias horas con medición de CPU | CPU igual o menor que la cadena actual, sin `audio starved` |

## Decisión sobre el maestro (resumen)

Se acordó el modo **proporcional** y de **un solo sentido**: si Spotify pasa de 77 a 50, cada
cliente se multiplica por 50/77 (un cliente en 40 queda en 26). No existe camino de vuelta de
Snapcast a Spotify, para evitar rebotes entre varios clientes. La consecuencia aceptada es que
el slider de la app puede quedar desactualizado si se cambia un cliente desde Snapweb. Se
descartaron el modo absoluto (sube clientes al bajar el slider) y el de diferencia fija (hunde
a los clientes que ya estaban bajos), y la acción de "normalizar".

Casos borde pendientes de definir: slider anterior en 0 (división por cero), clientes que
llegan a 100 antes que los demás, y clientes desconectados al momento del cambio.

## Criterio para pasar a `main`

Solo si E1 a E7 salen bien y la rama MP3 de la Sangean queda resuelta. Si E2 o E5 no tienen
salida razonable, el resultado esperado es documentar por qué y quedarse con la cadena actual:
Spotify en 100 % y volumen desde los clientes.

## Alternativas descartadas

- **Compensar con ganancia en el sink** (aplicar 1/v después de la atenuación): matemáticamente
  neutra en coma flotante, pero un salto de volumen en la app produce un instante de audio
  amplificado. Riesgo para los parlantes.
- **Forzar el stream a 100 % desde un servicio:** Soloist lo interpreta como un cambio de
  volumen del usuario y mueve el slider.
