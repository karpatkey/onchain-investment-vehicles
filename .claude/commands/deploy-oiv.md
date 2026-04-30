# /deploy-oiv — Deployment guiado de un OIV

Este skill guia al usuario paso a paso para deployar un nuevo fondo OIV via `KpkOivFactory`.
La factory ya está deployada en todas las chains. Este proceso deploya el fondo en sí.

Contexto técnico mínimo:
- `deployOiv` (mainnet): deploya toda la infraestructura del fondo + el token de shares (ERC-20).
- `deployStack` (sidechains): deploya solo la infraestructura operativa (sin token de shares).
- Ambas funciones son permissionless. El deployer no retiene ningún rol privilegiado post-deployment.
- El mismo `salt` + mismo `caller` (address del deployer) produce las mismas 5 direcciones de infraestructura en todas las chains. Esto es crítico para la coherencia cross-chain.

---

## Instrucciones para Claude

Seguí estos pasos en orden. Hacé **una pregunta a la vez**, esperá la respuesta del usuario y validá antes de continuar.
Usá español en todas las interacciones. Si el usuario da una respuesta inválida, explicá el problema y pedí que lo corrija.

---

### FASE 1 — Verificación del entorno

**Paso 1.1: Verificar Foundry**

Corré `forge --version` y `cast --version`.

- Si alguno falla: informale al usuario que Foundry no está instalado y preguntá si querés que lo instale ahora.
  - Si acepta: corré `curl -L https://foundry.paradigm.xyz | bash` y luego `foundryup`. Avisale que puede que necesite reiniciar el terminal.
  - Si rechaza: avisale que sin Foundry no se puede continuar y terminá el skill.
- Si ambos están presentes: confirmá la versión y continuá.

**Paso 1.2: Verificar dependencias del proyecto**

Corré `forge build` para verificar que el proyecto compila.

- Si falla con errores de dependencias: corré `forge install` y reintentá.
- Si falla por otro motivo: mostrá el error y pedí ayuda manual.
- Si compila: continuá.

**Paso 1.3: Verificar el archivo `.env`**

Revisá si existe un archivo `.env` en el directorio raíz del proyecto.

Si no existe, crealo vacío y avisale al usuario. Luego verificá que `.env` esté en `.gitignore`:
- Si no está: agregalo al `.gitignore` antes de continuar.

**Paso 1.4: Configurar la private key del deployer**

Preguntá:

> "Para hacer el deployment necesitás una cuenta con ETH para pagar el gas.
> Tenés ya una private key de deployer, o querés que generemos una nueva?"

**Si ya tiene una:**
- Pedile que la ingrese (solo para escribirla en `.env`, nunca la muestres en pantalla).
- Escribila en `.env` como `PRIVATE_KEY=0x<la_key>`.
- Mostrá la address pública: `cast wallet address --private-key $PRIVATE_KEY`.
- Confirmá que esa es la cuenta que va a deployar.

**Si quiere generar una nueva:**
- Corré `cast wallet new` y capturá el output.
- Escribí solo la private key en `.env` como `PRIVATE_KEY=0x<la_key>`.
- Mostrá al usuario **solo la address pública** y el mensaje:
  > "Wallet generada. Address del deployer: `<address>`
  > Esta cuenta necesita ETH en cada chain donde vayas a deployar para pagar el gas.
  > El deployer no retiene ningún rol privilegiado después del deployment — todas las
  > responsabilidades quedan en el admin y el Manager Safe que configures a continuación.
  > Fondeala antes de continuar."
- Preguntá: "¿Ya fondeaste la cuenta, o necesitás tiempo para hacerlo?"
  - Si necesita tiempo: avisale que puede retomar el proceso más tarde con `/deploy-oiv` y terminá.

**Paso 1.5: Verificar RPC URLs**

Preguntá qué chains va a deployar (mainnet, arbitrum, base, optimism, gnosis).
Según la respuesta, chequeá si las variables de entorno correspondientes están seteadas en `.env`:

| Chain     | Variable requerida    |
|-----------|----------------------|
| Mainnet   | `MAINNET_RPC_URL`    |
| Arbitrum  | `ARBITRUM_RPC_URL`   |
| Base      | `BASE_RPC_URL`       |
| Optimism  | `OPTIMISM_RPC_URL`   |
| Gnosis    | `GNOSIS_RPC_URL`     |

