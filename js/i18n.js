/* =========================================================
   WIN ZONE — MULTILINGUAL (i18n) ENGINE
   Supports English (EN), French (FR), Kinyarwanda (RW), Spanish (ES)
   ========================================================= */

window.WINZONE = window.WINZONE || {};

(function () {
    "use strict";

    const TRANSLATIONS = {
        EN: {
            brandName: "WIN ZONE",
            navCompetitions: "Competitions",
            navWallet: "Wallet",
            navDisputes: "Disputes",
            navNotifications: "Notifications",
            navAccount: "Account",
            navLogin: "Log In",
            navRegister: "Create Account",
            navDashboard: "Dashboard",
            deposit: "Deposit",
            withdraw: "Withdraw",
            logout: "Logout",
            findOpponent: "Find Opponent",
            matchCode: "Match Code",
            stake: "Stake",
            prizePool: "Prize Pool",
            commission: "WIN ZONE Commission",
            winnerPayout: "Winner Payout",
            terms: "Terms & Conditions",
            privacy: "Privacy Policy",
            helpCenter: "Help Center",
            ageNotice: "18+ Only. Play responsibly.",
            heroTitle: "Play. Compete. Win.",
            heroSubtitle: "WIN ZONE is a premier skill-based competition platform where verified players challenge opponents and compete in organized matches with real stakes.",
            commissionExplain: "There is no separate entry fee. A standard 10% platform commission is calculated from the combined prize pool. The winner receives 90% upon match verification."
        },
        FR: {
            brandName: "WIN ZONE",
            navCompetitions: "Compétitions",
            navWallet: "Portefeuille",
            navDisputes: "Litiges",
            navNotifications: "Notifications",
            navAccount: "Mon Compte",
            navLogin: "Connexion",
            navRegister: "Créer un compte",
            navDashboard: "Tableau de bord",
            deposit: "Dépôt",
            withdraw: "Retrait",
            logout: "Déconnexion",
            findOpponent: "Trouver un adversaire",
            matchCode: "Code du match",
            stake: "Mise",
            prizePool: "Cagnotte totale",
            commission: "Commission WIN ZONE",
            winnerPayout: "Paiement du gagnant",
            terms: "Conditions Générales",
            privacy: "Politique de Confidentialité",
            helpCenter: "Centre d'Aide",
            ageNotice: "Réservé aux 18 ans et plus. Jouez de manière responsable.",
            heroTitle: "Jouez. Affrontez. Gagnez.",
            heroSubtitle: "WIN ZONE est une plateforme compétitive de haut niveau où les joueurs vérifiés s'affrontent lors de matchs organisés avec de vraies mises.",
            commissionExplain: "Aucun frais d'inscription supplémentaire. Une commission standard de 10% est prélevée sur la cagnotte. Le gagnant reçoit 90% après validation."
        },
        RW: {
            brandName: "WIN ZONE",
            navCompetitions: "Amarushanwa",
            navWallet: "Ijaketi",
            navDisputes: "Ubujurire",
            navNotifications: "Ubutumwa",
            navAccount: "Konti Yanjye",
            navLogin: "Injira",
            navRegister: "Fungura Konti",
            navDashboard: "Ahabanza",
            deposit: "Bika Amafaranga",
            withdraw: "Bikuza Amafaranga",
            logout: "Sohoka",
            findOpponent: "Shaka Uwo Mukina",
            matchCode: "Kode y'Umukino",
            stake: "Ingano y'Umutungo",
            prizePool: "Igihembo Cyose",
            commission: "Komisiyo ya WIN ZONE",
            winnerPayout: "Amafaranga Y'Uwatsize",
            terms: "Amategeko n'Amabwiriza",
            privacy: "Umutekano n'Amakuru",
            helpCenter: "Ubufasha",
            ageNotice: "Abafite imyaka 18+ gusa. Kina mu buryo bunoze.",
            heroTitle: "Kina. Hatana. Batsinda.",
            heroSubtitle: "WIN ZONE ni urubuga rwizewe rwo guhatana mu mikino y'ubuhanga ku bakinnyi bakuze.",
            commissionExplain: "Nta yandi mafaranga yinjira acibwa. WIN ZONE ifata 10% by'igihembo cyose, uwatsize agahabwa 90% nyuma y'umukino."
        },
        ES: {
            brandName: "WIN ZONE",
            navCompetitions: "Competiciones",
            navWallet: "Billetera",
            navDisputes: "Disputas",
            navNotifications: "Notificaciones",
            navAccount: "Mi Cuenta",
            navLogin: "Iniciar Sesión",
            navRegister: "Crear Cuenta",
            navDashboard: "Panel Principal",
            deposit: "Depositar",
            withdraw: "Retirar",
            logout: "Cerrar Sesión",
            findOpponent: "Buscar Rival",
            matchCode: "Código de Partida",
            stake: "Apuesta",
            prizePool: "Bolsa de Premios",
            commission: "Comisión WIN ZONE",
            winnerPayout: "Pago al Ganador",
            terms: "Términos y Condiciones",
            privacy: "Política de Privacidad",
            helpCenter: "Centro de Ayuda",
            ageNotice: "Solo mayores de 18 años. Juega con responsabilidad.",
            heroTitle: "Juega. Compite. Gana.",
            heroSubtitle: "WIN ZONE es una plataforma de competición de alto nivel basada en la habilidad donde jugadores verificados compiten con apuestas reales.",
            commissionExplain: "Sin tarifa de entrada adicional. La comisión estándar de WIN ZONE es del 10% del total de la bolsa. El ganador recibe el 90%."
        }
    };

    WINZONE.getLanguage = function () {
        return localStorage.getItem("winzone_lang") || "EN";
    };

    WINZONE.setLanguage = function (lang) {
        if (TRANSLATIONS[lang]) {
            localStorage.setItem("winzone_lang", lang);
            WINZONE.applyTranslations(lang);
            document.dispatchEvent(new CustomEvent("winzone:lang_changed", { detail: { lang: lang } }));
        }
    };

    WINZONE.t = function (key) {
        const lang = WINZONE.getLanguage();
        return (TRANSLATIONS[lang] && TRANSLATIONS[lang][key]) || (TRANSLATIONS.EN && TRANSLATIONS.EN[key]) || key;
    };

    WINZONE.applyTranslations = function (langCode) {
        const lang = langCode || WINZONE.getLanguage();
        const dict = TRANSLATIONS[lang] || TRANSLATIONS.EN;

        document.querySelectorAll("[data-i18n]").forEach(el => {
            const key = el.getAttribute("data-i18n");
            if (dict[key]) {
                if (el.tagName === "INPUT" && el.hasAttribute("placeholder")) {
                    el.placeholder = dict[key];
                } else {
                    el.textContent = dict[key];
                }
            }
        });

        const langSelect = document.getElementById("wzLangSelect");
        if (langSelect) langSelect.value = lang;
    };

    document.addEventListener("DOMContentLoaded", function () {
        WINZONE.applyTranslations();

        const langSelect = document.getElementById("wzLangSelect");
        if (langSelect) {
            langSelect.value = WINZONE.getLanguage();
            langSelect.addEventListener("change", function () {
                WINZONE.setLanguage(this.value);
            });
        }
    });

})();
