/* =========================================================
   WIN ZONE — OFFICIAL GLOBAL LOGIC & ENGINE
   Standardized Frontend Functions, State, i18n & Currency
   ========================================================= */

window.WINZONE = window.WINZONE || {};

(function () {
    "use strict";

    /* =====================================================
       1. CURRENCY ENGINE & FORMATTER
       ===================================================== */
    const RATES = {
        USD: { symbol: "$", rate: 1.0, decimals: 2 },
        RWF: { symbol: "FRw ", rate: 1350.0, decimals: 0 },
        EUR: { symbol: "€", rate: 0.92, decimals: 2 },
        KES: { symbol: "KSh ", rate: 130.0, decimals: 0 }
    };

    WINZONE.getCurrency = function () {
        return localStorage.getItem("winzone_currency") || "USD";
    };

    WINZONE.setCurrency = function (curr) {
        if (RATES[curr]) {
            localStorage.setItem("winzone_currency", curr);
            document.dispatchEvent(new CustomEvent("winzone:currency_changed", { detail: { currency: curr } }));
            WINZONE.refreshDisplayCurrencies();
        }
    };

    WINZONE.convertAmount = function (amountUSD, targetCurr) {
        const curr = targetCurr || WINZONE.getCurrency();
        const conf = RATES[curr] || RATES.USD;
        return Number(amountUSD) * conf.rate;
    };

    WINZONE.formatMoney = function (amountUSD, targetCurr) {
        const num = Number(amountUSD);
        if (!Number.isFinite(num)) return "$0.00";

        const curr = targetCurr || WINZONE.getCurrency();
        const conf = RATES[curr] || RATES.USD;
        const converted = num * conf.rate;

        if (curr === "USD") {
            return "$" + converted.toFixed(2);
        } else if (curr === "EUR") {
            return "€" + converted.toFixed(2);
        } else if (curr === "RWF") {
            return Math.round(converted).toLocaleString() + " FRw";
        } else if (curr === "KES") {
            return "KSh " + Math.round(converted).toLocaleString();
        }
        return converted.toFixed(conf.decimals) + " " + curr;
    };

    WINZONE.refreshDisplayCurrencies = function () {
        document.querySelectorAll("[data-usd]").forEach(el => {
            const usd = parseFloat(el.getAttribute("data-usd"));
            if (!isNaN(usd)) {
                el.textContent = WINZONE.formatMoney(usd);
            }
        });
        const select = document.getElementById("wzCurrencySelect");
        if (select) select.value = WINZONE.getCurrency();
    };

    /* =====================================================
       2. WALLET STATE SIMULATION (PERSISTED)
       ===================================================== */
    const DEFAULT_WALLET = {
        available: 50.00,
        reserved: 0.00,
        totalWinnings: 0.00
    };

    WINZONE.getWallet = function () {
        try {
            const stored = localStorage.getItem("winzone_wallet");
            return stored ? JSON.parse(stored) : { ...DEFAULT_WALLET };
        } catch (e) {
            return { ...DEFAULT_WALLET };
        }
    };

    WINZONE.setWallet = function (wallet) {
        localStorage.setItem("winzone_wallet", JSON.stringify(wallet));
        document.dispatchEvent(new CustomEvent("winzone:wallet_updated", { detail: wallet }));
        WINZONE.refreshDisplayBalances();
    };

    WINZONE.refreshDisplayBalances = function () {
        const wallet = WINZONE.getWallet();
        document.querySelectorAll(".wz-wallet-available").forEach(el => {
            el.textContent = WINZONE.formatMoney(wallet.available);
        });
        document.querySelectorAll(".wz-wallet-reserved").forEach(el => {
            el.textContent = WINZONE.formatMoney(wallet.reserved);
        });
        document.querySelectorAll(".wz-wallet-total").forEach(el => {
            el.textContent = WINZONE.formatMoney(wallet.available + wallet.reserved);
        });
    };

    /* =====================================================
       3. TRANSACTIONS LEDGER
       ===================================================== */
    WINZONE.getTransactions = function () {
        try {
            const stored = localStorage.getItem("winzone_txs");
            return stored ? JSON.parse(stored) : [
                { id: "TX-1092", type: "deposit", title: "Initial Welcome Deposit", amount: 50.00, date: new Date().toISOString(), status: "Completed" }
            ];
        } catch (e) {
            return [];
        }
    };

    WINZONE.addTransaction = function (tx) {
        const txs = WINZONE.getTransactions();
        tx.id = tx.id || "TX-" + Math.floor(1000 + Math.random() * 9000);
        tx.date = tx.date || new Date().toISOString();
        txs.unshift(tx);
        localStorage.setItem("winzone_txs", JSON.stringify(txs));
    };

    /* =====================================================
       4. SECURE MATCH CODE GENERATOR (3-5 CHARS, NEVER ALL NUMBERS)
       ===================================================== */
    WINZONE.generateMatchCode = function () {
        const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"; // exclude I, O
        const numbers = "23456789";                 // exclude 0, 1
        const length = Math.floor(Math.random() * 3) + 3; // 3, 4, or 5

        let code = "";
        // Guarantee at least one letter and at least one number
        const letterPos = Math.floor(Math.random() * length);
        let numPos = Math.floor(Math.random() * length);
        while (numPos === letterPos) {
            numPos = Math.floor(Math.random() * length);
        }

        const allChars = letters + numbers;
        for (let i = 0; i < length; i++) {
            if (i === letterPos) {
                code += letters[Math.floor(Math.random() * letters.length)];
            } else if (i === numPos) {
                code += numbers[Math.floor(Math.random() * numbers.length)];
            } else {
                code += allChars[Math.floor(Math.random() * allChars.length)];
            }
        }
        return code;
    };

    /* =====================================================
       5. 18+ AGE CHECK VALIDATION
       ===================================================== */
    WINZONE.isAdult = function (dateOfBirth) {
        const birthDate = new Date(dateOfBirth);
        if (Number.isNaN(birthDate.getTime())) return false;

        const today = new Date();
        let age = today.getFullYear() - birthDate.getFullYear();
        const monthDiff = today.getMonth() - birthDate.getMonth();

        if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birthDate.getDate())) {
            age--;
        }
        return age >= 18;
    };

    /* =====================================================
       6. UI HELPERS & NOTIFICATIONS
       ===================================================== */
    WINZONE.copyText = async function (text) {
        if (!text) return false;
        try {
            await navigator.clipboard.writeText(text);
            return true;
        } catch (e) {
            const temp = document.createElement("textarea");
            temp.value = text;
            document.body.appendChild(temp);
            temp.select();
            document.execCommand("copy");
            document.body.removeChild(temp);
            return true;
        }
    };

    WINZONE.togglePassword = function (input, button) {
        if (!input) return;
        if (input.type === "password") {
            input.type = "text";
            if (button) button.textContent = "HIDE";
        } else {
            input.type = "password";
            if (button) button.textContent = "SHOW";
        }
    };

    WINZONE.status = function (element, message, type) {
        if (!element) return;
        element.textContent = message;
        element.style.display = "block";
        element.className = "wz-notice " + (type || "info");
    };

    WINZONE.clearStatus = function (element) {
        if (!element) return;
        element.textContent = "";
        element.style.display = "none";
    };

    WINZONE.formatDate = function (dateValue) {
        const d = new Date(dateValue);
        if (Number.isNaN(d.getTime())) return "";
        return new Intl.DateTimeFormat(undefined, {
            dateStyle: "medium",
            timeStyle: "short"
        }).format(d);
    };

    WINZONE.requestNotifications = async function () {
        if (!("Notification" in window)) return "unsupported";
        try {
            return await Notification.requestPermission();
        } catch (e) {
            return "error";
        }
    };

    WINZONE.logout = function () {
        sessionStorage.clear();
        window.location.href = "login.html";
    };

    /* Auto initialize on DOM ready */
    document.addEventListener("DOMContentLoaded", function () {
        WINZONE.refreshDisplayCurrencies();
        WINZONE.refreshDisplayBalances();

        // Connect global currency dropdown if present
        const currSelect = document.getElementById("wzCurrencySelect");
        if (currSelect) {
            currSelect.value = WINZONE.getCurrency();
            currSelect.addEventListener("change", function () {
                WINZONE.setCurrency(this.value);
            });
        }
    });

})();