Para cada chain seleccionada que no tenga RPC URL seteada, pedí al usuario que la agregue al `.env`.
Podés sugerir que use Alchemy (alchemy.com) o Infura (infura.io) como proveedores gratuitos.
No continúes hasta que todas las RPC URLs necesarias estén configuradas.

---

### FASE 2 — Tipo de deployment

Preguntá:

> "¿Qué tipo de deployment querés hacer?
> 1. **OIV completo** — deploya la infraestructura del fondo + el token de shares en mainnet, y la infraestructura en las sidechains seleccionadas.
> 2. **Solo infraestructura** — deploya solo el backbone operativo (sin token de shares) en las chains seleccionadas. Útil para agregar soporte de una nueva chain a un fondo existente."

Guardá la respuesta como `deployment_type` (valores: `full_oiv` o `stack_only`).

Si eligió `full_oiv`, preguntá qué sidechains además de mainnet (puede ser ninguna):
> "Además de mainnet, ¿en qué sidechains querés deployar la infraestructura? (arbitrum, base, optimism, gnosis, o ninguna)"

Si eligió `stack_only`, preguntá en qué chains:
> "¿En qué chains querés deployar la infraestructura? (arbitrum, base, optimism, gnosis)"

---

### FASE 3 — Identidad del fondo

**Paso 3.1: Nombre del fondo**

Preguntá:
> "¿Cuál es el nombre del fondo? (ej: 'kpk USD Beta Fund')"

Usá la respuesta para derivar un `slug` en minúsculas sin espacios (ej: `kpk-usd-beta-fund`).
El slug se va a usar como nombre del archivo de configuración.

**Paso 3.2: Símbolo del token** (solo si `deployment_type == full_oiv`)

Preguntá:
> "¿Cuál va a ser el símbolo del token de shares? (ej: 'kUSDB' — máximo 8 caracteres, sin espacios)"

---

### FASE 4 — Manager Safe

Preguntá:
> "¿Cuáles son las addresses de los firmantes del Manager Safe?
> Ingresalas separadas por coma. (ej: 0xAbc..., 0xDef...)"

Validá cada address: debe ser un string hexadecimal de 42 caracteres que empiece con `0x`.
Si alguna es inválida, indicá cuál y pedí que la corrija.
No pueden haber addresses duplicadas.

Luego preguntá:
> "¿Cuántas firmas se requieren para aprobar una transacción? (debe ser mayor a 0 y menor o igual a la cantidad de firmantes)"

Validá que el threshold sea `> 0` y `<= cantidad de owners`.

---

### FASE 5 — Admin y autoridad

**Para `full_oiv`:**

