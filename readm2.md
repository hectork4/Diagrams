# Guía para Lanzar un Nuevo Juego Multiplayer (RGS)

**Autor:** Hector Klikailo  
**Actualizado:** 4 de febrero de 2026  
**Versión:** 3.0

---

## Índice

1. [Visión General](#visión-general)
2. [Arquitectura del Sistema](#arquitectura-del-sistema)
3. [Orden de Implementación](#orden-de-implementación)
4. [Fase 1: Engine del Juego](#fase-1-engine-del-juego-gaming-service-betbr)
5. [Fase 2: Migraciones de Base de Datos](#fase-2-migraciones-de-base-de-datos)
6. [Fase 3: Integración con Server](#fase-3-integración-con-server-server-betbr)
7. [Fase 4: Cliente Frontend](#fase-4-cliente-frontend-client-betbr)
8. [Fase 5: Panel de Admin](#fase-5-panel-de-admin-admin-betbr)
9. [Checklist de Release](#checklist-de-release)
10. [Referencia: Lotto Beast](#referencia-lotto-beast)

---

## Visión General

Esta guía explica cómo implementar y lanzar un nuevo juego **multiplayer** en el RGS de Blaze. 

### Repositorios Involucrados

| Repositorio | Responsabilidad |
|-------------|-----------------|
| gaming-service-betbr | Engine del juego, lógica de ticks, RNG, settlement, validaciones |
| gaming-service-pg-controller | Migraciones de BD, schemas de tablas, enums |
| server-betbr | Feature flags, bridge de WebSockets, configuraciones |
| client-betbr | UI del juego, animaciones, estado Redux, handlers de socket |
| admin-betbr | Panel de administración, controles de release, debugging |

### Paquetes NPM a Publicar

| Paquete | Propósito | Cuándo Publicar |
|---------|-----------|-----------------|
| @blazecode/gaming-service-pg-controller | Migraciones y schemas | Antes de deployar gaming-service |
| @blazecode/subwriter-pg-controller | Seeds de feature flags | Antes de deployar server-betbr |

---

## Arquitectura del Sistema

```
CLIENT (client-betbr)
    UI + Animaciones + Redux + Socket Client
                    │ WebSocket
                    ▼
SERVER (server-betbr)
    Feature Flags + Socket Bridge + Settings
                    │ Redis Pub/Sub
                    ▼
GAMING SERVICE (gaming-service-betbr)
    ┌──────────────┬──────────────┬──────────────┐
    │ Game Runner  │  Settlement  │   REST API   │
    │   Worker     │   Worker     │              │
    └──────────────┴──────────────┴──────────────┘
                    │
             ┌──────▼──────┐
             │   ENGINE    │
             │ (Tu juego)  │
             └─────────────┘
```

### Ciclo de Vida de un Tick

1. **Game Runner** ejecuta engine.executeTick() cada N milisegundos
2. El **tick** evalúa el estado del juego y decide si avanzar
3. Estados: waiting → rolling → complete → (nuevo juego)
4. Al completar, se ejecuta **settlement** (pagar apuestas)
5. Se replica el estado via **Redis pub/sub** → **server-betbr** → **clientes**

---

## Orden de Implementación

> ⚠️ **IMPORTANTE:** Seguir este orden evita dependencias rotas.

```
1. RNG (packages/math/)
   └── El engine lo necesita para generar resultados
   
2. Engine Core (packages/games/engines/{game}-engine/)
   ├── config.js         → Tiempos, límites, multiplicadores
   ├── index.js          → Clase principal (extiende MultiplayerEngine)
   ├── repos/            → Acceso a BD (games y bets)
   └── services/         → Outcomes, marshalling, validación
   
3. Workers
   ├── game-runner.js    → Loop principal del juego
   └── settlement-worker.js → Reintentos de settlement
   
4. Integración Edge
   ├── cron-worker.js    → Registrar el settlement worker
   ├── replication-sio.js → Agregar room de WebSocket
   └── entry-api.js      → Endpoints REST (si necesarios)
   
5. Migraciones BD (gaming-service-pg-controller)
   ├── Tabla de games    → Con campos específicos del juego
   └── Tabla de bets     → Con particionamiento mensual
   
6. Server-betbr
   ├── Feature flags     → Para controlar el rollout
   └── WebSocket bridge  → Suscripción al canal del juego
   
7. Client-betbr
   ├── Componentes UI    → Pantalla del juego
   ├── Redux slice       → Estado y actions
   └── Socket handlers   → Recibir updates del servidor
   
8. Admin-betbr
   ├── Status map        → Ver estado del juego
   └── Bet search        → Debugging de apuestas
```

---

## Fase 1: Engine del Juego (gaming-service-betbr)

### 1.1 RNG (Random Number Generator)

**Ubicación:** packages/math/{game}/{game}-rng.js

**¿Por qué primero?** El engine necesita el RNG para generar resultados cuando el juego pasa a estado "rolling".

**¿Qué hace?**
- Extiende core-rng.js que provee 5 valores determinísticos desde un hash SHA-256
- Mapea esos valores al formato de resultado de tu juego
- Debe ser auditable por GLI

**Referencia:** packages/math/lotto-beast/lotto-beast-rng.js

---

### 1.2 Configuración del Engine

**Ubicación:** packages/games/engines/{game}-engine/config.js

**¿Por qué?** Define todos los parámetros que el engine y servicios necesitan.

**Qué debe incluir:**

| Campo | Descripción | Ejemplo |
|-------|-------------|---------|
| gameType | Identificador único | 'lotto_beast' |
| timing.preRoundMs | Duración estado "waiting" | 15500 |
| timing.rollingMs | Duración estado "rolling" | 12000 |
| timing.postRoundMs | Pausa post-complete | 5000 |
| timing.tickMs | Frecuencia del loop | 1000 |
| limits.minBet | Apuesta mínima | 0.1 |
| limits.maxBet | Apuesta máxima | 10000 |
| limits.maxProfit | Ganancia máxima por ronda | 5000000 |
| multipliers | Multiplicadores de pago | { full_number: 9200 } |

**Referencia:** packages/games/engines/lotto-beast-engine/config.js

---

### 1.3 Clase Principal del Engine

**Ubicación:** packages/games/engines/{game}-engine/index.js

**¿Por qué?** Es el punto de entrada que conecta todas las piezas.

**Qué debe hacer:**
- Extender MultiplayerEngine
- Inyectar repositorios (gamesRepo, betsRepo) y marshalling
- Implementar métodos:

| Método | Propósito |
|--------|-----------|
| buildConfig() | Retornar la configuración |
| getRng() | Retornar la función RNG |
| getAddGameSpecificFields() | Campos custom al tick (opcional) |
| getSettlementFn() | Función de settlement |
| getLimits() | Límites y multiplicadores |

**Referencia:** packages/games/engines/lotto-beast-engine/index.js

---

### 1.4 Repositorios

**Ubicación:** packages/games/engines/{game}-engine/repos/

**¿Por qué?** Abstraen el acceso a BD con campos específicos del juego.

| Archivo | Propósito |
|---------|-----------|
| games-repo.js | CRUD de rondas, usa factory gamesRepository |
| bets-repo.js | CRUD de apuestas, usa factory betsRepository |

**Referencia:** packages/games/engines/lotto-beast-engine/repos/

---

### 1.5 Servicios

**Ubicación:** packages/games/engines/{game}-engine/services/

| Servicio | Propósito |
|----------|-----------|
| outcomes-service.js | Determina ganadores/perdedores, calcula payouts |
| marshalling-service.js | Formatea respuestas de API/ticks |
| validator-service.js | Valida estructura y reglas de apuestas |
| admin-service.js | Queries para panel admin |

**Referencia:** packages/games/engines/lotto-beast-engine/services/

---

### 1.6 Utilidades

**Ubicación:** packages/games/engines/{game}-engine/utils/

| Archivo | Propósito |
|---------|-----------|
| calculations.js | Cálculos de pagos, house edge |
| payload-utils.js | Parseo de payloads de apuestas |
| tick-game-specific.js | Campos adicionales para el tick |

---

### 1.7 Workers

**Ubicación:** packages/games/engines/{game}-engine/workers/

| Worker | Propósito |
|--------|-----------|
| game-runner.js | Loop infinito que ejecuta ticks |
| settlement-worker.js | Reintenta settlements fallidos |

**Referencia:** packages/games/engines/lotto-beast-engine/workers/

---

### 1.8 Registrar el Engine

**Ubicación:** packages/rgs-core/engine-factory.js

- Importar tu engine
- Agregarlo al map de engines

---

### 1.9 Integración Edge Layer

| Archivo | Qué hacer |
|---------|-----------|
| packages/edge/cron-worker.js | Importar y agregar retry del settlement worker |
| packages/edge/websockets/replication-sio.js | Agregar room al array validRooms |
| packages/edge/entry-api.js | Solo si necesitas endpoints custom |

---

## Fase 2: Migraciones de Base de Datos

**Repositorio:** gaming-service-pg-controller

### Tabla de Games
- Campos: id, status, hash, created_at, updated_at
- **+ campos específicos del juego** (ej: winning_number_1)

### Tabla de Bets
- Campos: id, game_id, user_id, bet_payload, amount, payout, status, created_at
- **Usar particionamiento mensual** (24 meses)

### Publicar
```bash
npm version patch && npm publish
```
Luego actualizar dependencia en gaming-service-betbr.

---

## Fase 3: Integración con Server (server-betbr)

### Feature Flags
- Agregar seeds en subwriter-pg-controller
- Flags: {game}_enabled, {game}_visible

### WebSocket Bridge
- Suscribirse al canal del juego
- Reenviar eventos a clientes conectados

---

## Fase 4: Cliente Frontend (client-betbr)

### Estructura
```
src/games/{game}/
├── components/    # Componentes React
├── redux/         # Slice, actions, reducers
├── socket/        # Handlers de socket
└── assets/        # Sprites, sonidos
```

### Socket Events
- {game}:tick → Actualizar estado
- {game}:result → Mostrar resultado
- {game}:bet:confirmed → Confirmar apuesta

---

## Fase 5: Panel de Admin (admin-betbr)

| Componente | Propósito |
|------------|-----------|
| Game Status Map | Ver estado en tiempo real |
| Bet Search | Debugging y soporte |
| Release Controls | Toggle de feature flags |

---

## Checklist de Release

### Pre-Development
- [ ] Definir reglas y multiplicadores
- [ ] Diseñar estructura del payload
- [ ] Specs de RNG aprobados

### Gaming Service
- [ ] RNG (packages/math/{game}/)
- [ ] config.js
- [ ] Engine class (index.js)
- [ ] Repositorios
- [ ] Services (outcomes, marshalling, validator)
- [ ] Workers (game-runner, settlement)
- [ ] Registrar en engine-factory.js
- [ ] Integrar con cron-worker.js
- [ ] Agregar room en replication-sio.js
- [ ] Tests

### Database
- [ ] Migración tabla games
- [ ] Migración tabla bets (particionada)
- [ ] Publicar pg-controller

### Server
- [ ] Feature flags
- [ ] WebSocket bridge

### Client
- [ ] Redux slice
- [ ] Socket handlers
- [ ] Componentes UI
- [ ] Routing

### Admin
- [ ] Status map
- [ ] Bet search

### Deployment
- [ ] Deploy gaming-service
- [ ] Deploy server
- [ ] Deploy client
- [ ] Deploy admin
- [ ] Activar flags gradualmente
- [ ] Monitorear Datadog

---

## Referencia: Lotto Beast

### Estructura
```
packages/games/engines/lotto-beast-engine/
├── index.js          # Engine class
├── config.js         # Configuración
├── repos/            # games-repo, bets-repo
├── services/         # outcomes, marshalling, validator, admin
├── utils/            # calculations, payload-utils, tick-game-specific
└── workers/          # game-runner, settlement-worker

packages/math/lotto-beast/
└── lotto-beast-rng.js
```

### Puntos de Integración

| Archivo | Qué agregar |
|---------|-------------|
| packages/rgs-core/engine-factory.js | 'lotto-beast': LottoBeastEngine |
| packages/edge/cron-worker.js | import retrySettleLottoBeastBets |
| packages/edge/websockets/replication-sio.js | lottoBeastRooms en validRooms |

---

## Troubleshooting

| Problema | Verificar |
|----------|-----------|
| Game runner no inicia | Engine registrado en engine-factory.js, buildConfig() válido |
| Ticks no llegan a clientes | Room en replication-sio.js, suscripción Redis |
| Settlement no procesa | getSettlementFn() implementado, outcomes-service correcto |
| Apuestas rechazadas | validator-service, estructura del payload |

---

*Última actualización: Febrero 2026*
