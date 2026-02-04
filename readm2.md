# How to Release a New Multiplayer Game (RGS Architecture Guide)

**Author:** Hector Klikailo  
**Updated:** February 4, 2026  
**Version:** 3.0

---

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Implementation Order](#implementation-order)
4. [Phase 1: Game Engine (gaming-service-betbr)](#phase-1-game-engine-gaming-service-betbr)
5. [Phase 2: Database Migrations](#phase-2-database-migrations)
6. [Phase 3: Server Integration (server-betbr)](#phase-3-server-integration-server-betbr)
7. [Phase 4: Client Frontend (client-betbr)](#phase-4-client-frontend-client-betbr)
8. [Phase 5: Admin Panel (admin-betbr)](#phase-5-admin-panel-admin-betbr)
9. [Release Checklist](#release-checklist)
10. [Reference: Lotto Beast Implementation](#reference-lotto-beast-implementation)

---

## Overview

This guide explains how to implement and launch a new **multiplayer game** in Blaze's Remote Gaming Service (RGS).

### Repositories Involved

| Repository | Responsibility |
|------------|----------------|
| `gaming-service-betbr` | Game engine, tick logic, RNG, settlement, validations, workers |
| `gaming-service-pg-controller` | Database migrations, table schemas, enums |
| `server-betbr` | Feature flags, WebSocket bridge, user settings |
| `client-betbr` | Game UI, animations, Redux state, socket handlers |
| `admin-betbr` | Admin panel, release controls, bet debugging |

### NPM Packages to Publish

| Package | Purpose | When to Publish |
|---------|---------|-----------------|
| `@blazecode/gaming-service-pg-controller` | Migrations and schemas | Before deploying gaming-service |
| `@blazecode/subwriter-pg-controller` | Feature flag seeds | Before deploying server-betbr |

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     CLIENT (client-betbr)                        │
│              UI + Animations + Redux + Socket Client             │
└─────────────────────────────┬───────────────────────────────────┘
                              │ WebSocket (Socket.IO)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     SERVER (server-betbr)                        │
│              Feature Flags + Socket Bridge + Settings            │
└─────────────────────────────┬───────────────────────────────────┘
                              │ Redis Pub/Sub
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│               GAMING SERVICE (gaming-service-betbr)              │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐  │
│  │   Game Runner    │  │    Settlement    │  │   REST API    │  │
│  │     Worker       │  │     Worker       │  │  (entry-api)  │  │
│  └────────┬─────────┘  └────────┬─────────┘  └───────┬───────┘  │
│           │                     │                    │          │
│           └─────────────────────┼────────────────────┘          │
│                                 │                               │
│                          ┌──────▼──────┐                        │
│                          │   ENGINE    │                        │
│                          │ (Your Game) │                        │
│                          └─────────────┘                        │
│                                                                  │
│  Shared: PostgreSQL Pool │ Redis │ Core RNG │ Provably Fair     │
└─────────────────────────────────────────────────────────────────┘
```

### Game Tick Lifecycle

1. **Game Runner Worker** calls `engine.executeTick()` every N milliseconds
2. The **tick service** evaluates game state and decides whether to advance
3. States flow: `waiting` → `rolling` → `complete` → (create new game)
4. On `complete`, **settlement** executes immediately (pay winning bets)
5. State is replicated via **Redis pub/sub** → **server-betbr** → **clients**

### State Machine Timing

| State | Description | Duration (Lotto Beast) |
|-------|-------------|------------------------|
| `waiting` | Accepting bets, countdown visible | 15.5 seconds |
| `rolling` | Animation playing, no bets allowed | 12 seconds |
| `complete` | Result shown, settlement triggered | 5 seconds |

---

## Implementation Order

> ⚠️ **CRITICAL:** Follow this order to avoid broken dependencies and enable incremental testing.

```
1. RNG Module (packages/math/{game}/)
   │
   └── WHY FIRST: The engine requires RNG to generate outcomes when
       transitioning to "rolling" state. Without RNG, the game cannot
       produce results.

2. Engine Core (packages/games/engines/{game}-engine/)
   │
   ├── config.js
   │   └── WHY: Defines all parameters (timing, limits, multipliers)
   │       that every other component depends on.
   │
   ├── index.js (Engine Class)
   │   └── WHY: Entry point that wires together RNG, repos, services.
   │       Extends MultiplayerEngine base class.
   │
   ├── repos/ (games-repo.js, bets-repo.js)
   │   └── WHY: Database abstraction layer. Must exist before services
   │       can query or persist data.
   │
   └── services/ (outcomes, marshalling, validator, admin)
       └── WHY: Business logic layer. Depends on repos and config.

3. Workers (packages/games/engines/{game}-engine/workers/)
   │
   ├── game-runner.js
   │   └── WHY: The main game loop. Runs tick execution continuously.
   │       Required to actually "run" the game.
   │
   └── settlement-worker.js
       └── WHY: Handles settlement retries for failed transactions.
           Runs as a separate cron process.

4. Edge Layer Integration (packages/edge/)
   │
   ├── cron-worker.js
   │   └── WHY: Must import and register the settlement worker to
   │       enable automatic retry of failed settlements.
   │
   ├── websockets/replication-sio.js
   │   └── WHY: Must add game room to validRooms array to allow
   │       clients to subscribe to game updates.
   │
   └── entry-api.js (if needed)
       └── WHY: Only if your game needs custom REST endpoints
           beyond the standard multiplayer API.

5. Database Migrations (gaming-service-pg-controller)
   │
   ├── Games table migration
   │   └── WHY: Stores each game round with results. Must include
   │       game-specific columns (e.g., winning_number_1).
   │
   └── Bets table migration (with monthly partitioning)
       └── WHY: Stores all bets. Partitioning is critical for
           query performance at scale.

6. Server Integration (server-betbr)
   │
   ├── Feature flags
   │   └── WHY: Controls gradual rollout. Game should be disabled
   │       by default until ready for production.
   │
   └── WebSocket bridge
       └── WHY: Subscribes to Redis channel and forwards events
           to connected clients.

7. Client Frontend (client-betbr)
   │
   ├── Redux slice
   │   └── WHY: Manages client-side game state.
   │
   ├── Socket handlers
   │   └── WHY: Receives tick updates and triggers Redux actions.
   │
   └── UI Components
       └── WHY: Visual representation of the game.

8. Admin Panel (admin-betbr)
   │
   ├── Game status map
   │   └── WHY: Real-time monitoring of game state.
   │
   └── Bet search
       └── WHY: Customer support and debugging capabilities.
```

---

## Phase 1: Game Engine (gaming-service-betbr)

### 1.1 RNG Module

**Location:** `packages/math/{game}/{game}-rng.js`

**Why first?** The engine calls the RNG function when transitioning from `waiting` to `rolling` state to generate the game outcome.

**What it does:**
- Extends `core-rng.js` which provides 5 deterministic values from a SHA-256 hash
- Maps those values to your game's outcome format
- Must be GLI (Gaming Laboratories International) auditable

**How Lotto Beast implements it:**

The core RNG (`packages/math/core-rng.js`) works as follows:
1. Takes a SHA-256 hash (64 hex characters)
2. Normalizes and extends to 65 characters
3. Splits into 5 segments of 13 hex characters each
4. Converts each segment to a number in range [0, 2^52)

Lotto Beast then maps these to its game range:
```
Core RNG value (0 to 2^52) → value % 10000 → [0, 9999]
```

**Reference file:** `packages/math/lotto-beast/lotto-beast-rng.js`

**Key implementation details:**
- Function: `getLottoBeastRng(hash)` 
- Input: SHA-256 hash string
- Output: Array of 5 numbers in range [0, 9999]
- Uses modulo operation to map core values to game range

---

### 1.2 Engine Configuration

**Location:** `packages/games/engines/{game}-engine/config.js`

**Why?** Every component (engine, services, workers, API) reads configuration from this single source of truth.

**Required fields:**

| Field | Purpose | Lotto Beast Value |
|-------|---------|-------------------|
| `gameType` | Unique identifier used in DB and events | `'lotto_beast'` |
| `gameName` | Human-readable name | `'LottoBeast'` |
| `rooms` | Array of room IDs (usually `[1]`) | `[1]` |
| `roomName` | Socket room name pattern | `'lotto_beast_room_1'` |
| `timing.preRoundMs` | Duration of "waiting" state | `15500` |
| `timing.rollingMs` | Duration of "rolling" state | `12000` |
| `timing.postRoundMs` | Duration of "complete" state | `5000` |
| `timing.tickMs` | Game loop interval | `1000` |
| `limits.minBet` | Minimum bet amount | `0.1` |
| `limits.maxProfit` | Maximum profit per round | `5000000` |
| `multipliers` | Payout multipliers by bet type | See below |
| `database.games` | Games table name | `'lotto_beast_games'` |
| `database.bets` | Bets table name | `'lotto_beast_bets'` |
| `betStatus` | Imported from games-config | Standard statuses |
| `MultiplayerGameEnded` | Domain event name | `'LottoBeastGameEnded'` |

**Lotto Beast multipliers structure:**
```
baseMultipliers:
  full_number: 9200  (match all 4 digits)
  last_3: 920        (match last 3 digits)
  last_2: 92         (match last 2 digits)
  animal: 23         (match animal group)

modeFactors:
  1: 1.0             (just_1st_raffle: 100% of base)
  5: 0.201           (all_5_raffles: 20.1% of base)
```

**Reference file:** `packages/games/engines/lotto-beast-engine/config.js`

---

### 1.3 Main Engine Class

**Location:** `packages/games/engines/{game}-engine/index.js`

**Why?** This is the entry point that wires together all game-specific components and extends the shared `MultiplayerEngine` base class.

**What it must do:**

1. **Extend MultiplayerEngine** - Inherits tick execution, state management, replication
2. **Inject dependencies** - Pass gamesRepo, betsRepo, marshal to parent constructor
3. **Implement required methods:**

| Method | Purpose | Returns |
|--------|---------|---------|
| `buildConfig()` | Provide game configuration | Config object from config.js |
| `getRng()` | Provide RNG function | RNG function reference |
| `getAddGameSpecificFields()` | Custom tick payload fields | Function or undefined |
| `getSettlementFn()` | Settlement logic | Async function |
| `getLimits()` | Bet limits and multipliers | Object with limits + multipliers |

**How Lotto Beast implements it:**

```
Constructor:
  - Requires games-repo, bets-repo, marshalling-service
  - Passes them to super() constructor
  
Static property:
  - GAME_ID = 'lotto-beast'

getSettlementFn():
  - Returns async function that calls processGameSettlement()
  - Passes all required query functions and outcome determiner
  - Settlement happens immediately when game completes
```

**Reference file:** `packages/games/engines/lotto-beast-engine/index.js`

---

### 1.4 Repositories

**Location:** `packages/games/engines/{game}-engine/repos/`

**Why?** Abstraction layer for database operations with game-specific columns.

#### games-repo.js

Uses the factory pattern from `packages/games/repos/games-repo-factory.js`.

**Configuration required:**
- `gameName`: Game identifier
- `table`: Database table name
- `idSeq`: Sequence name for IDs
- `alias`: SQL alias (e.g., 'lg' for lotto_beast_games)
- `selectCols`: Game-specific columns for each query type
- `insertColsAndValues`: Function that returns columns and values for INSERT

**Lotto Beast specific columns:**
- `winning_number_1` through `winning_number_5`
- These are included in SELECT and INSERT operations

**Reference file:** `packages/games/engines/lotto-beast-engine/repos/lotto-beast-games-repo.js`

#### bets-repo.js

Uses the factory pattern from `packages/games/repos/bets-repo-factory.js`.

**Configuration required:**
- `sequence`: Sequence for bet IDs
- `gameFk`: Foreign key column name
- `table.bets`: Bets table name
- `table.games`: Games table name (for JOINs)
- `alias.bets`, `alias.games`: SQL aliases
- `selectCols`: Game-specific columns for each query type
- `insertColsAndValues`: Function for INSERT operations

**Lotto Beast specific columns:**
- `bet_type`: Derived from target (full_number, last_3, last_2, animal)
- `raffle_mode`: just_1st_raffle or all_5_raffles
- `target`: Bet target as string (e.g., "01-02-03-04" for animal)
- `multiplier`, `win_position`: Populated after settlement

**Reference file:** `packages/games/engines/lotto-beast-engine/repos/lotto-beast-bets-repo.js`

---

### 1.5 Services

**Location:** `packages/games/engines/{game}-engine/services/`

#### outcomes-service.js

**Purpose:** Determine which bets won and which lost after a game completes.

**Input:** Array of bets + game data (with results)

**Output:** `{ winningBets, losingBets }`

**Lotto Beast implementation:**
1. Extracts 5 winning numbers from game data
2. For each bet, calls `calculateLottoBetSettlement()`
3. Winning bets get: multiplier, winPosition, actualBetType
4. Losing bets get: multiplier=0, winPosition=null

**Reference file:** `packages/games/engines/lotto-beast-engine/services/lotto-beast-outcomes-service.js`

#### marshalling-service.js

**Purpose:** Format API/socket responses consistently.

**Extends:** `GameMarshalling` from `packages/games/services/marshalling-service.js`

**Methods to override:**
- `marshalGameWithBets()`: Current game + user bets
- `marshalGamesHistory()`: Recent games list
- `marshalUserBetsHistory()`: User's bet history
- `marshalPlaceBetResponse()`: Response after placing bet

**Lotto Beast specifics:**
- Adds `winning_numbers` object with padded 4-digit numbers
- Converts target string to array format
- Includes `server_seed` when game is complete

**Reference file:** `packages/games/engines/lotto-beast-engine/services/lotto-beast-marshalling-service.js`

#### validator-service.js

**Purpose:** Validate bet payloads before accepting bets.

**Exports:**
- `key`: Cache key for validator (e.g., `'game-validator:lotto_beast'`)
- `validateGameSpecificRules(payload, gameConfig)`: Sync validation
- `validateAdditionalRules({...})`: Async validation (duplicate checks, max profit)

**Lotto Beast validations:**
1. `raffle_mode` must be 'all_5_raffles' or 'just_1st_raffle'
2. `target` must be array of length 1 (number bet) or 4 (animal bet)
3. Number bet: target between 0-9999
4. Animal bet: each target between 0-99
5. No duplicate bets (same user + same target + same game)
6. Total potential payout cannot exceed maxProfit

**Reference file:** `packages/games/engines/lotto-beast-engine/services/lotto-beast-validator-service.js`

#### admin-service.js

**Purpose:** Queries for admin panel features.

**Methods:**
- `getRoundById()`: Get full round details
- `getBetsForRound()`: Get all bets for a specific round

**Reference file:** `packages/games/engines/lotto-beast-engine/services/lotto-beast-admin-service.js`

---

### 1.6 Utilities

**Location:** `packages/games/engines/{game}-engine/utils/`

| File | Purpose |
|------|---------|
| `calculations.js` | Payout calculations, win checking, multiplier logic |
| `payload-utils.js` | Parse and normalize bet payloads, deduce bet type |
| `tick-game-specific.js` | Add custom fields to tick payload (e.g., reveal timing) |

**Reference:** `packages/games/engines/lotto-beast-engine/utils/`

---

### 1.7 Workers

**Location:** `packages/games/engines/{game}-engine/workers/`

#### game-runner.js

**Purpose:** Main game loop that executes ticks continuously.

**How it works:**
1. Gets engine instance from `engine-factory.js`
2. Runs infinite loop for each room
3. Calls `engine.executeTick({ db, roomId })` every tick
4. Catches errors without crashing (logs and continues)
5. Uses Datadog APM tracing for monitoring

**Lotto Beast implementation:**
- Sets `DD_SERVICE` to `'lotto-beast-game-runner'`
- Initializes Datadog and registers cleanup handlers
- Loops through configured rooms (usually just `[1]`)
- Sleeps for `timing.tickMs` between ticks

**Production script in package.json:**
```
"prod:lotto-beast-game-server": "node packages/games/engines/lotto-beast-engine/workers/game-runner.js"
```

**Reference file:** `packages/games/engines/lotto-beast-engine/workers/game-runner.js`

#### settlement-worker.js

**Purpose:** Retry failed settlements and pending wallet operations.

**How it works:**
1. Creates engine instance with db pool
2. Calls `processGameSettlement()` to settle any unsettled games
3. Calls `processRetryOperations()` for pending wallet/refund operations
4. Runs every 30 seconds via setTimeout
5. Exports `retrySettleBets` object with `run()` and `stop()` methods

**Integration with cron-worker:**
- Imported in `packages/edge/cron-worker.js`
- Called via `retrySettleLottoBeastBets.run()`

**Reference file:** `packages/games/engines/lotto-beast-engine/workers/settlement-worker.js`

---

### 1.8 Register the Engine

**Location:** `packages/rgs-core/engine-factory.js`

**What to do:**
1. Import your engine class
2. Add to the `engines` map with your game ID as key
3. Engine is instantiated with the shared db pool

**Lotto Beast registration:**
```
const LottoBeastEngine = require('../games/engines/lotto-beast-engine/index.js');

const engines = {
  'lotto-beast': new LottoBeastEngine({ db: dbPool }),
  // ... other engines
};
```

**Reference file:** `packages/rgs-core/engine-factory.js`

---

### 1.9 Edge Layer Integration

#### cron-worker.js

**Location:** `packages/edge/cron-worker.js`

**What to add:**
1. Import settlement worker: `const { retrySettleBets: retrySettleLottoBeastBets } = require('../games/engines/lotto-beast-engine/workers/settlement-worker');`
2. Call `retrySettleLottoBeastBets.run();` in the main body

#### replication-sio.js

**Location:** `packages/edge/websockets/replication-sio.js`

**What to add:**
1. Import config: `const lottoBeastConfig = require('../../games/engines/lotto-beast-engine/config');`
2. Create rooms array: `const lottoBeastRooms = lottoBeastConfig.rooms.map(roomId => \`lotto_beast_room_\${roomId}\`);`
3. Add to `validRooms`: `...lottoBeastRooms`

**Reference file:** `packages/edge/websockets/replication-sio.js`

---

## Phase 2: Database Migrations

**Repository:** `gaming-service-pg-controller`

### Games Table

**Purpose:** Stores each game round with its outcome.

**Standard columns:**
- `id` (UUID, primary key)
- `status` (enum: waiting, rolling, complete)
- `server_roll_id` (for provably fair)
- `multiplayer_game_id` (room ID)
- `created_at`, `updated_at`

**Game-specific columns (Lotto Beast):**
- `winning_number_1` through `winning_number_5` (INTEGER)

### Bets Table

**Purpose:** Stores all user bets.

**Standard columns:**
- `id` (BIGINT, primary key)
- `{game}_game_id` (foreign key to games)
- `user_id` (UUID)
- `amount` (DECIMAL)
- `currency_type` (VARCHAR)
- `target` (VARCHAR or JSONB)
- `status` (enum)
- `payout` (DECIMAL, nullable)
- `created_at`, `updated_at`

**Game-specific columns (Lotto Beast):**
- `bet_type` (VARCHAR: full_number, last_3, last_2, animal)
- `raffle_mode` (VARCHAR: just_1st_raffle, all_5_raffles)
- `multiplier` (DECIMAL)
- `win_position` (INTEGER, nullable)
- `remote_bet_id`, `remote_round_id` (for external integration)
- `free_bet` (BOOLEAN)
- `wallet_id` (UUID)

**Important:** Use monthly partitioning (24 months) for performance.

### Publish

```bash
cd gaming-service-pg-controller
npm version patch
npm publish
```

Then update dependency in gaming-service-betbr.

---

## Phase 3: Server Integration (server-betbr)

### Feature Flags

**Where:** `subwriter-pg-controller` (seeds)

**Flags to add:**
- `{game}_enabled`: Master toggle for game availability
- `{game}_visible`: Whether game appears in lobby
- `{game}_maintenance`: For maintenance mode

### WebSocket Bridge

**What to do:**
1. Subscribe to Redis channel for game updates
2. Forward `{game}:tick` events to subscribed clients
3. Handle room subscription/unsubscription

---

## Phase 4: Client Frontend (client-betbr)

### Folder Structure

```
src/games/{game}/
├── components/          # React components
│   ├── GameCanvas.tsx   # Main game visualization
│   ├── BetPanel.tsx     # Bet placement UI
│   └── History.tsx      # Recent results
├── redux/
│   ├── slice.ts         # Redux toolkit slice
│   ├── selectors.ts     # Memoized selectors
│   └── thunks.ts        # Async actions
├── socket/
│   └── handlers.ts      # Socket event handlers
├── assets/
│   ├── sprites/         # Pixi.js sprites
│   └── sounds/          # Audio files
└── utils/
    └── helpers.ts       # Game-specific utilities
```

### Redux Slice

**State shape:**
- `currentGame`: Current round data
- `userBets`: User's bets in current round
- `recentGames`: Last N results
- `isConnected`: Socket connection status
- `error`: Error state

**Actions:**
- `setCurrentGame`: Update from tick
- `addUserBet`: After bet confirmation
- `setResult`: When game completes

### Socket Events

| Event | Direction | Purpose |
|-------|-----------|---------|
| `{game}:tick` | Server → Client | Update game state |
| `{game}:result` | Server → Client | Final result |
| `{game}:bet:confirmed` | Server → Client | Bet acceptance |
| `{game}:bet:error` | Server → Client | Bet rejection |

---

## Phase 5: Admin Panel (admin-betbr)

### Game Status Map

**What to add:**
- Add game to status overview dashboard
- Show: current round ID, state, time in state, last activity

### Bet Search

**What to add:**
- Search by user ID, round ID, bet ID
- Display bet details: payload, amount, payout, status
- Show round context: winning numbers, timestamp

### Release Controls

**What to add:**
- Toggle for feature flags
- Maintenance mode switch
- Limits adjustment UI

---

## Release Checklist

### Pre-Development
- [ ] Define game rules and payout multipliers
- [ ] Design bet payload structure
- [ ] Get RNG specification approved by compliance/GLI

### Development - Gaming Service
- [ ] Implement RNG (`packages/math/{game}/`)
- [ ] Create `config.js`
- [ ] Create Engine class extending MultiplayerEngine
- [ ] Implement games-repo with factory
- [ ] Implement bets-repo with factory
- [ ] Implement outcomes-service
- [ ] Implement marshalling-service
- [ ] Implement validator-service
- [ ] Create game-runner worker
- [ ] Create settlement-worker
- [ ] Register engine in engine-factory.js
- [ ] Add to cron-worker.js
- [ ] Add room to replication-sio.js
- [ ] Add production script to package.json
- [ ] Write unit tests
- [ ] Write integration tests

### Development - Database
- [ ] Create games table migration
- [ ] Create bets table migration (with partitioning)
- [ ] Add necessary enums
- [ ] Publish @blazecode/gaming-service-pg-controller

### Development - Server
- [ ] Add feature flag seeds
- [ ] Configure WebSocket bridge
- [ ] Publish @blazecode/subwriter-pg-controller

### Development - Client
- [ ] Create Redux slice
- [ ] Implement socket handlers
- [ ] Build UI components
- [ ] Implement animations
- [ ] Add routing
- [ ] Write component tests

### Development - Admin
- [ ] Add to status map
- [ ] Implement bet search
- [ ] Add release controls

### Testing
- [ ] Unit tests passing
- [ ] Integration tests passing
- [ ] QA on staging environment
- [ ] Load test game runner
- [ ] Verify settlement under load

### Deployment
- [ ] Deploy gaming-service-betbr
- [ ] Deploy server-betbr
- [ ] Deploy client-betbr
- [ ] Deploy admin-betbr
- [ ] Enable feature flags gradually
- [ ] Monitor Datadog metrics

### Post-Launch
- [ ] Monitor Sentry for errors
- [ ] Check settlement success rate
- [ ] Review failed settlement logs
- [ ] Document operational runbooks

---

## Reference: Lotto Beast Implementation

### File Structure

```
packages/games/engines/lotto-beast-engine/
├── index.js                              # LottoBeastEngine class
├── config.js                             # Game configuration
├── repos/
│   ├── lotto-beast-games-repo.js         # Games repository (factory)
│   └── lotto-beast-bets-repo.js          # Bets repository (factory)
├── services/
│   ├── lotto-beast-outcomes-service.js   # Win/lose determination
│   ├── lotto-beast-marshalling-service.js # Response formatting
│   ├── lotto-beast-validator-service.js  # Bet validation
│   └── lotto-beast-admin-service.js      # Admin queries
├── utils/
│   ├── calculations.js                   # Payout math
│   ├── payload-utils.js                  # Payload processing
│   └── tick-game-specific.js             # Tick field additions
└── workers/
    ├── game-runner.js                    # Main game loop
    └── settlement-worker.js              # Retry settlement

packages/math/lotto-beast/
└── lotto-beast-rng.js                    # RNG implementation
```

### Integration Points Summary

| File | What to Add |
|------|-------------|
| `packages/rgs-core/engine-factory.js` | `'lotto-beast': new LottoBeastEngine({ db: dbPool })` |
| `packages/edge/cron-worker.js` | Import and call `retrySettleLottoBeastBets.run()` |
| `packages/edge/websockets/replication-sio.js` | Add `lottoBeastRooms` to `validRooms` array |
| `package.json` | Add `prod:lotto-beast-game-server` script |

### Key Patterns Used

| Pattern | Where | Why |
|---------|-------|-----|
| Factory | Repos | Reuse common DB operations with game-specific config |
| Inheritance | Engine | Share tick/state logic via MultiplayerEngine |
| Strategy | Settlement | Pluggable outcome determination per game |
| Dependency Injection | Engine constructor | Testability and flexibility |

---

## Troubleshooting

| Problem | What to Check |
|---------|---------------|
| Game runner won't start | Engine registered in engine-factory.js? buildConfig() returns valid config? |
| Ticks not reaching clients | Room added to replication-sio.js validRooms? Redis pub/sub connected? |
| Settlement not processing | getSettlementFn() implemented? outcomes-service returns correct structure? |
| Bets being rejected | validator-service rules correct? Payload structure matches expectations? |
| Wrong payouts | calculations.js multipliers correct? outcomes-service logic correct? |

---

*Last updated: February 2026*