Preguntá:
> "¿Cuál es la address del admin del fondo? El admin recibe control sobre el módulo de ejecución (exec Roles Modifier) y el rol DEFAULT_ADMIN_ROLE en el token de shares.
> Default: Security Council Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`
> (Presioná Enter para usar el default, o ingresá otra address)"

Si el usuario presiona Enter o deja vacío, usá `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`.
Validá que la address no sea `0x0000000000000000000000000000000000000000`.

**Para `stack_only`:**

Preguntá:
> "¿Cuál es la address que recibirá ownership del exec Roles Modifier? Típicamente el Security Council Safe.
> Default: `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`
> (Presioná Enter para usar el default, o ingresá otra address)"

---

### FASE 6 — Parámetros del token de shares (solo `full_oiv`)

**Paso 6.1: Asset base**

Preguntá:
> "¿Cuál es el asset base del fondo? Es el token principal para subscripciones y redenciones.
> Opciones comunes (mainnet):
>   1. USDC  — `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
>   2. USDT  — `0xdAC17F958D2ee523a2206206994597C13D831ec7`
>   3. WETH  — `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
>   4. Otra address (ingresala directamente)"

Guardá la address del asset base.

**Paso 6.2: Assets adicionales**

Preguntá:
> "¿Querés habilitar assets adicionales para subscripciones o redenciones además del asset base? (sí/no)"

Si dice sí, pedí por cada asset:
> "Ingresá la address del asset adicional:"
> "¿Se puede usar para **subscripciones** (depósitos)? (sí/no)"
> "¿Se puede usar para **redenciones** (retiros)? (sí/no)"

Seguí preguntando hasta que diga que no quiere agregar más. Máximo 20 assets adicionales.
Validá que no se repita el asset base ni addresses duplicadas.

**Paso 6.3: Fees**

Presentá este bloque de preguntas con contexto:
> "Ahora configuramos las comisiones del fondo. Todas se expresan en porcentaje (%) y el máximo es 20%."

Preguntá cada una por separado:

- **Management fee** (comisión anual de gestión):
  > "¿Cuál es la management fee anual? (ej: 1.5 para 1.5%, o 0 para no cobrar)"

- **Redemption fee** (comisión por retiro):
  > "¿Cuál es la redemption fee por cada retiro? (ej: 0.5 para 0.5%, o 0 para no cobrar)"

- **Performance fee** (comisión sobre ganancias):
  > "¿Hay performance fee? (sí/no)"
  - Si dice sí: preguntá el porcentaje y la address del módulo de performance fee.
    > "¿Cuánto es la performance fee? (ej: 10 para 10%)"
    > "¿Cuál es la address del módulo de performance fee?"
  - Si dice no: usá `0x0000000000000000000000000000000000000000` y 0%.

Convertí todos los porcentajes a basis points internamente: `bps = porcentaje * 100`.
Validá que ningún fee supere 2000 bps (20%).

**Paso 6.4: Fee receiver**

Preguntá:
> "¿A qué address se envían las comisiones (management fee, redemption fee, performance fee)?"

Validá que no sea address cero.

**Paso 6.5: TTLs (períodos de cancelación)**

Explicá y preguntá:
> "Los TTLs definen el tiempo mínimo que un inversor debe esperar antes de poder cancelar una solicitud pendiente."

- **TTL de subscripción:**
  > "¿Cuántos días debe esperar un inversor para cancelar una solicitud de subscripción? (mínimo 1, máximo 7)"

- **TTL de redención:**
  > "¿Cuántos días debe esperar un inversor para cancelar una solicitud de redención? (mínimo 1, máximo 7)"

Convertí a segundos internamente: `segundos = días * 86400`.

---

### FASE 7 — Salt

Preguntá:
> "El salt es un número que determina las direcciones del fondo en todas las chains.
> El mismo salt + la misma cuenta deployer produce las mismas direcciones en mainnet, Arbitrum, Base, etc.
> ¿Querés usar salt 0 (recomendado para el primer deployment de este fondo), o ingresás un número específico?"

Si el usuario presiona Enter o dice "0" o "default", usá `0`.
Si ingresa un número, validá que sea un entero no negativo.

---

### FASE 8 — Generación del archivo de configuración

Construí el JSON de configuración con los datos recopilados.

Para `full_oiv`, el archivo tiene esta estructura:

```json
{
  "fundName": "<nombre del fondo>",
  "managerSafe": {
    "owners": ["<owner1>", "<owner2>", "..."],
    "threshold": <threshold>
  },
  "salt": "<salt>",
  "execRolesModFinalOwner": "<admin_address>",
  "oiv": {
    "admin": "<admin_address>",
    "sharesParams": {
      "asset": "<asset_address>",
      "name": "<nombre del fondo>",
      "symbol": "<simbolo>",
      "subscriptionRequestTtl": <ttl_en_segundos>,
      "redemptionRequestTtl": <ttl_en_segundos>,
      "feeReceiver": "<fee_receiver_address>",
      "managementFeeRate": <management_fee_bps>,
      "redemptionFeeRate": <redemption_fee_bps>,
      "performanceFeeModule": "<performance_fee_module_address>",
      "performanceFeeRate": <performance_fee_bps>
    },
    "additionalAssets": [
      {
        "asset": "<asset_address>",
        "canDeposit": true,
        "canRedeem": true
      }
    ]
  },
  "sidechains": ["<chain1>", "<chain2>"]
}
```

Para `stack_only`, omití el objeto `"oiv"` y usá solo las keys comunes.

Guardá el archivo en `script/<slug>-config.json`.

Luego mostrá un resumen formateado de todos los parámetros al usuario:
> "Antes de deployar, revisá la configuración del fondo:
> [mostrar resumen en lenguaje no técnico, convirtiendo bps a % y segundos a días]"

Pedí confirmación:
> "¿Todo está correcto? (sí para continuar, no para corregir algún parámetro)"

Si dice no: preguntá qué quiere corregir y volvé al paso correspondiente.

---

### FASE 9 — Preview de direcciones (solo `full_oiv`)

Antes del deployment, mostrá las direcciones predichas:

Corré:
```
source .env && forge script script/DeployFund.s.sol \
  --sig "predict(string)" "script/<slug>-config.json" \
  --rpc-url $MAINNET_RPC_URL
