# Flujos de Free Bets / Free Winnings

## 1) Legacy Crash – Flujo completo

```mermaid
flowchart TD
  %% =========================
  %% FASE 1: CRÉDITO DE FREE BETS
  %% =========================
  subgraph F1["FASE 1: CRÉDITO DE FREE BETS"]
    A1["Admin/Webhook: POST /admin/free-bets/credit<br/>{ user_id, rounds, type, note }"]
    A2["creditFreeRounds({ userId, type, rounds })"]

    A1 --> A2

    A2 --> B1["CREATE/UPDATE bonus_rounds<br/>(rounds += N)"]
    A2 --> B2["INSERT bonus_round_transactions<br/>(amount = N, note)"]

    B1 --> C1["CREATE free_winnings wallet<br/>(si no existe)"]
    B2 --> C1

    C1 --> D1["Emite WebSocket update"]
  end

  %% =========================
  %% FASE 2: COLOCACIÓN DE APUESTA (Legacy Crash)
  %% =========================
  subgraph F2["FASE 2: COLOCACIÓN DE APUESTA (Legacy Crash)"]
    E1["Usuario: POST /crash<br/>{ free_bet: true }"]
    E2["placeCrashBet({ user, gameId })"]
    E3{"wallet.free_bet ?"}
    E4["placeFreeBet({ userId, type: 'crash' })"]

    E1 --> E2 --> E3
    E3 -- "sí" --> E4

    E4 --> F1a["bonus_rounds.rounds -= 1"]
    F1a --> F1b["INSERT bonus_round_transactions<br/>(amount = -1, closing_balance)"]
    F1b --> F1c["INSERT free_bets<br/>(amount = random(), status = 'created')"]
    F1c --> F1d["INSERT bonus_round_bets<br/>(bet_id, bonus_round_transaction_id)"]
    F1d --> F1e["RETURN { id, amount, currency_type }"]

    E2 --> G1["INSERT crash_bets<br/>(amount, free_bet=true, remote_bet_id, status='placed')"]
    G1 --> G2["Emite WebSocket update"]
  end

  %% =========================
  %% FASE 3: SETTLEMENT
  %% =========================
  subgraph F3["FASE 3: SETTLEMENT (Crash Game Ends)"]
    H1["Juego termina con resultado"]
    H2["Domain Event: CrashBetWon o CrashBetLost"]
    H3["Cron: retryCrashPayouts (cada 5min)"]
    H4["Obtiene bets con status='placed'"]
    H5["Para cada bet"]
    H6{"bet.free_bet ?"}
    H7{"isWin ?"}
    H8["payoutFreeBet({ betId, multiplier })"]
    H9["winAmount = amount * multiplier"]
    H10["UPDATE wallets<br/>SET bonus_balance += winAmount<br/>WHERE free_winnings = true"]
    H11["UPDATE free_bets<br/>SET status='win', win_amount, multiplier"]
    H12["UPDATE bonus_round_bets<br/>SET payout_transaction_id"]
    H13["closeLostFreeBet({ betId })"]
    H14["UPDATE free_bets<br/>SET status='loss', win_amount=0"]
    H15["Emite WebSocket update"]

    H1 --> H2 --> H3 --> H4 --> H5 --> H6
    H6 -- "sí" --> H7
    H7 -- "win" --> H8 --> H9 --> H10 --> H11 --> H12 --> H15
    H7 -- "loss" --> H13 --> H14 --> H15
  end

  %% =========================
  %% FASE 4: TRANSFERENCIA A WALLET REAL
  %% =========================
  subgraph F4["FASE 4: TRANSFERENCIA A WALLET REAL"]
    I1["Cron: retryTransferFreeWinnings (cada 4min)"]
    I2["Busca bonus_rounds<br/>rounds=0 && bonus_balance>0"]
    I3["transferFreeWinnings({ userId, type })"]
    I4["Débito wallets WHERE free_winnings=true<br/>(bonus_balance -= X)"]
    I5["INSERT free_winnings_outbound_journal<br/>(user_id, amount, status='pending')"]
    I6["UPDATE bonus_rounds<br/>SET status='complete'"]
    I7["tryToTransferOutboundAndLogIt()"]
    I8["POST /casino/hooks/originals/transfer-free-winnings<br/>(wallet service)"]
    I9{"¿éxito?"}
    I10["UPDATE free_winnings_outbound_journal<br/>SET status='complete', external_transaction_id"]
    I11["Mantiene status='pending' (retry)"]
    I12["Usuario ve dinero en wallet real"]

    I1 --> I2 --> I3 --> I4 --> I5 --> I6 --> I7 --> I8 --> I9
    I9 -- "sí" --> I10 --> I12
    I9 -- "no" --> I11 --> I1
  end

  %% Conexión conceptual entre fases
  F1 --> F2 --> F3 --> F4
