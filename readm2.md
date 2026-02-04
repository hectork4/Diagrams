# How to Release a New Game (RGS Architecture Guide)

**Author:** Hector Klikailo  
**Updated:** February 4, 2026  
**Version:** 2.0

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Overview](#architecture-overview)
3. [Repository Roles and Responsibilities](#repository-roles-and-responsibilities)
4. [Required NPM Packages](#required-npm-packages)
5. [Step-by-Step Implementation Guide](#step-by-step-implementation-guide)
   - [Phase 1: Engine Implementation (gaming-service-betbr)](#phase-1-engine-implementation-gaming-service-betbr)
   - [Phase 2: Database Migrations](#phase-2-database-migrations-gaming-service-pg-controller)
   - [Phase 3: Server Wiring (server-betbr)](#phase-3-server-wiring-server-betbr)
   - [Phase 4: Client Implementation (client-betbr)](#phase-4-client-implementation-client-betbr)
   - [Phase 5: Admin Panel (admin-betbr)](#phase-5-admin-panel-admin-betbr)
6. [Complete File Structure Template](#complete-file-structure-template)
7. [Code Templates with Examples](#code-templates-with-examples)
8. [Integration Points Checklist](#integration-points-checklist)
9. [Release Flow & Deployment](#release-flow--deployment)
10. [Testing Strategy](#testing-strategy)
11. [Troubleshooting Guide](#troubleshooting-guide)
12. [Reference Implementation: Lotto Beast](#reference-implementation-lotto-beast)

---

## Overview

This guide provides practical, end-to-end steps to add and launch a new **multiplayer game** in Blaze's Remote Gaming Service (RGS). It covers all repositories:

- `gaming-service-betbr` - Game engine & backend
- `server-betbr` - Feature flags & socket bridge
- `client-betbr` - Frontend UI
- `admin-betbr` - Admin panel

> ⚠️ **Note:** This guide is for multiplayer RGS games only. It does NOT cover single-player games (bet-slip based) or third-party provider integrations.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CLIENT (client-betbr)                            │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │   Game Canvas   │  │   Redux Store   │  │  Socket Client  │         │
│  │   (Pixi/Spine)  │  │    (State)      │  │  (Socket.IO)    │         │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘         │
└───────────┼─────────────────────┼─────────────────────┼─────────────────┘
            │                     │                     │
            │                     ▼                     │
            │         ┌─────────────────────┐           │
            │         │    server-betbr     │           │
            │         │  (Feature Flags &   │◄──────────┘
            │         │   Socket Bridge)    │
            │         └──────────┬──────────┘
            │                    │
            ▼                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    gaming-service-betbr (RGS Core)                       │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │
│  │  REST API    │  │ Game Runner  │  │  Settlement  │  │  Message    │  │
│  │  (entry-api) │  │   Worker     │  │   Worker     │  │   Queue     │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬──────┘  │
│         │                 │                 │                 │         │
│         ▼                 ▼                 ▼                 ▼         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    Game Engine (MultiplayerEngine)                │  │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────────┐  │  │
│  │  │  config.js │ │  repos/*   │ │ services/* │ │ utils/*        │  │  │
│  │  │            │ │ games-repo │ │ outcomes   │ │ calculations   │  │  │
│  │  │            │ │ bets-repo  │ │ marshalling│ │ tick-specific  │  │  │
│  │  └────────────┘ └────────────┘ └────────────┘ └────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                      Shared Services                               │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌─────────────┐  │  │
│  │  │  Core RNG  │  │  Provably  │  │  Postgres  │  │   Redis     │  │  │
│  │  │            │  │   Fair     │  │   Pool     │  │  (pub/sub)  │  │  │
│  │  └────────────┘  └────────────┘  └────────────┘  └─────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Flow: Game Tick Lifecycle

```
1. Game Runner Worker starts tick loop
   │
2. executeTickService() called every config.timing.tickMs
   │
3. Check game state timing via shouldAdvanceGameState()
   │
   ├── WAITING → Check if preRoundMs elapsed → ROLLING
   │
   ├── ROLLING → Check if rollingMs elapsed → COMPLETE
   │                                           │
   │                                           ├── Execute settlement (immediate)
   │                                           └── Emit MultiplayerGameEnded event
   │
   └── COMPLETE → Check if postRoundMs elapsed → Create new game
   │
4. replicateGameUpdate() sends tick via Redis pub/sub
   │
5. server-betbr receives and broadcasts to connected clients
```

---

## Repository Roles and Responsibilities

| Repository | Role | Key Components |
|------------|------|----------------|
| **gaming-service-betbr** | Game engine, ticks, RNG, settlement, limits, marshalling | Engine classes, workers, repos, services |
| **server-betbr** | Feature flags, waitlist, settings, Socket.IO bridge | Feature status seeds, waitlist constants, socket channels |
| **client-betbr** | Game UI/animations, Redux state, socket handlers, routing | React components, Pixi/Spine canvas, Redux logic |
| **admin-betbr** | Release controls, health/status, bet search/debugging | Game status map, bet search forms |

---

## Required NPM Packages

| Package | Purpose | When to Publish |
|---------|---------|-----------------|
| `@blazecode/gaming-service-pg-controller` | Game/bet schemas, enums, migrations, seeds | Before gaming-service-betbr deploy |
| `@blazecode/subwriter-pg-controller` | feature_status and waitlist seeds | Before server-betbr deploy |
| `@blazecode/oltp-pg-controller` (legacy) | Generic settings | Only if needed |

---

## Step-by-Step Implementation Guide

### Phase 1: Engine Implementation (gaming-service-betbr)

#### 1.1 Create Engine Directory Structure

```
packages/games/engines/{game}-engine/
├── index.js                          # Main engine class
├── config.js                         # Game configuration
├── repos/
│   ├── {game}-games-repo.js          # Games table repository
│   └── {game}-bets-repo.js           # Bets table repository
├── services/
│   ├── {game}-outcomes-service.js    # Settlement/win determination
│   ├── {game}-marshalling-service.js # API response formatting
│   ├── {game}-validator-service.js   # Bet validation rules
│   └── {game}-admin-service.js       # Admin panel queries
├── utils/
│   ├── calculations.js               # Game math/multipliers
│   ├── payload-utils.js              # Bet payload processing
│   └── tick-game-specific.js         # Custom tick fields
├── workers/
│   ├── game-runner.js                # Main game loop
│   └── settlement-worker.js          # Settlement retry worker
├── infra/
│   └── {game}-message-queue-interface.js  # Message queue handlers
└── tests/
    ├── {game}-e2e-integration.spec.js
    ├── {game}-validator-service.spec.js
    ├── settlement-validation.spec.js
    └── engine-validation.test.js
```

#### 1.2 Create the RNG Module

**Location:** `packages/math/{game}/{game}-rng.js`

The RNG module extends the Core RNG (`packages/math/core-rng.js`) which provides 5 deterministic values from a SHA-256 hash. Each game maps these values to its specific outcome format.

```javascript
/**
 * {Game} RNG - GLI Auditable RNG Extension
 *
 * Converts SHA-256 hash into deterministic game outcome.
 * Extends core RNG which divides hash into 5 segments of 13 hex chars each.
 *
 * Specification:
 * - Input: SHA-256 hash (64 hex characters)
 * - Output: Game-specific outcome
 * - Uses core RNG values [0, 2^52) mapped to game range
 *
 * @see Documentation: https://blazeltd.atlassian.net/wiki/spaces/SA/pages/1533313026/New+RNG
 */

const { generateCoreRngValues } = require('../core-rng');

/**
 * Get {game} outcome from SHA-256 hash
 * @param {string} hash - SHA-256 hash (64 hex characters)
 * @returns {YourOutcomeType} - Game-specific outcome
 */
const get{Game}Rng = (hash) => {
  // Get 5 core RNG values (each in range [0, 2^52))
  const rngValues = generateCoreRngValues(hash);

  // Map values to your game's outcome format
  // Example for numbers in range [0, 9999]:
  // const outcome = rngValues.map((value) => value % 10000);

  return outcome;
};

module.exports = { get{Game}Rng };
```

**Core RNG Reference:**
```javascript
// packages/math/core-rng.js
// Generates 5 values in range [0, 2^52) from SHA-256 hash
// Process:
// 1. Normalize hash to 64 hex characters
// 2. Extend hash by copying first char (65 chars total)
// 3. Divide into 5 segments of 13 hex chars each
// 4. Convert each segment to decimal
```

#### 1.3 Create Main Engine Class (index.js)

```javascript
const { MultiplayerEngine } = require('../multiplayer-engine.js');
const { get{Game}Rng } = require('../../../math/{game}/{game}-rng.js');
const { addGameSpecificFields } = require('./utils/tick-game-specific.js');
const { processGameSettlement } = require('../../services/game-settlement-service');
const { determine{Game}BetOutcomes } = require('./services/{game}-outcomes-service');

class {Game}Engine extends MultiplayerEngine {
  static GAME_ID = '{game-slug}';  // e.g., 'lotto-beast'

  constructor(options) {
    const gamesRepo = require('./repos/{game}-games-repo');
    const betsRepo = require('./repos/{game}-bets-repo');
    const marshal = require('./services/{game}-marshalling-service.js');

    super({
      ...options,
      gamesRepo,
      betsRepo,
      marshal,
    });
  }

  // Required: Return game configuration
  buildConfig() {
    return require('./config.js');
  }

  // Required: Return RNG function
  getRng() {
    return get{Game}Rng;
  }

  // Optional: Add game-specific fields to tick payload
  getAddGameSpecificFields() {
    return addGameSpecificFields;
  }

  // Optional: Override to add game-specific limits
  async getLimits() {
    return {
      ...this.config.limits,
      // Add game-specific limits like multipliers
    };
  }

  // Optional: Return settlement function for immediate settlement
  getSettlementFn() {
    const gamesRepo = this.gamesRepo;
    const betsRepo = this.betsRepo;
    const gameConfig = this.config;

    return async ({ db, gameId }) => {
      await processGameSettlement({
        db: { master: db, begin: db.begin?.bind(db) || this.db.begin.bind(this.db) },
        gameConfig,
        getGamesToSettleQuery: () => Promise.resolve([{ id: gameId }]),
        getGameByIdQuery: gamesRepo.getGameById,
        getBetsForSettlementQuery: betsRepo.getBetsForSettlement,
        getBetsForSettlementByIdsQuery: betsRepo.getBetsForSettlementByIds,
        updateBetStatusQuery: betsRepo.updateBetStatusWithOutcomes,
        determineBetOutcomes: determine{Game}BetOutcomes,
      });
    };
  }
}

module.exports = {Game}Engine;
```

#### 1.4 Create Game Configuration (config.js)

```javascript
const { betStatus } = require('../../games-config');

const rooms = [1];  // Array of room IDs (usually just [1] for single room)

module.exports = {
  // === Identity ===
  gameType: '{game_type}',           // DB enum value, e.g., 'lotto_beast'
  gameName: '{GameName}',            // Display name, e.g., 'LottoBeast'
  version: '1.0.0',
  remoteId: 'blaze:{game}',

  // === Rooms ===
  rooms,
  roomName: '{game}_room_1',         // Primary room name (matches multiplayer_games.game)
  {game}Rooms: rooms.map(roomId => `{game}_room_${roomId}`),

  // === Bet Parameters ===
  // These are extracted from bet payload and stored in the bets table
  betParams: ['target', /* other game-specific params */],

  // === Limits (BRL currency) ===
  limits: {
    minBet: 0.1,
    maxProfit: 5000000,       // Maximum profit per round
    defaultMaxBet: 277777.78, // Default max bet amount
  },

  // === Rules ===
  rules: {
    maxBetsPerRound: 50,      // Max bets per user per round
  },

  // === Game-specific multipliers (if applicable) ===
  multipliers: {
    // Define your multiplier structure based on game mechanics
    // Example:
    // baseMultipliers: { type_a: 100, type_b: 50 },
    // modeFactors: { mode_1: 1.0, mode_2: 0.5 },
  },

  // === Database Configuration ===
  database: {
    games: '{game}_games',
    bets: '{game}_bets',
    gameIdColumn: '{game}_game_id',
    betSequence: '{game}_bets_id_seq',
  },

  // === Timing (milliseconds) ===
  timing: {
    preRoundMs: 15500,     // Betting window (time in WAITING status)
    rollingMs: 12000,      // Animation/reveal phase (time in ROLLING status)
    postRoundMs: 5000,     // Results display (time in COMPLETE status)
    tickMs: 1000,          // Tick interval (how often executeTick runs)
    // Add game-specific timing like revealIntervalMs if needed
  },

  // === Status Values ===
  status: {
    WAITING: 'waiting',    // Accepting bets
    ROLLING: 'rolling',    // Game in progress/animation
    COMPLETE: 'complete',  // Results shown, settlement done
  },

  betStatus, // Imported from games-config.js

  // === Event Names (for message queue) ===
  MultiplayerGameEnded: '{GameName}GameEnded',      // e.g., 'LottoBeastGameEnded'
  Multi{Game}BetResulted: 'Multi{Game}BetResulted',

  // === Remote ID Generators ===
  // Used for wallet integration and external tracking
  getRemoteId: (roomId) => `blaze:{game}-${roomId}`,
  getLegacyRemoteId: (remote_round_id, roomId = 1) => `blaze:{game}-${roomId}-bet-gs-${remote_round_id}`,
};
```

#### 1.5 Create Games Repository

**File:** `repos/{game}-games-repo.js`

The games repository uses the factory pattern from `games-repo-factory.js` which provides common operations. You customize it by defining table-specific columns and insert logic.

```javascript
const { gamesRepository } = require('../../../repos/games-repo-factory');

module.exports = gamesRepository({
  gameName: '{game}',                    // e.g., 'lotto_beast'
  table: '{game}_games',
  idSeq: '{game}_games_id_seq',
  alias: 'gg',                           // Short alias for SQL queries
  
  // Define which columns to select for each operation
  selectCols: {
    currentGame: 'outcome_col_1, outcome_col_2, outcome_col_3',
    recentGames: 'outcome_col_1, outcome_col_2, outcome_col_3',
    gamesHistory: 'gg.outcome_col_1, gg.outcome_col_2, gg.outcome_col_3',
    gameById: 'gg.outcome_col_1, gg.outcome_col_2, gg.outcome_col_3',
  },
  
  // Define how to insert a new game
  insertColsAndValues: ({ id, now, rollId, roomId, rngOutcome }) => {
    // Extract values from rngOutcome array (returned by your RNG function)
    const [val1, val2, val3] = rngOutcome || [null, null, null];

    return {
      columns: [
        'id',
        'status',
        'outcome_col_1',
        'outcome_col_2',
        'outcome_col_3',
        'created_at',
        'updated_at',
        'server_roll_id',
        'multiplayer_game_id',
      ],
      values: [id, 'waiting', val1, val2, val3, now, now, rollId, roomId],
    };
  },
});
```

**Available methods from factory:**
- `getMultiplayerGameId({ db, roomId })` - Get multiplayer_games.id for a room
- `getCurrentGame({ db, multiplayerGameId })` - Get current active game
- `getRecentGames({ db, limit })` - Get recent completed games
- `getPaginatedGamesHistory({ db, multiplayerGameId, limit, offset })`
- `getGameById({ db, gameId })` - Get specific game with all details
- `createNewGame(db, roomId, rollId, rngOutcome)` - Create new game
- `updateGameStatus(db, gameId, status)` - Update game status

#### 1.6 Create Bets Repository

**File:** `repos/{game}-bets-repo.js`

```javascript
const moment = require('moment');
const { betsRepository } = require('../../../repos/bets-repo-factory');

const betsFactoryRepo = betsRepository({
  sequence: '{game}_bets_id_seq',
  gameFk: '{game}_game_id',
  table: {
    bets: '{game}_bets',
    games: '{game}_games',
  },
  alias: {
    bets: 'gb',
    games: 'gg',
  },
  
  // Define columns for each query type
  selectCols: {
    currentUserBets: 'bet_param_1, bet_param_2',
    betsForGameById: 'gb.bet_param_1, gb.bet_param_2, gg.outcome_col_1',
    userBetsHistory: 'gb.bet_param_1, gb.multiplier, gg.outcome_col_1',
    betsForSettlement: 'gb.bet_param_1, gb.multiplier, gg.outcome_col_1, gg.multiplayer_game_id',
    betsForSettlementByIds: 'target, bet_param_1, remote_round_id',
  },
  
  // Define how to insert a new bet
  insertColsAndValues: ({ betId, gameId, payload, amount, currency, status, remoteBetId = null, now }) => {
    const { user_id, target, bet_param_1, free_bet = false, wallet_id = null } = payload;

    return {
      columns: [
        'id',
        '{game}_game_id',
        'user_id',
        'amount',
        'currency_type',
        'target',
        'bet_param_1',
        'status',
        'created_at',
        'updated_at',
        'free_bet',
        'remote_bet_id',
        'wallet_id',
      ],
      values: [
        betId,
        gameId,
        user_id,
        amount,
        currency,
        target,
        bet_param_1,
        status,
        now,
        now,
        free_bet,
        remoteBetId,
        wallet_id,
      ],
    };
  },
});

// ============================================
// CUSTOM METHODS (add game-specific queries)
// ============================================

/**
 * Get all bets for a game (used for tick replication)
 */
const getAllBets = async (db, game, config) => {
  const { id: gameId } = game;
  const { betStatus } = config;
  const { PLACED, PAYOUT, LOST, PENDING_WALLET } = betStatus;

  const statusList = [PLACED, PAYOUT, LOST, PENDING_WALLET];

  const query = `
    WITH gameBets AS (
      SELECT 
        gb.id as entry_id,
        gb.user_id,
        gb.amount,
        gb.currency_type,
        gb.target,
        gb.bet_param_1,
        gb.free_bet,
        gb.created_at,
        CASE
          WHEN gb.status = 'payout' THEN 'win'
          WHEN gb.status = 'lost' THEN 'loss'
          ELSE gb.status
        END as bet_status,
        CASE
          WHEN gb.status = 'payout' AND gb.multiplier IS NOT NULL
          THEN gb.amount * gb.multiplier
          ELSE 0
        END as win_amount,
        gb.multiplier,
        p.username,
        p.rank as user_rank,
        true as show_username
      FROM {game}_bets gb
      LEFT JOIN players p ON p.user_id = gb.user_id
      WHERE gb.{game}_game_id = $1 AND gb.status = ANY($2)
    )
    SELECT
      COALESCE(json_agg(row_to_json(gameBets.*)), '[]'::json) as bets,
      COALESCE(COUNT(*), 0) as total_bets_placed,
      COALESCE(SUM(amount), 0) as total_eur_bet,
      COALESCE(SUM(win_amount), 0) as total_eur_won
    FROM gameBets
  `;

  const result = await db.single(query, [gameId, statusList]);

  return {
    bets: result.bets,
    total_bets_placed: parseInt(result.total_bets_placed),
    total_eur_bet: parseFloat(result.total_eur_bet),
    total_eur_won: parseFloat(result.total_eur_won),
  };
};

/**
 * Update bet status with settlement outcomes
 */
const updateBetStatusWithOutcomes = async ({ db, betId, status, winningPosition = null, multiplier = null }) => {
  const now = moment().toISOString();

  return await db.query(
    `UPDATE {game}_bets
     SET status = $1, win_position = $2, multiplier = $3, updated_at = $4
     WHERE id = $5`,
    [status, winningPosition, multiplier, now, betId]
  );
};

/**
 * Get games that need settlement
 */
const getGamesToSettle = async ({ db, status }) => {
  return await db.query(
    `SELECT DISTINCT gg.id
     FROM {game}_games gg
     INNER JOIN {game}_bets gb ON gb.{game}_game_id = gg.id
     WHERE gg.status = 'complete'
       AND gb.status = $1
     ORDER BY gg.id ASC
     LIMIT 100`,
    [status]
  );
};

/**
 * Get bets for settlement
 */
const getBetsForSettlement = async ({ db, gameId, status, gameCreatedAt }) => {
  return await db.query(
    `SELECT 
       gb.id,
       gb.user_id,
       gb.amount,
       gb.currency_type,
       gb.target,
       gb.bet_param_1,
       gb.free_bet,
       gb.remote_bet_id,
       gb.wallet_id,
       gg.outcome_col_1,
       gg.outcome_col_2,
       gg.outcome_col_3
     FROM {game}_bets gb
     INNER JOIN {game}_games gg ON gg.id = gb.{game}_game_id
     WHERE gb.{game}_game_id = $1
       AND gb.status = $2
       AND gb.created_at >= $3`,
    [gameId, status, gameCreatedAt]
  );
};

/**
 * Get bets by IDs for settlement processing
 */
const getBetsForSettlementByIds = async ({ db, betIds, gameCreatedAt }) => {
  return await db.query(
    `SELECT 
       gb.id,
       gb.user_id,
       gb.amount,
       gb.currency_type,
       gb.target,
       gb.bet_param_1,
       gb.status,
       gb.free_bet,
       gb.remote_bet_id,
       gb.remote_round_id,
       gb.wallet_id
     FROM {game}_bets gb
     WHERE gb.id = ANY($1)
       AND gb.created_at >= $2`,
    [betIds, gameCreatedAt]
  );
};

// Export all methods
module.exports = {
  ...betsFactoryRepo,
  getAllBets,
  updateBetStatusWithOutcomes,
  getGamesToSettle,
  getBetsForSettlement,
  getBetsForSettlementByIds,
};
```

#### 1.7 Create Outcomes Service

**File:** `services/{game}-outcomes-service.js`

The outcomes service determines winning and losing bets based on game results.

```javascript
const { calculateBetSettlement } = require('../utils/calculations');

/**
 * Determine bet outcomes for {game}
 * @param {Array} bets - Array of bet objects from getBetsForSettlement
 * @param {Object} gameData - Game data including outcome columns
 * @returns {Object} { winningBets, losingBets }
 */
const determine{Game}BetOutcomes = (bets, gameData) => {
  // Extract game outcome from gameData
  const gameOutcome = {
    col_1: gameData.outcome_col_1,
    col_2: gameData.outcome_col_2,
    col_3: gameData.outcome_col_3,
  };

  const winningBets = [];
  const losingBets = [];

  bets.forEach((bet) => {
    // Use your game-specific calculation logic
    const settlement = calculateBetSettlement(bet, gameOutcome);

    if (settlement.won) {
      winningBets.push({
        ...bet,
        multiplier: settlement.multiplier,
        winPosition: settlement.winPosition,
        // Add any additional settlement data
      });
    } else {
      losingBets.push({
        ...bet,
        multiplier: 0,
        winPosition: null,
      });
    }
  });

  return { winningBets, losingBets };
};

module.exports = { determine{Game}BetOutcomes };
```

#### 1.8 Create Marshalling Service

**File:** `services/{game}-marshalling-service.js`

The marshalling service formats data for API responses and socket events.

```javascript
const { GameMarshalling } = require('../../../services/marshalling-service');

class {Game}Marshalling extends GameMarshalling {
  /**
   * Marshal current game with user bets
   * Used by: GET /rgs/{game}/user_bets/:roomId
   */
  static marshalGameWithBets(game, gameBets, config) {
    const bets = super.marshalBet(game.status, gameBets, config);
    const base = super.marshalCurrentGameWithBets(game, gameBets);

    const response = {
      ...base,
      bets,
    };

    // Add game-specific fields for completed games
    if (game.status === config.status.COMPLETE) {
      response.game_result = {
        outcome_1: game.outcome_col_1,
        outcome_2: game.outcome_col_2,
        // ... other outcome fields
      };
      if (game.server_seed) {
        response.server_seed = game.server_seed;
      }
    }

    return response;
  }

  /**
   * Marshal games history
   * Used by: GET /rgs/{game}/recent/:roomId
   */
  static marshalGamesHistory(games, config) {
    const records = super.marshalGamesHistory(games, config);

    return records.map((record, index) => ({
      ...record,
      game_result: {
        outcome_1: games[index].outcome_col_1,
        outcome_2: games[index].outcome_col_2,
      },
    }));
  }

  /**
   * Marshal user bets history
   * Used by: GET /rgs/{game}/user_bets_history/:roomId
   */
  static marshalUserBetsHistory(userBets, config) {
    const result = super.marshalUserBetsHistory(userBets, config);

    const recordsWithGameData = result.records.map(record => ({
      ...record,
      // Add game-specific transformations
    }));

    return {
      ...result,
      records: recordsWithGameData
    };
  }

  /**
   * Marshal place bet response
   * Used by: POST /rgs/{game}/bet
   */
  static marshalPlaceBetResponse(result, gameConfig) {
    const response = super.marshalPlaceBetResponse(result, gameConfig);

    return {
      success: true,
      ...response,
      // Add game-specific response data
    };
  }
}

module.exports = {Game}Marshalling;
```

#### 1.9 Create Validator Service

**File:** `services/{game}-validator-service.js`

```javascript
const { APIError, ErrorCode } = require('../../../../shared/legacy-errors');

const key = 'game-validator:{game_type}';

/**
 * Validate game-specific bet rules
 * Called synchronously during bet placement
 */
const validateGameSpecificRules = (payload, _gameConfig) => {
  const { target, bet_param_1 } = payload;

  // Validate target format
  if (!target || typeof target !== 'string') {
    throw new APIError(ErrorCode.INVALID_STATE, {
      target,
      reason: 'Target is required and must be a string',
    });
  }

  // Add game-specific validation rules
  // Example: validate bet_param_1 is within allowed values
  const validParams = ['option_a', 'option_b', 'option_c'];
  if (bet_param_1 && !validParams.includes(bet_param_1)) {
    throw new APIError(ErrorCode.INVALID_STATE, {
      bet_param_1,
      reason: `Invalid bet parameter: ${bet_param_1}`,
    });
  }
};

/**
 * Additional async validation
 * Called after synchronous validation, allows DB queries
 */
const validateAdditionalRules = async ({
  db,
  gameId,
  userId,
  payload,
  getDuplicateTargetBet,
  getActiveBetsForMaxProfit,
  gameConfig,
}) => {
  const { target, amount } = payload;

  // Example: Check for duplicate bet with same target
  const duplicateBet = await getDuplicateTargetBet({
    db,
    gameId,
    userId,
    target,
  });

  if (duplicateBet) {
    throw new APIError(ErrorCode.DUPLICATE_BET, {
      reason: 'You already have a bet with this target',
    });
  }

  // Example: Check max profit limits
  if (gameConfig?.limits?.maxProfit && getActiveBetsForMaxProfit) {
    const existingBets = await getActiveBetsForMaxProfit({ db, gameId });
    const totalPotentialPayout = calculateTotalPotentialPayout(existingBets);
    
    // Calculate new bet potential payout based on your game logic
    const newBetPotentialPayout = calculatePotentialPayout(amount, payload);
    
    if (totalPotentialPayout + newBetPotentialPayout > gameConfig.limits.maxProfit) {
      throw new APIError(ErrorCode.BET_ABOVE_TABLE_LIMIT, {
        reason: 'Bet would exceed maximum profit limit for this round',
      });
    }
  }
};

module.exports = {
  key,
  validateGameSpecificRules,
  validateAdditionalRules,
};
```

#### 1.10 Create Tick-Specific Fields Utility

**File:** `utils/tick-game-specific.js`

```javascript
const moment = require('moment');

/**
 * Add game-specific fields to tick payload
 * Called during each tick to add custom data to the socket event
 * @param {Object} currentGame - The current game object
 * @param {Object} config - Game configuration
 * @returns {Object} Game-specific fields to add to the payload
 */
const addGameSpecificFields = ({ currentGame, config }) => {
  const gameSpecificFields = {};

  const now = moment();
  const createdAt = moment(currentGame.created_at);
  const timeSinceCreated = now.diff(createdAt);

  const { preRoundMs, rollingMs } = config.timing;

  // Add timing information based on game status
  if (currentGame.status === config.status.WAITING) {
    gameSpecificFields.time_until_rolling = Math.max(0, preRoundMs - timeSinceCreated);
  }

  if (currentGame.status === config.status.ROLLING) {
    const timeUntilComplete = preRoundMs + rollingMs - timeSinceCreated;
    gameSpecificFields.time_until_complete = Math.max(0, timeUntilComplete);
    
    // Add progressive reveal logic if applicable
    // Example: reveal game outcome progressively during rolling phase
    // gameSpecificFields.revealed_data = calculateRevealedData(currentGame, config);
  }

  if (currentGame.status === config.status.COMPLETE) {
    // Include full game outcome for completed games
    gameSpecificFields.game_result = {
      outcome_1: currentGame.outcome_col_1,
      outcome_2: currentGame.outcome_col_2,
    };
  }

  return gameSpecificFields;
};

module.exports = { addGameSpecificFields };
```

#### 1.11 Create Calculations Utility

**File:** `utils/calculations.js`

```javascript
const config = require('../config');

/**
 * Calculate multiplier for a bet type
 * @param {string} betType - Type of bet
 * @returns {number} Multiplier value
 */
const getMultiplier = (betType) => {
  const { multipliers } = config;
  
  const baseMultiplier = multipliers.baseMultipliers[betType];
  if (!baseMultiplier) {
    throw new Error(`Invalid bet type: ${betType}`);
  }
  
  return baseMultiplier;
};

/**
 * Check if a bet wins
 * @param {Object} bet - Bet object
 * @param {Object} gameOutcome - Game outcome
 * @returns {Object} { won, multiplier, winPosition }
 */
const calculateBetSettlement = (bet, gameOutcome) => {
  const { target, bet_param_1 } = bet;
  
  // Implement your game-specific win logic
  // Example: check if target matches any outcome position
  
  let won = false;
  let winPosition = null;
  let multiplier = 0;
  
  // Your win determination logic here
  // ...
  
  if (won) {
    multiplier = getMultiplier(bet_param_1);
  }
  
  return { won, multiplier, winPosition };
};

/**
 * Calculate total potential payout for active bets
 * Used for max profit limit checking
 */
const calculateTotalPotentialPayout = (bets) => {
  return bets.reduce((total, bet) => {
    const multiplier = getMultiplier(bet.bet_type);
    return total + (bet.amount * multiplier);
  }, 0);
};

module.exports = {
  getMultiplier,
  calculateBetSettlement,
  calculateTotalPotentialPayout,
};
```

#### 1.12 Register Engine in Factory

**File:** `packages/rgs-core/engine-factory.js`

```javascript
const { masterDb, scienceDb } = require('../shared/postgres.js');

// Add import for your new engine
const {Game}Engine = require('../games/engines/{game}-engine/index.js');
const LottoBeastEngine = require('../games/engines/lotto-beast-engine/index.js');
const SlideEngine = require('../games/engines/slide-engine/index.js');

const dbPool = {
  master: masterDb,
  science: scienceDb,
  begin: masterDb.begin.bind(masterDb),
};

// Add your engine to the engines object
const engines = {
  'lotto-beast': new LottoBeastEngine({ db: dbPool }),
  'slide': new SlideEngine({ db: dbPool }),
  '{game-slug}': new {Game}Engine({ db: dbPool }),  // ADD THIS
};

function getEngine(gameId) {
  return engines[gameId] || null;
}

function getAllEngines() {
  return engines;
}

function isMultiplayer(gameId) {
  const engine = getEngine(gameId);
  return engine?.constructor?.isMultiplayer || false;
}

module.exports = {
  getEngine,
  getAllEngines,
  isMultiplayer,
};
```

#### 1.13 Create Game Runner Worker

**File:** `workers/game-runner.js`

```javascript
process.env.DD_SERVICE = process.env.DD_SERVICE || '{game}-game-runner';

require('../../../../shared/globals');
require('../../../../shared/datadog').initialize();
require('../../../../shared/exiter').registerGenericCleanup();

const { masterDb } = require('../../../../shared/postgres');
const { sleep } = require('../../../../shared/utils');
const gracefulExitManager = require('../../../../shared/exiter');
const { getEngine } = require('../../../../rgs-core/engine-factory');
const datadog = require('../../../../shared/datadog');
const { apm } = datadog;

const log = global.log.child({ label: '{Game} Game Runner' });
const GAME_ID = '{game-slug}';

/**
 * Main game loop
 */
async function start() {
  const engine = getEngine(GAME_ID);

  if (!engine) {
    log.error(`Engine not found for ${GAME_ID}`);
    if (datadog?.addErrorToActiveTrace) {
      datadog.addErrorToActiveTrace(new Error(`Engine not found for ${GAME_ID}`), {
        message: '{Game} engine not found',
        gameId: GAME_ID,
      });
    }
    process.exit(1);
  }

  const { timing, rooms } = engine.getConfig();

  if (!rooms || rooms.length === 0) {
    log.warn(`No rooms configured for ${GAME_ID}`);
    return;
  }

  log.info(`Starting ${GAME_ID} for ${rooms.length} room(s)`);

  for (const roomId of rooms) {
    log.info(`Starting ${GAME_ID} game loop for room ${roomId}`);

    while (true) {
      try {
        await apm.trace({
          name: '{Game}GameTick',
          callback: async () => {
            await engine.executeTick({ db: masterDb, roomId });
          },
        });
      } catch (error) {
        log.error(`Error in ${GAME_ID} game loop for room ${roomId}:`, error);
        if (datadog?.addErrorToActiveTrace) {
          datadog.addErrorToActiveTrace(error, {
            message: 'Error in game loop execution',
            gameId: GAME_ID,
            roomId,
          });
        }
      }

      await sleep(timing.tickMs);
    }
  }
}

// Graceful shutdown handling
gracefulExitManager.listenForExitSignals({
  onInterruptSignalReceived: () => {
    log.info('{Game} game runner received shutdown signal');
    return new Promise((resolve) => {
      setTimeout(() => {
        log.info('{Game} game runner shutdown complete');
        gracefulExitManager.closeInfrastructureDependencies();
        gracefulExitManager.exitWithOk();
        resolve();
      }, 1000);
    });
  },
});

start();

module.exports = { gameRunner: { run: start, stop: () => gracefulExitManager.closeInfrastructureDependencies() } };
```

#### 1.14 Create Settlement Worker

**File:** `workers/settlement-worker.js`

```javascript
require('../../../../shared/globals');
require('../../../../shared/datadog').initialize();

const { masterDb, scienceDb } = require('../../../../shared/postgres');
const { apm } = require('../../../../shared/datadog');
const { processGameSettlement } = require('../../../services/game-settlement-service');
const { processRetryOperations } = require('../../../services/retry-operations-service');
const { determine{Game}BetOutcomes } = require('../services/{game}-outcomes-service.js');
const {Game}Engine = require('../index.js');
const betsRepo = require('../repos/{game}-bets-repo');
const gamesRepo = require('../repos/{game}-games-repo');

const dbPool = {
  master: masterDb,
  science: scienceDb,
  begin: masterDb.begin.bind(masterDb),
};

const engine = new {Game}Engine({ db: dbPool });
const gameConfig = engine.getConfig();

let timeout;

const process{Game}Settlement = async function run() {
  try {
    await apm.trace({
      name: 'Retry{Game}SettleBets',
      callback: async () => {
        // Process any games with unsettled bets
        await processGameSettlement({
          db: dbPool,
          gameConfig,
          getGamesToSettleQuery: betsRepo.getGamesToSettle,
          getGameByIdQuery: gamesRepo.getGameById,
          getBetsForSettlementQuery: betsRepo.getBetsForSettlement,
          getBetsForSettlementByIdsQuery: betsRepo.getBetsForSettlementByIds,
          updateBetStatusQuery: betsRepo.updateBetStatusWithOutcomes,
          determineBetOutcomes: determine{Game}BetOutcomes,
        });

        // Retry failed wallet operations
        await processRetryOperations({
          db: dbPool.master,
          gameConfig,
          retryPendingWalletQuery: betsRepo.getPendingWalletBets,
          retryRefundQuery: betsRepo.getPendingRefundBets,
          updateBetWithWalletDataQuery: betsRepo.updateBetWithWalletData,
          updateBetStatusQuery: betsRepo.updateBetStatus,
        });
      },
    });

    log.info(`[Retry{Game}SettleBets] finished processing`);
  } catch (error) {
    log.error('[Retry{Game}SettleBets] Error occurred during settlement:', error);
  }

  clearTimeout(timeout);
  timeout = setTimeout(() => run(), 30 * 1000); // Run every 30 seconds
};

const retrySettleBets = {
  async run() {
    log.info('[{Game}Settlement] Starting settlement worker');
    process{Game}Settlement();
  },
  stop() {
    log.info('[{Game}Settlement] Stopping settlement worker');
    clearTimeout(timeout);
  },
};

module.exports = { retrySettleBets };
```

#### 1.15 Add to package.json Scripts

**File:** `package.json`

```json
{
  "scripts": {
    "prod:{game}-game-server": "node packages/games/engines/{game}-engine/workers/game-runner.js"
  }
}
```

#### 1.16 Register in Cron Worker

**File:** `packages/edge/cron-worker.js`

```javascript
// Add import
const { retrySettleBets: retrySettle{Game}Bets } = require('../games/engines/{game}-engine/workers/settlement-worker');

// Add to workers list (at the end with other settlement workers)
retrySettle{Game}Bets.run();
```

#### 1.17 Add WebSocket Room Configuration

**File:** `packages/edge/websockets/replication-sio.js`

```javascript
// Add import
const {game}Config = require('../../games/engines/{game}-engine/config');

// Add room names
const {game}Rooms = {game}Config.rooms.map(roomId => `{game}_room_${roomId}`);

// Add to validRooms array
const validRooms = [
  ...CrashRooms,
  ...DoubleRooms,
  ...SlideRooms,
  ...FruitsRooms,
  ...FortuneDoubleRooms,
  ...lottoBeastRooms,
  ...{game}Rooms,  // ADD THIS
  ...betSlipGameRoomsUpdate,
  ...betSlipGameRoomsError,
];
```

#### 1.18 Optional: Register Validator in Strategy Registry

**File:** `packages/games/utils/strategy-registry.js`

If you have custom validation that needs to be registered:

```javascript
const {game}Validator = require('../engines/{game}-engine/services/{game}-validator-service');

const registry = new Map([
  // ... existing entries
  [{game}Validator.key, {game}Validator], // game-validator:{game_type}
]);
```

---

### Phase 2: Database Migrations (gaming-service-pg-controller)

All database changes are made in the `@blazecode/gaming-service-pg-controller` package.

#### 2.1 Create Status Enum Migration

```sql
-- migrations/{timestamp}_create_{game}_status_enum.sql
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = '{game}_status') THEN
        CREATE TYPE {game}_status AS ENUM ('waiting', 'rolling', 'complete');
    END IF;
END
$$;
```

#### 2.2 Create Games Table Migration

```sql
-- migrations/{timestamp}_create_{game}_games_table.sql
CREATE TABLE IF NOT EXISTS {game}_games (
    id BIGSERIAL PRIMARY KEY,
    status {game}_status NOT NULL DEFAULT 'waiting',
    
    -- Game-specific outcome columns (from RNG)
    outcome_col_1 INTEGER,
    outcome_col_2 INTEGER,
    outcome_col_3 INTEGER,
    -- Add all columns needed to store game outcome
    
    -- Standard columns
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    -- Foreign keys
    server_roll_id BIGINT NOT NULL REFERENCES server_rolls(id),
    multiplayer_game_id BIGINT NOT NULL REFERENCES multiplayer_games(id)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_{game}_games_status ON {game}_games(status);
CREATE INDEX IF NOT EXISTS idx_{game}_games_created_at ON {game}_games(created_at);
CREATE INDEX IF NOT EXISTS idx_{game}_games_multiplayer_game_id ON {game}_games(multiplayer_game_id);
CREATE INDEX IF NOT EXISTS idx_{game}_games_status_mpg ON {game}_games(status, multiplayer_game_id);
```

#### 2.3 Create Bets Table Migration (Partitioned)

**IMPORTANT:** The bets table must be partitioned by `created_at` for performance. Create at least 24 monthly partitions.

```sql
-- migrations/{timestamp}_create_{game}_bets_table.sql

-- Create the parent partitioned table
CREATE TABLE IF NOT EXISTS {game}_bets (
    id BIGSERIAL,
    {game}_game_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    
    -- Bet parameters
    amount NUMERIC(20, 8) NOT NULL,
    currency_type VARCHAR(10) NOT NULL,
    target VARCHAR(255) NOT NULL,
    bet_param_1 VARCHAR(50),
    bet_param_2 VARCHAR(50),
    -- Add game-specific bet columns
    
    -- Status and results
    status VARCHAR(50) NOT NULL DEFAULT 'placed',
    multiplier NUMERIC(20, 8),
    win_position INTEGER,
    
    -- Wallet integration
    remote_bet_id VARCHAR(255),
    remote_round_id VARCHAR(255),
    wallet_id VARCHAR(255),
    free_bet BOOLEAN DEFAULT FALSE,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    -- Composite primary key for partitioning
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Create sequence
CREATE SEQUENCE IF NOT EXISTS {game}_bets_id_seq;

-- Create partitions for current and next 24 months
-- Example: Create partitions for 2025-2027
CREATE TABLE IF NOT EXISTS {game}_bets_2025_01 PARTITION OF {game}_bets
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE IF NOT EXISTS {game}_bets_2025_02 PARTITION OF {game}_bets
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
-- ... continue for all months through 2027

-- Indexes on parent table (will be inherited by partitions)
CREATE INDEX IF NOT EXISTS idx_{game}_bets_game_id ON {game}_bets({game}_game_id);
CREATE INDEX IF NOT EXISTS idx_{game}_bets_user_id ON {game}_bets(user_id);
CREATE INDEX IF NOT EXISTS idx_{game}_bets_status ON {game}_bets(status);
CREATE INDEX IF NOT EXISTS idx_{game}_bets_created_at ON {game}_bets(created_at);
CREATE INDEX IF NOT EXISTS idx_{game}_bets_user_status ON {game}_bets(user_id, status);
CREATE INDEX IF NOT EXISTS idx_{game}_bets_game_status ON {game}_bets({game}_game_id, status);
```

#### 2.4 Add to Bet Type Enums (if needed)

```sql
-- migrations/{timestamp}_add_{game}_to_enums.sql

-- Add to bet_type enum
ALTER TYPE bet_type ADD VALUE IF NOT EXISTS '{game}';

-- Add to transaction_type enum if needed
ALTER TYPE transaction_type ADD VALUE IF NOT EXISTS '{game}_bet';
ALTER TYPE transaction_type ADD VALUE IF NOT EXISTS '{game}_win';
```

#### 2.5 Seed Data

**multiplayer_games seed:**
```sql
-- seeds/{timestamp}_seed_{game}_multiplayer_game.sql
INSERT INTO multiplayer_games (game, status) 
VALUES ('{game}_room_1', 'active')
ON CONFLICT (game) DO NOTHING;
```

**settings seed:**
```sql
-- seeds/{timestamp}_seed_{game}_settings.sql
INSERT INTO settings (key, value) 
VALUES ('{game}_enabled', '0')
ON CONFLICT (key) DO NOTHING;
```

---

### Phase 3: Server Wiring (server-betbr)

#### 3.1 Feature Status Seed (subwriter-pg-controller)

```sql
-- In @blazecode/subwriter-pg-controller
-- seeds/{timestamp}_seed_{game}_feature_status.sql

INSERT INTO feature_status (feature_name, status) 
VALUES ('{game}_room_1', 'game_maintenance')
ON CONFLICT (feature_name) DO NOTHING;
```

#### 3.2 Waitlist Constants

**File:** `packages/waitlist-feature/src/constants.js`

```javascript
module.exports = {
  // ... existing games
  CRASH_ROOM_1: 'crash_room_1',
  DOUBLE_ROOM_1: 'double_room_1',
  {GAME}_ROOM_1: '{game}_room_1',  // ADD THIS
};
```

#### 3.3 Socket Channel Configuration

The socket channels are automatically exposed when you:
1. Add the room to `validRooms` in `replication-sio.js` (gaming-service-betbr)
2. The engine emits ticks via `replicateGameUpdate()`

Clients subscribe to:
- `{game}_room_1` - Room for game ticks
- Events received: tick data containing game state and bets

---

### Phase 4: Client Implementation (client-betbr)

#### 4.1 Directory Structure

```
src/casino/originals/{game}/
├── {Game}.js                    # Main component
├── {Game}.scss                  # Styles
├── constants.js                 # Game constants
├── index.js                     # Exports
├── logic/
│   ├── actions.js               # Redux actions
│   ├── reducers.js              # Redux reducers
│   ├── selectors.js             # Redux selectors
│   └── types.js                 # Action types
├── hooks/
│   ├── use{Game}Socket.js       # Socket connection hook
│   ├── use{Game}State.js        # Game state hook
│   └── use{Game}Bet.js          # Bet placement hook
├── controller/
│   ├── BetController.js         # Bet UI controller
│   └── BetForm.js               # Bet form component
├── canvas/
│   ├── {Game}Canvas.js          # Main Pixi/Spine canvas
│   ├── GameRenderer.js          # Game rendering logic
│   └── animations/              # Animation files
│       ├── *.json               # Spine animation data
│       └── *.atlas              # Spine atlas files
├── components/
│   ├── GameHeader.js            # Game header
│   ├── GameResult.js            # Result display
│   └── GameHistory.js           # History component
├── LiveBetTable/
│   ├── LiveBetTable.js          # Live bets display
│   └── LiveBetRow.js            # Individual bet row
└── assets/
    ├── images/                  # Static images
    └── sounds/                  # Sound effects
```

#### 4.2 Routing Configuration

**File:** `src/casino/CasinoPage.js`

```javascript
import Loadable from 'react-loadable';
import LoadingComponent from '../components/LoadingComponent';

// Add import with Loadable for code splitting
const {Game}Page = Loadable({
  loader: () => import('./originals/{game}'),
  loading: LoadingComponent,
});

// In the routes section
const CasinoPage = () => {
  const isAdmin = useSelector(selectIsAdmin);
  
  return (
    <Routes>
      {/* ... existing routes */}
      
      {/* Add new game route - initially with isAdmin gate */}
      <Route 
        path="/games/{game}" 
        element={isAdmin ? <{Game}Page /> : <Navigate to="/casino" />} 
      />
      
      {/* After global release, remove isAdmin check:
      <Route path="/games/{game}" element={<{Game}Page />} />
      */}
    </Routes>
  );
};
```

#### 4.3 Socket Handlers

**File:** `src/app/networking/socketio-blaze-originals.js`

```javascript
// Add subscription to game room
const subscribeToGame = (socket, gameType, roomId) => {
  socket.emit('cmd', { 
    id: 'subscribe', 
    payload: { room: `${gameType}_room_${roomId}` } 
  });
};

// Add socket listeners for new game
const setup{Game}Listeners = (socket, store) => {
  // Game tick updates
  socket.on('{game}.tick', (data) => {
    store.dispatch({game}Actions.updateGameState(data));
  });

  // User bet results
  socket.on('{game}.user-bets-result', (data) => {
    store.dispatch({game}Actions.updateUserBets(data));
  });
};

// Call setup function when socket connects
export const initializeGameSockets = (socket, store) => {
  // ... existing game setups
  setup{Game}Listeners(socket, store);
};
```

#### 4.4 Redux Logic

**File:** `src/casino/originals/{game}/logic/actions.js`

```javascript
import * as types from './types';
import { api } from '../../../../app/api';

export const updateGameState = (data) => ({
  type: types.UPDATE_GAME_STATE,
  payload: data,
});

export const updateUserBets = (data) => ({
  type: types.UPDATE_USER_BETS,
  payload: data,
});

export const placeBet = (betData) => async (dispatch) => {
  dispatch({ type: types.PLACE_BET_REQUEST });
  
  try {
    const response = await api.post('/rgs/{game}/bet', betData);
    dispatch({ type: types.PLACE_BET_SUCCESS, payload: response.data });
    return response.data;
  } catch (error) {
    dispatch({ type: types.PLACE_BET_FAILURE, payload: error.message });
    throw error;
  }
};

export const fetchGameState = (roomId) => async (dispatch) => {
  try {
    const response = await api.get(`/rgs/{game}/user_bets/${roomId}`);
    dispatch({ type: types.SET_INITIAL_STATE, payload: response.data });
  } catch (error) {
    console.error('Error fetching game state:', error);
  }
};

export const fetchGameHistory = (roomId, page = 1) => async (dispatch) => {
  try {
    const response = await api.get(`/rgs/{game}/recent/history/${roomId}?page=${page}`);
    dispatch({ type: types.SET_GAME_HISTORY, payload: response.data });
  } catch (error) {
    console.error('Error fetching game history:', error);
  }
};
```

**File:** `src/casino/originals/{game}/logic/reducers.js`

```javascript
import * as types from './types';

const initialState = {
  currentGame: null,
  userBets: [],
  gameHistory: [],
  isLoading: false,
  error: null,
  betPending: false,
};

export const {game}Reducer = (state = initialState, action) => {
  switch (action.type) {
    case types.UPDATE_GAME_STATE:
      return {
        ...state,
        currentGame: action.payload,
        userBets: action.payload.bets || state.userBets,
      };
      
    case types.UPDATE_USER_BETS:
      return {
        ...state,
        userBets: action.payload,
      };
      
    case types.PLACE_BET_REQUEST:
      return { ...state, betPending: true, error: null };
      
    case types.PLACE_BET_SUCCESS:
      return { 
        ...state, 
        betPending: false,
        userBets: [...state.userBets, action.payload],
      };
      
    case types.PLACE_BET_FAILURE:
      return { ...state, betPending: false, error: action.payload };
      
    case types.SET_INITIAL_STATE:
      return { ...state, ...action.payload, isLoading: false };
      
    case types.SET_GAME_HISTORY:
      return { ...state, gameHistory: action.payload };
      
    default:
      return state;
  }
};
```

#### 4.5 Navigation Configuration

**File:** `src/app/left-bar/constants.js`

```javascript
import {Game}Icon from '../icons/{Game}Icon';

export const NAVIGATION_ITEMS = [
  // ... existing items
  {
    id: '{game}',
    label: '{Game Name}',
    path: '/games/{game}',
    icon: {Game}Icon,
    category: 'originals',
    isAdmin: true,  // REMOVE AFTER GLOBAL RELEASE
  },
];
```

#### 4.6 Games Configuration

**File:** `src/casino/originals/core/config/games-config.js`

```javascript
export const GAMES_CONFIG = {
  // ... existing games
  {game}: {
    roomId: 1,
    cacheTime: 5000,
    displayName: '{Game Name}',
    socketRoom: '{game}_room_1',
    apiEndpoint: '/rgs/{game}',
    minBet: 0.1,
    // Add game-specific config
  },
};
```

#### 4.7 Global Constants

**File:** `src/app/constants/original-games.js`

```javascript
export const ORIGINAL_GAMES = {
  CRASH: 'crash',
  DOUBLE: 'double',
  SLIDE: 'slide',
  // ... existing
  {GAME}: '{game}',  // ADD THIS
};
```

---

### Phase 5: Admin Panel (admin-betbr)

#### 5.1 Game Status Configuration

**File:** `src/casino/game-status/tab-games-status/const.js`

```javascript
export const GAMES_STATUS_CONFIG = [
  // ... existing games
  {
    id: '{game}',
    name: '{Game Name}',
    featureKey: '{game}_room_1',
    serverKey: '{game}',
    gamingKey: '{game}',
    healthKey: '{game}-game-server',
    autobetType: null,  // or 'autobet-{game}' if applicable
    endpoints: {
      status: '/api/gaming/{game}/status',
      toggle: '/api/gaming/{game}/toggle',
    },
  },
];
```

#### 5.2 Bet Search Component

**File:** `src/originals/search-{game}-bet.js`

```javascript
import React from 'react';
import SearchBetForm from '../components/SearchBetForm';

const Search{Game}Bet = () => {
  return (
    <SearchBetForm
      title="Search {Game Name} Bets"
      gameType="{game}"
      endpoint="/api/admin/users/{game}-bets"
      betDetailEndpoint="/api/admin/users/{game}-bets"
      fields={[
        { name: 'user_id', label: 'User ID', type: 'text', required: false },
        { name: 'bet_id', label: 'Bet ID', type: 'text', required: false },
        { name: 'start_date', label: 'Start Date', type: 'date', required: true },
        { name: 'end_date', label: 'End Date', type: 'date', required: true },
        { name: 'status', label: 'Status', type: 'select', options: [
          { value: '', label: 'All' },
          { value: 'placed', label: 'Placed' },
          { value: 'payout', label: 'Won' },
          { value: 'lost', label: 'Lost' },
        ]},
      ]}
      columns={[
        { key: 'bet_id', label: 'Bet ID' },
        { key: 'user_id', label: 'User ID' },
        { key: 'amount', label: 'Amount' },
        { key: 'target', label: 'Target' },
        { key: 'status', label: 'Status' },
        { key: 'multiplier', label: 'Multiplier' },
        { key: 'created_at', label: 'Date' },
      ]}
    />
  );
};

export default Search{Game}Bet;
```

#### 5.3 Add Admin Routes (admin-betbr)

```javascript
// In admin routes configuration
{
  path: '/originals/{game}',
  component: Search{Game}Bet,
  name: '{Game Name}',
}
```

---

## Integration Points Checklist

### gaming-service-betbr Integrations

| File | Change Required | Status |
|------|-----------------|--------|
| `packages/rgs-core/engine-factory.js` | Register engine instance | ⬜ |
| `packages/edge/cron-worker.js` | Add settlement worker | ⬜ |
| `packages/edge/websockets/replication-sio.js` | Add room names to validRooms | ⬜ |
| `packages/edge/admin/user/originals-bets.js` | Add admin endpoints | ⬜ |
| `packages/games/utils/strategy-registry.js` | Register validator (if custom) | ⬜ |
| `package.json` | Add prod script for game runner | ⬜ |

### Database Integrations

| Package | Item | Status |
|---------|------|--------|
| `gaming-service-pg-controller` | Status enum migration | ⬜ |
| `gaming-service-pg-controller` | Games table migration | ⬜ |
| `gaming-service-pg-controller` | Bets table migration (partitioned) | ⬜ |
| `gaming-service-pg-controller` | Bet type enum update | ⬜ |
| `gaming-service-pg-controller` | multiplayer_games seed | ⬜ |
| `gaming-service-pg-controller` | settings seed | ⬜ |
| `subwriter-pg-controller` | feature_status seed | ⬜ |

---

## Release Flow & Deployment

### Deployment Order (Production)

```
1. gaming-service-pg-controller (publish new version)
      ↓
2. subwriter-pg-controller (publish new version)
      ↓
3. gaming-service-betbr (runs migrations, starts workers)
      ↓
4. server-betbr (applies feature_status seed)
      ↓
5. client-betbr (admin-only route initially)
      ↓
6. admin-betbr (status panel + bet search)
```

### Release Phases

| Phase | Duration | Settings | Actions |
|-------|----------|----------|---------|
| **Admin Only** | Day 1 | `{game}_enabled = 0`, feature_status = `game_maintenance` | Access via direct URL for admins only |
| **Beta/Whitelist** | Days 2-7 | `{game}_enabled = 1`, feature_status = `restricted_access` | Grant users via waitlist |
| **Global Release** | Day 8+ | `{game}_enabled = 1`, feature_status = `globally_available` | Remove `isAdmin` from route/nav |

### Post-Deploy Checklist

#### Staging Verification

- [ ] Tables and partitions (24 months) created
- [ ] `SELECT * FROM multiplayer_games WHERE game LIKE '{game}%'` returns row
- [ ] `SELECT * FROM settings WHERE key = '{game}_enabled'` returns '0'
- [ ] `SELECT * FROM feature_status WHERE feature_name = '{game}_room_1'` returns 'game_maintenance'
- [ ] Game runner logs show tick execution
- [ ] Admin can load game via direct URL
- [ ] Can place a bet successfully
- [ ] Bets settle correctly (win/lose)
- [ ] Socket events received by client

#### Production Verification

- [ ] Migrations succeeded (check DB logs)
- [ ] Health endpoints green (ECS service healthy)
- [ ] Application logs clean (no errors)
- [ ] Datadog metrics flowing
- [ ] Ready for whitelist phase

#### Post-Release (Global)

- [ ] Remove `isAdmin` from route in client-betbr
- [ ] Remove `isAdmin` from navigation in client-betbr
- [ ] Update feature_status → `globally_available`
- [ ] Update setting → `1`
- [ ] Add game to home page categories
- [ ] Send user communications

---

## Testing Strategy

### Unit Tests (`*.test.js`, `*.unit.js`)

```javascript
// packages/games/engines/{game}-engine/tests/engine-validation.test.js
const { expect } = require('chai');
const { describe, it } = require('mocha');

describe('{Game} Engine Validation Tests', () => {
  const { get{Game}Rng } = require('../../../../math/{game}/{game}-rng');
  const { calculateBetSettlement, getMultiplier } = require('../utils/calculations');

  it('should generate consistent deterministic outcomes from same hash', () => {
    const hash = 'a1b2c3d4e5f6789abcdef123456789abcdef123456789abcdef123456789abcdef';
    
    const result1 = get{Game}Rng(hash);
    const result2 = get{Game}Rng(hash);
    
    expect(result1).to.deep.equal(result2);
  });

  it('should generate outcomes within valid range', () => {
    const hash = 'a1b2c3d4e5f6789abcdef123456789abcdef123456789abcdef123456789abcdef';
    
    const result = get{Game}Rng(hash);
    
    // Verify all outcomes are within expected range
    result.forEach((value) => {
      expect(value).to.be.at.least(0);
      expect(value).to.be.at.most(YOUR_MAX_VALUE);
    });
  });

  it('should calculate valid multipliers for all bet types', () => {
    const betTypes = ['type_a', 'type_b', 'type_c'];
    
    betTypes.forEach((betType) => {
      const multiplier = getMultiplier(betType);
      expect(multiplier).to.be.a('number');
      expect(multiplier).to.be.above(0);
    });
  });

  it('should correctly determine winning bet', () => {
    const bet = { target: 'winning_target', bet_param_1: 'type_a' };
    const gameOutcome = { /* matching outcome */ };
    
    const result = calculateBetSettlement(bet, gameOutcome);
    
    expect(result.won).to.be.true;
    expect(result.multiplier).to.be.above(0);
  });

  it('should correctly determine losing bet', () => {
    const bet = { target: 'losing_target', bet_param_1: 'type_a' };
    const gameOutcome = { /* non-matching outcome */ };
    
    const result = calculateBetSettlement(bet, gameOutcome);
    
    expect(result.won).to.be.false;
    expect(result.multiplier).to.equal(0);
  });
});
```

### Integration Tests (`*.spec.js`)

```javascript
// packages/games/engines/{game}-engine/tests/{game}-e2e-integration.spec.js
const { expect } = require('chai');
const { describe, it, beforeEach, afterEach } = require('mocha');
const nock = require('nock');
const { masterDb } = require('../../../../shared/postgres');
const {Game}Engine = require('../index');
const config = require('../config');

describe('{Game} E2E Integration', () => {
  let engine;
  let dbPool;

  beforeEach(async () => {
    dbPool = {
      master: masterDb,
      science: masterDb,
      begin: masterDb.begin?.bind(masterDb),
    };
    
    engine = new {Game}Engine({ db: dbPool });

    // Mock wallet API calls
    nock(config.wallet.url)
      .post('/casino/hooks/originals/payout')
      .optionally()
      .times(50)
      .reply(200, {});
  });

  afterEach(async () => {
    nock.cleanAll();
  });

  it('should complete full game lifecycle', async () => {
    // 1. Get or create multiplayer_games entry
    const { id: multiplayerGameId } = await engine.gamesRepo.getMultiplayerGameId({
      db: masterDb,
      roomId: 1,
    });
    
    // 2. Create a new game
    await engine.executeTick({ db: masterDb, roomId: 1 });
    
    // 3. Verify game was created
    const game = await engine.gamesRepo.getCurrentGame({
      db: masterDb,
      multiplayerGameId,
    });
    
    expect(game).to.exist;
    expect(game.status).to.equal('waiting');
    
    // 4. Place a bet
    const betResult = await engine.placeBet({
      user_id: 777001,
      amount: 10,
      currency: 'BRL',
      target: 'test_target',
      room_id: 1,
    });
    
    expect(betResult.success).to.be.true;
    
    // 5. Advance game to completion
    // (manipulate created_at to simulate time passing)
    
    // 6. Verify settlement
    // ...
  });

  it('should enforce max profit limits', async () => {
    // Test that bets exceeding max profit are rejected
  });

  it('should validate bet parameters', async () => {
    // Test validator service
  });
});
```

### Running Tests

```bash
# All unit tests
npm run test:unit

# All integration tests
npm run test:e2e

# Single test file
npm run test:unit:single -- --grep "{Game}"

# Test with coverage
npm run cover
```

---

## Troubleshooting Guide

### Common Issues and Solutions

| Issue | Possible Causes | Solutions |
|-------|-----------------|-----------|
| **Game not showing in client** | Route missing, feature_status blocking, CDN assets wrong | Check routing config, verify feature_status in DB, validate CDN paths |
| **Bets failing** | `{game}_enabled = 0`, feature_status denies, socket disconnected | Check settings table, verify feature_status, check socket connection |
| **No ticks / game not starting** | Runner down, roomId mismatch, missing multiplayer_games seed | Check runner logs, verify roomId matches config, check seeds ran |
| **Settlement stuck** | Worker stopped, outcomes bug, wallet API error | Check settlement worker logs, review outcomes logic, check wallet API health |
| **Socket events missing** | Room not in validRooms, client not subscribed | Add room to replication-sio.js validRooms, verify client subscription |
| **Database errors** | Missing partitions, wrong column types | Check table exists, verify partition range covers current date |
| **Engine not found** | Not registered in engine-factory.js | Verify engine is imported and added to engines object |

### Useful Debug Commands

```sql
-- Check if game is enabled
SELECT * FROM settings WHERE key = '{game}_enabled';

-- Check feature status
SELECT * FROM feature_status WHERE feature_name = '{game}_room_1';

-- Check multiplayer game exists
SELECT * FROM multiplayer_games WHERE game LIKE '{game}%';

-- Check recent games
SELECT id, status, created_at, outcome_col_1 
FROM {game}_games 
ORDER BY id DESC 
LIMIT 5;

-- Check pending bets
SELECT id, user_id, amount, target, status 
FROM {game}_bets 
WHERE status = 'placed' 
ORDER BY id DESC 
LIMIT 10;

-- Check bets for a specific game
SELECT * FROM {game}_bets 
WHERE {game}_game_id = YOUR_GAME_ID;

-- Check for unsettled completed games
SELECT g.id, g.status, COUNT(b.id) as pending_bets
FROM {game}_games g
LEFT JOIN {game}_bets b ON b.{game}_game_id = g.id AND b.status = 'placed'
WHERE g.status = 'complete'
GROUP BY g.id, g.status
HAVING COUNT(b.id) > 0;
```

### Log Locations

| Service | Log Command / Location |
|---------|----------------------|
| Game Runner | ECS task logs, search for "{Game} Game Runner" |
| Settlement Worker | ECS cron-worker logs, search for "[{Game}Settlement]" |
| API | ECS api logs |
| Datadog | dd.service:{game}-game-runner |

---

## Reference Implementation: Lotto Beast

### Overview

Lotto Beast is a lottery-style multiplayer game that serves as the reference implementation for new games. It demonstrates all patterns described in this guide.

### Key Files

| Component | Path |
|-----------|------|
| Engine | `packages/games/engines/lotto-beast-engine/` |
| RNG | `packages/math/lotto-beast/lotto-beast-rng.js` |
| Config | `packages/games/engines/lotto-beast-engine/config.js` |
| Game Runner | `packages/games/engines/lotto-beast-engine/workers/game-runner.js` |
| Settlement Worker | `packages/games/engines/lotto-beast-engine/workers/settlement-worker.js` |
| Games Repo | `packages/games/engines/lotto-beast-engine/repos/lotto-beast-games-repo.js` |
| Bets Repo | `packages/games/engines/lotto-beast-engine/repos/lotto-beast-bets-repo.js` |
| Outcomes Service | `packages/games/engines/lotto-beast-engine/services/lotto-beast-outcomes-service.js` |
| Marshalling | `packages/games/engines/lotto-beast-engine/services/lotto-beast-marshalling-service.js` |
| Validator | `packages/games/engines/lotto-beast-engine/services/lotto-beast-validator-service.js` |
| Calculations | `packages/games/engines/lotto-beast-engine/utils/calculations.js` |
| Tests | `packages/games/engines/lotto-beast-engine/tests/` |

### Configuration Details

```javascript
// Timing Configuration
timing: {
  preRoundMs: 15500,     // 15.5 seconds betting window
  rollingMs: 12000,      // 12 seconds reveal animation
  postRoundMs: 5000,     // 5 seconds results display
  tickMs: 1000,          // 1 second tick interval
  revealIntervalMs: 2000 // 2 seconds between number reveals
}

// Multipliers
multipliers: {
  baseMultipliers: {
    full_number: 9200,   // Match all 4 digits
    last_3: 920,         // Match last 3 digits
    last_2: 92,          // Match last 2 digits
    animal: 23           // Match animal group (4 consecutive numbers)
  },
  modeFactors: {
    1: 1.0,              // just_1st_raffle: 100% of base multiplier
    5: 0.201             // all_5_raffles: 20.1% of base multiplier
  }
}

// Limits
limits: {
  minBet: 0.1,
  maxProfit: 5000000,
  defaultMaxBet: 277777.78
}

// Database
database: {
  games: 'lotto_beast_games',
  bets: 'lotto_beast_bets',
  gameIdColumn: 'lotto_beast_game_id',
  betSequence: 'lotto_beast_bets_id_seq'
}
```

### RNG Implementation

The Lotto Beast RNG extends the Core RNG to generate 5 numbers in range [0, 9999]:

```javascript
const { generateCoreRngValues } = require('../core-rng');

const getLottoBeastRng = (hash) => {
  // Get 5 core RNG values (each in range [0, 2^52))
  const rngValues = generateCoreRngValues(hash);
  
  // Map each value to Lotto Beast range [0, 9999]
  const numbers = rngValues.map((value) => value % 10000);
  
  return numbers;
};
```

### Database Schema

**lotto_beast_games Table:**
```sql
- id (BIGSERIAL PRIMARY KEY)
- status (lotto_beast_status: 'waiting', 'rolling', 'complete')
- winning_number_1 through winning_number_5 (INTEGER)
- created_at, updated_at (TIMESTAMP WITH TIME ZONE)
- server_roll_id (FK to server_rolls)
- multiplayer_game_id (FK to multiplayer_games)
```

**lotto_beast_bets Table (Partitioned):**
```sql
- id, lotto_beast_game_id, user_id
- amount, currency_type
- target (VARCHAR) - hyphen-separated targets (e.g., "1234" or "01-02-03-04")
- bet_type (VARCHAR) - 'full_number', 'last_3', 'last_2', 'animal', 'number'
- raffle_mode (VARCHAR) - 'just_1st_raffle', 'all_5_raffles'
- status, multiplier, win_position
- remote_bet_id, remote_round_id, wallet_id, free_bet
- created_at, updated_at
```

### Settlement Logic

```javascript
const determineLottoBeastBetOutcomes = (bets, gameData) => {
  const winningNumbers = [
    gameData.winning_number_1,
    gameData.winning_number_2,
    gameData.winning_number_3,
    gameData.winning_number_4,
    gameData.winning_number_5
  ];

  const winningBets = [];
  const losingBets = [];

  bets.forEach((bet) => {
    const settlement = calculateLottoBetSettlement(bet, winningNumbers);

    if (settlement.won) {
      winningBets.push({
        ...bet,
        multiplier: settlement.multiplier,
        winPosition: settlement.winPosition,
        actualBetType: settlement.actualBetType
      });
    } else {
      losingBets.push({
        ...bet,
        multiplier: 0,
        winPosition: null
      });
    }
  });

  return { winningBets, losingBets };
};
```

### Special Features

1. **Progressive Reveal:** During rolling phase, numbers are revealed one at a time every `revealIntervalMs`
2. **Multiple Bet Types:** Supports full number, last 2/3 digits, and animal group betting
3. **Raffle Modes:** Can bet on just first raffle or all 5 raffles (affects multiplier)
4. **Animal Groups:** 4 consecutive numbers represent an animal (e.g., 00-01-02-03)

---

## Appendix

### Useful Links

- [Core RNG Documentation](https://blazeltd.atlassian.net/wiki/spaces/SA/pages/1533313026/New+RNG)
- [GLI Audit Guidelines](internal-link)
- [Datadog Dashboards](internal-link)
- [Deployment Pipeline](internal-link)

### Key Contacts

- **RGS Architecture:** Hector Klikailo
- **DevOps/Deployment:** @blaze-ltd/devops
- **Game Logic Review:** @blaze-ltd/TL

---

**Document Version:** 2.0  
**Last Updated:** February 4, 2026  
**Maintainer:** Hector Klikailo