```

Explicale al usuario:
> "Estas son las direcciones que va a tener el fondo en **todas** las chains (son deterministas).
> Las direcciones del token de shares (kpkShares) no se pueden predecir de antemano."

---

### FASE 10 — Ejecución del deployment

Preguntá:
> "¿Querés ejecutar el deployment ahora, o preferís que te genere los comandos para correrlos manualmente después?"

**Si quiere ejecutar ahora:**

Ejecutá los comandos en este orden:

1. **Mainnet** (si `full_oiv`):
```
source .env && forge script script/DeployFund.s.sol \
  --sig "deployOiv(string)" "script/<slug>-config.json" \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast
```

2. **Cada sidechain** (en orden: arbitrum, base, optimism, gnosis):
```
source .env && forge script script/DeployFund.s.sol \
  --sig "deployStack(string)" "script/<slug>-config.json" \
  --rpc-url $<CHAIN>_RPC_URL \
  --broadcast
```

Después de cada deployment exitoso:
- Mostrá las direcciones desplegadas.
- Confirmá con el usuario antes de continuar con la siguiente chain.
- Si un deployment falla: mostrá el error completo, no continúes con las chains restantes, y pedile al usuario que lo reporte.

**Si prefiere hacerlo manualmente:**

Generá un archivo `script/<slug>-deploy-commands.sh` con todos los comandos listos:

```bash
#!/bin/bash
# Deployment del fondo: <nombre>
# Ejecutá este script desde la raíz del repositorio.
# Asegurate de tener el archivo .env configurado con PRIVATE_KEY y las RPC URLs.

source .env

echo "=== Predicción de direcciones (sin deployment) ==="
forge script script/DeployFund.s.sol \
  --sig "predict(string)" "script/<slug>-config.json" \
  --rpc-url $MAINNET_RPC_URL

# Descomentá las líneas de abajo para ejecutar el deployment:

# echo "=== Deployment en Mainnet (deployOiv) ==="
# forge script script/DeployFund.s.sol \
#   --sig "deployOiv(string)" "script/<slug>-config.json" \
#   --rpc-url $MAINNET_RPC_URL \
#   --broadcast

# echo "=== Deployment en Arbitrum (deployStack) ==="
# forge script script/DeployFund.s.sol \
#   --sig "deployStack(string)" "script/<slug>-config.json" \
#   --rpc-url $ARBITRUM_RPC_URL \
#   --broadcast

# [resto de chains...]
```

Mostrá un mensaje final:
> "Los archivos están listos:
> - `script/<slug>-config.json` — configuración del fondo
> - `script/<slug>-deploy-commands.sh` — comandos de deployment
>
> Cuando estés listo para deployar, ejecutá `bash script/<slug>-deploy-commands.sh`
> o descomentá los comandos de deployment en ese archivo."

---

## Notas para Claude

- Nunca muestres la private key en pantalla. Solo escribila en `.env`.
- El deployer EOA no retiene ningún rol post-deployment. Toda la autoridad queda en `admin` y `managerSafe`.
- El mismo `PRIVATE_KEY` debe usarse para todas las chains para garantizar determinismo de addresses.
- Si el usuario interrumpe el proceso, el archivo de config guardado hasta ese punto se puede retomar.
- Los campos `sharesParams.admin` y `sharesParams.safe` los ignora la factory (los sobreescribe internamente). No los incluyas en el JSON ni los preguntes al usuario.
- Los campos `subRolesMod.finalOwner` y `managerRolesMod.finalOwner` siempre quedan en el Manager Safe (la factory los ignora). No los preguntes al usuario.
- Addresses conocidas en mainnet para referencia rápida:
  - USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
  - USDT: `0xdAC17F958D2ee523a2206206994597C13D831ec7`
  - WETH: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
  - DAI:  `0x6B175474E89094C44Da98b954EedeAC495271d0F`
  - Security Council Safe: `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`
  - KpkOivFactory: `0x0d94255fdE65D302616b02A2F070CdB21190d420`
