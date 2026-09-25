# WIN ZONE — Premier 18+ Real-Money Competitive Gaming Platform

![WIN ZONE](https://img.shields.io/badge/Platform-WIN%20ZONE-00c65a?style=for-the-badge)
![Status](https://img.shields.io/badge/Status-Frontend%20Production%20Ready-blue?style=for-the-badge)
![Legal](https://img.shields.io/badge/Compliance-18%2B%20Only-f59e0b?style=for-the-badge)
![Design](https://img.shields.io/badge/UI-Mature%20Sportsbook-1a2232?style=for-the-badge)

WIN ZONE is a modern, high-trust, multilingual web platform designed as an **18+ real-money competitive gaming platform** where verified users compete against verified opponents by staking money on individual 1v1 matches.

---

## 🎨 Professional Sportsbook Design System
Inspired by disciplined, high-trust sports betting interfaces (**betPawa** and **ForzaBet**):
- **Obsidian & Deep Slate Palette**: Replaced cheap neon cyan and saturated purple glows with an authoritative foundation (`#090C10` base, `#131924` surface cards, `#1A2232` elevated panels).
- **Emerald Green Primary Accent (`#00C65A`)**: High-confidence betting green for verified badges, primary call-to-actions, and victory payouts.
- **Warm Sportsbook Amber (`#F59E0B`)**: Subtle highlights for stake chips, odds, and dispute status alerts.
- **Athletic Sans Typography**: Clean, high-legibility sans-serif typography with tabular numbers (`tabular-nums`) for currency, timers, and match codes.

---

## ⚡ Core Platform Architecture & Rules

### 1. Matchmaking & Predefined Stakes
- Players choose from official fixed stakes: **$1, $3, $5, $7, $9, $15, $20, $30, and $50** (with custom amount capability).
- Match codes are **not** generated prematurely; the system searches for an eligible and verified opponent at the identical stake tier.
- Once matched, the stake is locked in escrow from both wallets.

### 2. Fair 10% Platform Commission Rake
- Total Match Prize Pool = 2 &times; Agreed Individual Stake.
- **WIN ZONE Commission = 10%** of the prize pool.
- **Winner Guaranteed Net Payout = 90%** of the prize pool.
- *Example:* Two \$5.00 stakes yield a \$10.00 prize pool. WIN ZONE retains \$1.00 platform commission and \$9.00 is credited directly to the winner's wallet.

### 3. Match Code Security
- Every confirmed match receives a unique private match code.
- Stricly **3 to 5 characters**, containing letters and numbers, and **never only numbers** (`^(?=.*[A-Za-z])[A-Za-z0-9]{3,5}$`).

### 4. Distinct Outcome Experiences
- **Winner Experience (`payout.html`)**: Detailed verification ticket showing the completed match, stake, prize pool, commission, and instant credit of net winnings.
- **Loser Experience (`loss.html`)**: Clear match report showing the lost stake, \$0 payout, and direct options to play again or dispute.

### 5. Financial Wallet & Ledger
- Strict separation between **Available Balance** (liquid) and **Reserved in Escrow** (locked during matches).
- Integrated flows for **Deposits**, **Withdrawals**, and a full audit **Transaction Ledger** with filtering.

### 6. Two-Factor OTP Password Recovery
- Step-by-step OTP verification flow with 60-second countdown timer and secure resend mechanism.

### 7. Multilingual & Multi-Currency Engine
- **i18n Localization (`js/i18n.js`)**: Dynamic instant translation for English (EN), French (FR), Kinyarwanda (RW), and Spanish (ES).
- **Multi-Currency Converter (`js/global.js`)**: Live conversion between USD (`$`), RWF (`FRw`), EUR (`€`), and KES (`KSh`).

### 8. Fair Play Dispute Resolution
- Comprehensive dispute filing form supporting evidence attachments, categorization (score disagreement, disconnections, fraud), and administrative queue review.
- Official Support Contact: **[bigmin00001@gmail.com](mailto:bigmin00001@gmail.com)**.

---

## 📁 Repository Structure

```
win-zone/
├── .github/
│   └── workflows/
│       └── build.yml          # GitHub Actions CI build & verification workflow
├── css/
│   ├── style.css              # Main authoritative stylesheet
│   └── style                  # Backward-compatible alias
├── js/
│   ├── global.js              # State engine, match code generator, currency & wallet logic
│   ├── i18n.js                # Multilingual translations (EN, FR, RW, ES)
│   └── api.js                 # API service contract for WIN-ZONE-BACKEND
├── index.html                 # Hero & platform overview
├── match.html                 # 1v1 matchmaking lobby with all 9 predefined stakes
├── match-room.html            # Private 1v1 match room with generated code & ticket
├── custom.html                # Custom stake offer interface
├── payout.html                # Winner outcome & verified payout credit
├── loss.html                  # Loser outcome & dispute escalation
├── wallet.html                # Wallet overview (available vs reserved balances)
├── deposit.html               # Deposit interface (Card, Mobile Money, Crypto)
├── withdraw.html              # Withdrawal request interface
├── transactions.html          # Full transaction history ledger with filters
├── login.html                 # Player login portal
├── register.html              # 18+ registration with birthdate validation
├── forgot-password.html       # 2-step OTP password recovery
├── reset-password.html        # New password submission
├── account.html               # Profile & responsible gaming limits
├── notifications.html         # User alert center with push permission
├── dispute.html               # Match dispute & evidence filing
├── admin-login.html           # Restricted administrative authentication
├── admin.html                 # Administrative governance & dispute queue
├── terms.html                 # Platform terms & conditions (18+ & 10% commission)
└── privacy.html               # Data privacy policy
```

---

## 🛠️ GitHub Actions CI / CD Workflow
The repository includes a GitHub Actions workflow (`.github/workflows/build.yml`) that validates HTML/CSS integrity and packages the deployable frontend bundle as a verified artifact.

---

## 📧 Support
Official platform support and administrative escalation:
**bigmin00001@gmail.com**
