// English, French, Kinyarwanda. Missing keys fall back to English.
// NOTE: Kinyarwanda strings need review by a native speaker before public launch.
export const LANGS = ["en", "fr", "rw"];

const D = {
  en: {
    "nav.tournaments": "Tournaments", "nav.how": "How it works", "nav.organizers": "Organizers",
    "nav.signin": "Sign in", "nav.signup": "Register", "nav.me": "My matches", "nav.signout": "Sign out", "nav.admin": "Admin",
    "nav.menu": "Menu", "nav.dark": "Switch to dark mode", "nav.light": "Switch to light mode",
    "hero.kicker": "Free 1v1 football tournaments",
    "hero.title": "Every match. <em>One bracket.</em>",
    "hero.lede": "Register free. Get your fixture. Play on your phone. The app verifies the result and the bracket updates live, for everyone watching.",
    "hero.cta1": "Browse tournaments", "hero.cta2": "Run a tournament",
    "live.eyebrow": "On the board", "live.title": "Live & upcoming",
    "live.empty": "No tournaments yet. The first bracket is being built.",
    "how.eyebrow": "How it works", "how.title": "Three steps. No fee.",
    "how.1t": "Register", "how.1b": "Pick a tournament and sign up. It costs nothing, ever.",
    "how.2t": "Get your fixture", "how.2b": "The system builds the bracket and schedules every match. You get your time and opponent.",
    "how.3t": "Play and verify", "how.3b": "Tap Play in the app. It reads the match on your phone and reports the result. Both phones must agree.",
    "fair.eyebrow": "Fair by design", "fair.title": "Results nobody can argue with",
    "fair.1t": "Nobody types a score", "fair.1b": "Results come from the game screen itself, read on both phones. There is no result form.",
    "fair.2t": "Two phones, one answer", "fair.2b": "A match settles only when both phones agree. A mismatch goes to review.",
    "fair.3t": "The server decides", "fair.3b": "Phones report what they see. The result is decided in one place, and every override is logged.",
    "fair.4t": "Free to enter", "fair.4b": "No entry fee, no stake, no subscription. Players never pay to compete.",
    "org.eyebrow": "For organizers", "org.title": "Run your own tournament",
    "org.body": "Brackets, schedules, verified results and a public page for your audience. Built once, ready for any organizer.",
    "org.cta": "Talk to us",
    "t.bracket": "Bracket", "t.fixtures": "Fixtures", "t.table": "Table", "t.players": "Players",
    "t.register": "Register free", "t.registered": "You are registered", "t.withdraw": "Withdraw", "t.share": "Share",
    "t.copied": "Link copied", "t.format": "Format", "t.entry": "Entry", "t.free": "Free", "t.prize": "Prize", "t.starts": "Starts",
    "t.size": "Players", "t.planning": "Registration is closed. The organizer is preparing the fixtures.", "t.tbd": "To be decided", "t.champion": "Champion", "t.nomatches": "The bracket appears once registration closes.",
    "t.signin": "Sign in to register", "t.full": "Registration closed: tournament full",
    "st.draft": "Draft", "st.planning": "Preparing fixtures", "st.open": "Registration open", "st.live": "Live", "st.completed": "Completed", "st.cancelled": "Cancelled",
    "fm.knockout": "Knockout", "fm.league": "League", "fm.league_knockout": "League + knockout", "fm.groups_knockout": "Groups + knockout", "fm.league_phase": "League phase + knockout", "t.groups": "Groups", "t.group": "Group", "rd.playoff": "Play-off round", "t.zdirect": "Straight to the knockout", "t.zplayoff": "Play-off round",
    "fx.scheduled": "Scheduled", "fx.active": "Live", "fx.completed": "Full time", "fx.disputed": "Under review", "fx.cancelled": "Cancelled", "fx.stalled": "Under review", "fx.bye": "Bye",
    "rd.final": "Final", "rd.semi": "Semi-finals", "rd.quarter": "Quarter-finals", "rd.r16": "Round of 16", "rd.round": "Round",
    "tb.rank": "#", "tb.player": "Player", "tb.p": "P", "tb.w": "W", "tb.d": "D", "tb.l": "L", "tb.gd": "GD", "tb.pts": "Pts",
    "a.signin": "Sign in", "a.country": "Country", "a.choosecountry": "Select your country", "a.countryhint": "Used to show match times in your local time.", "c.save": "Save", "c.times": "Match times are shown in the time zone of", "c.cancel": "Cancel", "me.change": "Change country", "a.signup": "Create account", "a.email": "Email", "a.password": "Password", "a.username": "Username", "a.agree": "I accept the Terms and Privacy Policy.",
    "a.noaccount": "No account yet?", "a.haveaccount": "Already registered?",
    "me.title": "My matches", "n.title": "Notifications", "n.on": "Turn on notifications", "n.off": "Turn off", "n.active": "On for this phone", "n.blocked": "Notifications are blocked for this site in your browser settings.", "n.unsupported": "This browser cannot show notifications. On iPhone, add WIN ZONE to your Home Screen first.", "n.none": "No notifications yet.", "n.keep": "Keep following", "n.stop": "Stop", "n.kept": "You will keep getting updates about this tournament.", "n.stopped": "Updates from this tournament are stopped.", "n.ask": "Keep getting updates about this tournament?", "me.next": "Next fixtures", "me.entries": "My tournaments", "me.none": "Nothing here yet.",
    "me.room": "Open matchroom", "me.app": "Matches are played in the WIN ZONE app.", "me.getapp": "Get the app",
    "f.tag": "Free skill tournaments for mobile football.", "f.product": "Product", "f.legal": "Legal",
    "f.terms": "Terms", "f.privacy": "Privacy", "f.contact": "Contact", "f.rights": "All rights reserved.",
    "c.loading": "Loading", "c.error": "Something went wrong. Try again.", "c.sample": "Sample data. The live service is not connected yet.",
  },
  fr: {
    "nav.tournaments": "Tournois", "nav.how": "Comment ça marche", "nav.organizers": "Organisateurs",
    "nav.signin": "Connexion", "nav.signup": "S'inscrire", "nav.me": "Mes matchs", "nav.signout": "Déconnexion", "nav.admin": "Admin", "nav.menu": "Menu", "nav.dark": "Passer en mode sombre", "nav.light": "Passer en mode clair",
    "hero.kicker": "Tournois de football 1v1 gratuits",
    "hero.title": "Chaque match. <em>Un seul tableau.</em>",
    "hero.lede": "Inscription gratuite. Recevez votre match. Jouez sur votre téléphone. L'application vérifie le résultat et le tableau se met à jour en direct pour tous.",
    "hero.cta1": "Voir les tournois", "hero.cta2": "Organiser un tournoi",
    "live.eyebrow": "Au tableau", "live.title": "En direct et à venir",
    "live.empty": "Aucun tournoi pour le moment. Le premier tableau est en préparation.",
    "how.eyebrow": "Comment ça marche", "how.title": "Trois étapes. Aucun frais.",
    "how.1t": "Inscrivez-vous", "how.1b": "Choisissez un tournoi et inscrivez-vous. C'est gratuit, toujours.",
    "how.2t": "Recevez votre match", "how.2b": "Le système crée le tableau et planifie chaque match. Vous recevez l'heure et l'adversaire.",
    "how.3t": "Jouez et vérifiez", "how.3b": "Touchez Jouer dans l'application. Elle lit le match sur votre téléphone et envoie le résultat. Les deux téléphones doivent concorder.",
    "fair.eyebrow": "Équitable par conception", "fair.title": "Des résultats incontestables",
    "fair.1t": "Personne ne saisit de score", "fair.1b": "Les résultats viennent de l'écran du jeu, lu sur les deux téléphones. Il n'existe aucun formulaire de résultat.",
    "fair.2t": "Deux téléphones, une réponse", "fair.2b": "Un match n'est validé que si les deux téléphones concordent. Sinon, il est examiné.",
    "fair.3t": "Le serveur décide", "fair.3b": "Les téléphones rapportent ce qu'ils voient. Le résultat est décidé en un seul endroit et chaque modification est journalisée.",
    "fair.4t": "Participation gratuite", "fair.4b": "Pas de frais d'inscription, pas de mise, pas d'abonnement. Les joueurs ne paient jamais pour participer.",
    "org.eyebrow": "Pour les organisateurs", "org.title": "Organisez votre propre tournoi",
    "org.body": "Tableaux, calendriers, résultats vérifiés et page publique pour votre audience. Conçu une fois, prêt pour tout organisateur.",
    "org.cta": "Nous contacter",
    "t.bracket": "Tableau", "t.fixtures": "Matchs", "t.table": "Classement", "t.players": "Joueurs",
    "t.register": "S'inscrire gratuitement", "t.registered": "Vous êtes inscrit", "t.withdraw": "Se retirer", "t.share": "Partager",
    "t.copied": "Lien copié", "t.format": "Format", "t.entry": "Participation", "t.free": "Gratuite", "t.prize": "Récompense", "t.starts": "Début",
    "t.size": "Joueurs", "t.planning": "Les inscriptions sont closes. L'organisateur prépare le calendrier.", "t.tbd": "À déterminer", "t.champion": "Champion", "t.nomatches": "Le tableau apparaît à la clôture des inscriptions.",
    "t.signin": "Connectez-vous pour vous inscrire", "t.full": "Inscriptions terminées : tournoi complet",
    "st.draft": "Brouillon", "st.planning": "Préparation du calendrier", "st.open": "Inscriptions ouvertes", "st.live": "En direct", "st.completed": "Terminé", "st.cancelled": "Annulé",
    "fm.knockout": "Élimination directe", "fm.league": "Championnat", "fm.league_knockout": "Championnat + élimination", "fm.groups_knockout": "Groupes + élimination", "fm.league_phase": "Phase de ligue + élimination", "t.groups": "Groupes", "t.group": "Groupe", "rd.playoff": "Barrages", "t.zdirect": "Qualifié directement", "t.zplayoff": "Barrages",
    "fx.scheduled": "Programmé", "fx.active": "En direct", "fx.completed": "Terminé", "fx.disputed": "En examen", "fx.cancelled": "Annulé", "fx.stalled": "En examen", "fx.bye": "Exempt",
    "rd.final": "Finale", "rd.semi": "Demi-finales", "rd.quarter": "Quarts de finale", "rd.r16": "Huitièmes de finale", "rd.round": "Tour",
    "tb.rank": "#", "tb.player": "Joueur", "tb.p": "J", "tb.w": "G", "tb.d": "N", "tb.l": "P", "tb.gd": "Diff", "tb.pts": "Pts",
    "a.signin": "Connexion", "a.country": "Pays", "a.choosecountry": "Choisissez votre pays", "a.countryhint": "Sert à afficher les heures de match à votre heure locale.", "c.save": "Enregistrer", "c.times": "Les heures de match sont affichées selon le fuseau de", "c.cancel": "Annuler", "me.change": "Changer de pays", "a.signup": "Créer un compte", "a.email": "E-mail", "a.password": "Mot de passe", "a.username": "Nom d'utilisateur", "a.agree": "J'accepte les Conditions et la Politique de confidentialité.",
    "a.noaccount": "Pas encore de compte ?", "a.haveaccount": "Déjà inscrit ?",
    "me.title": "Mes matchs", "n.title": "Notifications", "n.on": "Activer les notifications", "n.off": "Désactiver", "n.active": "Activées sur ce téléphone", "n.blocked": "Les notifications sont bloquées pour ce site dans votre navigateur.", "n.unsupported": "Ce navigateur ne peut pas afficher de notifications. Sur iPhone, ajoutez d'abord WIN ZONE à l'écran d'accueil.", "n.none": "Aucune notification.", "n.keep": "Continuer à suivre", "n.stop": "Arrêter", "n.kept": "Vous continuerez à recevoir les nouvelles de ce tournoi.", "n.stopped": "Les nouvelles de ce tournoi sont arrêtées.", "n.ask": "Continuer à recevoir les nouvelles de ce tournoi ?", "me.next": "Prochains matchs", "me.entries": "Mes tournois", "me.none": "Rien pour le moment.",
    "me.room": "Ouvrir la salle", "me.app": "Les matchs se jouent dans l'application WIN ZONE.", "me.getapp": "Obtenir l'application",
    "f.tag": "Tournois de football mobile gratuits, basés sur l'habileté.", "f.product": "Produit", "f.legal": "Légal",
    "f.terms": "Conditions", "f.privacy": "Confidentialité", "f.contact": "Contact", "f.rights": "Tous droits réservés.",
    "c.loading": "Chargement", "c.error": "Une erreur est survenue. Réessayez.", "c.sample": "Données d'exemple. Le service n'est pas encore connecté.",
  },
  rw: {
    "nav.tournaments": "Amarushanwa", "nav.how": "Uko bikora", "nav.organizers": "Abategura",
    "nav.signin": "Injira", "nav.signup": "Iyandikishe", "nav.me": "Imikino yanjye", "nav.signout": "Sohoka", "nav.admin": "Ubuyobozi", "nav.menu": "Menu", "nav.dark": "Koresha uburyo bw'umwijima", "nav.light": "Koresha uburyo bw'umucyo",
    "hero.kicker": "Amarushanwa y'umupira w'amaguru ni ubuntu",
    "hero.title": "Buri mukino. <em>Urutonde rumwe.</em>",
    "hero.lede": "Iyandikishe ku buntu. Menya umukino wawe. Kina kuri telefone yawe. Porogaramu isuzuma amanota, urutonde rugahita ruvugururwa kuri bose.",
    "hero.cta1": "Reba amarushanwa", "hero.cta2": "Tegura irushanwa",
    "live.eyebrow": "Ku rutonde", "live.title": "Biri kuba kandi biri hafi",
    "live.empty": "Nta marushanwa ariho ubu. Irya mbere riri gutegurwa.",
    "how.eyebrow": "Uko bikora", "how.title": "Intambwe eshatu. Nta kiguzi.",
    "how.1t": "Iyandikishe", "how.1b": "Hitamo irushanwa maze wiyandikishe. Ni ubuntu burigihe.",
    "how.2t": "Menya umukino wawe", "how.2b": "Sisitemu itegura urutonde ikanashyiraho igihe cya buri mukino. Uhabwa igihe n'uwo muhanganye.",
    "how.3t": "Kina kandi usuzume", "how.3b": "Kanda Kina muri porogaramu. Isoma umukino kuri telefone yawe ikohereza amanota. Telefone zombi zigomba guhuza.",
    "fair.eyebrow": "Ubutabera mu buryo bwacu", "fair.title": "Amanota nta wayakoma imbere",
    "fair.1t": "Nta wuzuza amanota", "fair.1b": "Amanota aturuka kuri ecran y'umukino ubwayo, asomwa kuri telefone zombi. Nta fomu yo kwandika amanota.",
    "fair.2t": "Telefone ebyiri, igisubizo kimwe", "fair.2b": "Umukino wemezwa gusa iyo telefone zombi zihuje. Iyo zidahuje urasuzumwa.",
    "fair.3t": "Seriveri niyo ifata icyemezo", "fair.3b": "Telefone zivuga ibyo zibona. Icyemezo gifatirwa ahantu hamwe, kandi buri gihindurwa kiranditswe.",
    "fair.4t": "Kwinjira ni ubuntu", "fair.4b": "Nta kiguzi, nta ngwate, nta bwiyandikishe bwishyurwa. Abakinnyi ntibigera bishyura.",
    "org.eyebrow": "Ku bategura", "org.title": "Tegura irushanwa ryawe",
    "org.body": "Urutonde, gahunda, amanota yasuzumwe n'urubuga rusange rw'abakurikira. Byubatswe rimwe, bikwiye umuteguro wese.",
    "org.cta": "Tuvugishe",
    "t.bracket": "Urutonde", "t.fixtures": "Imikino", "t.table": "Imbonerahamwe", "t.players": "Abakinnyi",
    "t.register": "Iyandikishe ku buntu", "t.registered": "Warandikishijwe", "t.withdraw": "Ikuremo", "t.share": "Sangiza",
    "t.copied": "Link yakopowe", "t.format": "Uburyo", "t.entry": "Kwinjira", "t.free": "Ubuntu", "t.prize": "Igihembo", "t.starts": "Itangira",
    "t.size": "Abakinnyi", "t.planning": "Kwiyandikisha byarangiye. Umuteguro ari gutegura imikino.", "t.tbd": "Bizamenyekana", "t.champion": "Uwegukanye", "t.nomatches": "Urutonde ruzagaragara iyo kwiyandikisha birangiye.",
    "t.signin": "Injira kugira ngo wiyandikishe", "t.full": "Kwiyandikisha byarangiye: irushanwa ryuzuye",
    "st.draft": "Ikiraro", "st.planning": "Imikino iri gutegurwa", "st.open": "Kwiyandikisha birakinguye", "st.live": "Biri kuba", "st.completed": "Byarangiye", "st.cancelled": "Byahagaritswe",
    "fm.knockout": "Gusezerera", "fm.league": "Shampiyona", "fm.league_knockout": "Shampiyona + gusezerera", "fm.groups_knockout": "Amatsinda + gusezerera", "fm.league_phase": "Icyiciro cya shampiyona + gusezerera", "t.groups": "Amatsinda", "t.group": "Itsinda", "rd.playoff": "Imikino ya kamarampaka", "t.zdirect": "Bakomeza mu buryo butaziguye", "t.zplayoff": "Imikino ya kamarampaka",
    "fx.scheduled": "Biteganyijwe", "fx.active": "Biri kuba", "fx.completed": "Byarangiye", "fx.disputed": "Biri gusuzumwa", "fx.cancelled": "Byahagaritswe", "fx.stalled": "Biri gusuzumwa", "fx.bye": "Yasimbutse",
    "rd.final": "Umukino wa nyuma", "rd.semi": "Imikino ya kabiri ya nyuma", "rd.quarter": "Imikino ya kimwe cya kane", "rd.r16": "Imikino ya 16 ba nyuma", "rd.round": "Icyiciro",
    "tb.rank": "#", "tb.player": "Umukinnyi", "tb.p": "Yakinnye", "tb.w": "Yatsinze", "tb.d": "Yanganyije", "tb.l": "Yatsinzwe", "tb.gd": "Itandukaniro", "tb.pts": "Amanota",
    "a.signin": "Injira", "a.country": "Igihugu", "a.choosecountry": "Hitamo igihugu cyawe", "a.countryhint": "Bikoreshwa kugira ngo ibihe by'imikino bigaragare ku isaha yo mu gihugu cyawe.", "c.save": "Bika", "c.times": "Ibihe by'imikino bigaragara ku isaha ya", "c.cancel": "Reka", "me.change": "Hindura igihugu", "a.signup": "Fungura konti", "a.email": "Imeri", "a.password": "Ijambobanga", "a.username": "Izina ukoresha", "a.agree": "Nemeye Amabwiriza n'Politiki y'ibanga.",
    "a.noaccount": "Nta konti ufite?", "a.haveaccount": "Usanzwe wiyandikishije?",
    "me.title": "Imikino yanjye", "n.title": "Amatangazo", "n.on": "Fungura amatangazo", "n.off": "Funga", "n.active": "Afunguye kuri iyi telefone", "n.blocked": "Amatangazo y'uru rubuga yafunzwe mu igenamiterere rya mushakisha.", "n.unsupported": "Iyi mushakisha ntishobora kwerekana amatangazo. Kuri iPhone, banza ushyire WIN ZONE ku rugo rwa ecran.", "n.none": "Nta matangazo arahari.", "n.keep": "Komeza ukurikire", "n.stop": "Hagarika", "n.kept": "Uzakomeza kubona amakuru y'iri rushanwa.", "n.stopped": "Amakuru y'iri rushanwa yahagaritswe.", "n.ask": "Urashaka gukomeza kubona amakuru y'iri rushanwa?", "me.next": "Imikino ikurikira", "me.entries": "Amarushanwa yanjye", "me.none": "Nta kintu kiriho.",
    "me.room": "Fungura icyumba", "me.app": "Imikino ikinirwa muri porogaramu ya WIN ZONE.", "me.getapp": "Fata porogaramu",
    "f.tag": "Amarushanwa y'umupira wa telefone ni ubuntu.", "f.product": "Ibikorwa", "f.legal": "Amategeko",
    "f.terms": "Amabwiriza", "f.privacy": "Ibanga", "f.contact": "Twandikire", "f.rights": "Uburenganzira bwose burabitswe.",
    "c.loading": "Biratunganywa", "c.error": "Hari ikitagenze neza. Ongera ugerageze.", "c.sample": "Amakuru y'ikitegererezo. Serivisi ntiratangira.",
  },
};

let lang = "en";
try { const s = localStorage.getItem("wz_lang"); if (LANGS.includes(s)) lang = s; } catch (_) {}
if (lang === "en" && typeof navigator !== "undefined") {
  const n = (navigator.language || "").slice(0, 2);
  try { if (!localStorage.getItem("wz_lang") && (n === "fr" || n === "rw")) lang = n; } catch (_) {}
}

export const getLang = () => lang;
export function t(key) { return (D[lang] && D[lang][key]) || D.en[key] || key; }
export function setLang(l) {
  if (!LANGS.includes(l)) return;
  lang = l;
  try { localStorage.setItem("wz_lang", l); } catch (_) {}
  document.documentElement.lang = l;
}
export function applyI18n(root = document) {
  root.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
  root.querySelectorAll("[data-i18n-html]").forEach((el) => { el.innerHTML = t(el.dataset.i18nHtml); });
  root.querySelectorAll("[data-i18n-ph]").forEach((el) => { el.placeholder = t(el.dataset.i18nPh); });
}
