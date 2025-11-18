import Foundation
import SwiftUI

class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @Published var currentCountry: Country
    @Published var currentLanguage: Language
    
    private var localizations: [String: [String: String]] = [:]
    
    // Use UserDefaults directly to avoid @AppStorage initialization issues
    private var selectedCountryCode: String {
        get { UserDefaults.standard.string(forKey: "selectedCountryCode") ?? "US" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedCountryCode") }
    }
    
    private var selectedLanguageCode: String {
        get { UserDefaults.standard.string(forKey: "selectedLanguageCode") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLanguageCode") }
    }
    
    private init() {
        // Initialize with saved values or defaults
        self.currentCountry = Country.findByCode(UserDefaults.standard.string(forKey: "selectedCountryCode") ?? "US") ?? Country.all[0]
        self.currentLanguage = Language.findByCode(UserDefaults.standard.string(forKey: "selectedLanguageCode") ?? "en") ?? Language.all[0]
        
        loadLocalizations()
    }
    
    func setCountry(_ country: Country) {
        currentCountry = country
        selectedCountryCode = country.id
        
        // If current language is not available for the new country, switch to native language
        let availableLanguages = Language.availableFor(country: country)
        if !availableLanguages.contains(where: { $0.id == currentLanguage.id }) {
            if let nativeLang = Language.findByCode(country.nativeLanguageCode) {
                setLanguage(nativeLang)
            }
        }
        
        objectWillChange.send()
    }
    
    func setLanguage(_ language: Language) {
        currentLanguage = language
        selectedLanguageCode = language.id
        objectWillChange.send()
    }
    
    func localized(_ key: String) -> String {
        return localizations[currentLanguage.id]?[key] ?? localizations["en"]?[key] ?? key
    }
    
    private func loadLocalizations() {
        // English
        localizations["en"] = [
            // Tab Bar
            "tab.discovery": "Discovery",
            "tab.clips": "Clips",
            "tab.lists": "Lists",
            "tab.profile": "Profile",
            
            // Discovery
            "discovery.trending": "Trending Now",
            "discovery.popular": "Popular",
            "discovery.topRated": "Top Rated",
            "discovery.upcoming": "Upcoming",
            
            // Lists
            "lists.myLists": "My Lists",
            "lists.watchlist": "Watchlist",
            "lists.seen": "Seen",
            "lists.liked": "Liked",
            "lists.disliked": "Disliked",
            "lists.empty": "No Lists Yet",
            "lists.emptyDescription": "Create your first list to start organizing your favorite content",
            "lists.createList": "Create List",
            "lists.listName": "List Name",
            "lists.description": "Description (Optional)",
            "lists.noItems": "No items yet",
            
            // Profile
            "profile.notifications": "Notifications",
            "profile.streamingServices": "Streaming Services",
            "profile.settings": "Settings",
            "profile.helpSupport": "Help & Support",
            "profile.logout": "Logout",
            "profile.signIn": "Sign In",
            "profile.createAccount": "Create Account",
            "profile.signInToVibeWatch": "Sign in to VibeWatch",
            "profile.signInDescription": "Create lists, save clips, and personalize your experience",
            
            // Settings
            "settings.title": "Settings",
            "settings.country": "Country",
            "settings.language": "Language",
            "settings.selectCountry": "Select Country",
            "settings.selectLanguage": "Select Language",
            
            // Movie Detail
            "movieDetail.save": "Save",
            "movieDetail.seen": "Seen",
            "movieDetail.watchNow": "Watch Now",
            "movieDetail.trailer": "Trailer",
            "movieDetail.information": "Information",
            "movieDetail.rating": "Rating",
            "movieDetail.genres": "Genres",
            "movieDetail.runtime": "Runtime",
            "movieDetail.country": "Country",
            "movieDetail.director": "Director",
            "movieDetail.cast": "Cast",
            "movieDetail.similar": "People who liked this also liked",
            
            // Filters
            "filter.all": "All",
            "filter.movies": "Movies",
            "filter.tvSeries": "TV Series",
            
            // Sort
            "sort.dateAdded": "Date Added",
            "sort.title": "Title",
            "sort.releaseDate": "Release Date",
            "sort.rating": "Rating",
            "sort.sortBy": "Sort By",
            
            // Platforms
            "platforms.title": "Platforms",
            "platforms.streaming": "Streaming",
            "platforms.rent": "Rent",
            "platforms.buy": "Buy",
            
            // Common
            "common.done": "Done",
            "common.cancel": "Cancel",
            "common.save": "Save",
            "common.delete": "Delete",
            "common.edit": "Edit",
            "common.search": "Search",
            "common.year": "Year",
            "common.loading": "Loading...",
            "common.items": "items",
            "common.item": "item",
            "common.or": "OR",
            "common.reply": "Reply",
            "common.uploading": "Uploading...",
            
            // Clips
            "clips.loadingClips": "Loading clips...",
            "clips.noClipsAvailable": "No Clips Available",
            "clips.noClipsDescription": "Check back later for exciting scenes from your favorite movies and shows",
            "clips.comment": "Comment",
            "clips.comments": "Comments",
            "clips.noComments": "No comments yet",
            "clips.beFirstToComment": "Be the first to comment",
            "clips.replyingTo": "Replying to",
            "clips.reply": "Reply",
            "clips.replies": "replies",
            "clips.viewReplies": "View",
            "clips.hideReplies": "Hide",
            "clips.addToList": "Add to List",
            "clips.noListsYet": "No lists yet",
            "clips.createFirstList": "Create your first list to save content",
            "clips.createNewList": "Create New List",
            
            // Discovery
            "discovery.basedOnMood": "Based on Your Mood",
            "discovery.vibeWatch": "VibeWatch",
            
            // Search
            "search.trendingSearches": "Trending Searches",
            "search.noResultsFound": "No results found",
            "search.results": "Results",
            
            // Auth
            "auth.welcomeBack": "Welcome Back",
            "auth.signInContinue": "Sign in to continue your journey",
            "auth.forgotPassword": "Forgot Password?",
            "auth.signIn": "Sign In",
            "auth.dontHaveAccount": "Don't have an account?",
            "auth.signUp": "Sign Up",
            "auth.createAccount": "Create Account",
            "auth.joinVibeWatch": "Join VibeWatch and start discovering",
            "auth.invalidEmail": "Invalid email",
            "auth.invalidPassword": "Invalid password",
            "auth.passwordsDontMatch": "Passwords don't match",
            "auth.alreadyHaveAccount": "Already have an account?",
            
            // Notifications
            "notifications.permissionRequired": "Notification Permission Required",
            "notifications.openSettings": "Open Settings",
            "notifications.enableInSettings": "Please enable notifications in Settings to receive updates about new releases, price changes, and more.",
            "notifications.disableConfirmation": "Disable Notifications?",
            "notifications.disableMessage": "You won't receive notifications about new releases, price changes, and personalized recommendations.",
            "notifications.disableButton": "Disable Notifications",
            
            // Misc
            "misc.somethingWrong": "Something wrong?",
            "misc.letUsKnow": "Let us know",
            "misc.selected": "selected",
            "misc.of": "of",
        ]
        
        // Italian
        localizations["it"] = [
            // Tab Bar
            "tab.discovery": "Scopri",
            "tab.clips": "Clip",
            "tab.lists": "Liste",
            "tab.profile": "Profilo",
            
            // Discovery
            "discovery.popular": "Popolari",
            "discovery.topRated": "Più Votati",
            "discovery.upcoming": "In Arrivo",
            
            // Lists
            "lists.myLists": "Le Mie Liste",
            "lists.watchlist": "Da Vedere",
            "lists.seen": "Visti",
            "lists.liked": "Piaciuti",
            "lists.disliked": "Non Piaciuti",
            "lists.empty": "Nessuna Lista",
            "lists.emptyDescription": "Crea la tua prima lista per iniziare a organizzare i tuoi contenuti preferiti",
            "lists.createList": "Crea Lista",
            "lists.listName": "Nome Lista",
            "lists.description": "Descrizione (Opzionale)",
            "lists.noItems": "Nessun elemento",
            
            // Profile
            "profile.notifications": "Notifiche",
            "profile.streamingServices": "Servizi di Streaming",
            "profile.settings": "Impostazioni",
            "profile.helpSupport": "Aiuto e Supporto",
            "profile.logout": "Esci",
            "profile.signIn": "Accedi",
            "profile.createAccount": "Crea Account",
            "profile.signInToVibeWatch": "Accedi a VibeWatch",
            "profile.signInDescription": "Crea liste, salva clip e personalizza la tua esperienza",
            
            // Settings
            "settings.title": "Impostazioni",
            "settings.country": "Paese",
            "settings.language": "Lingua",
            "settings.selectCountry": "Seleziona Paese",
            "settings.selectLanguage": "Seleziona Lingua",
            
            // Movie Detail
            "movieDetail.save": "Salva",
            "movieDetail.seen": "Visto",
            "movieDetail.watchNow": "Guarda Ora",
            "movieDetail.trailer": "Trailer",
            "movieDetail.information": "Informazioni",
            "movieDetail.rating": "Valutazione",
            "movieDetail.genres": "Generi",
            "movieDetail.runtime": "Durata",
            "movieDetail.country": "Paese",
            "movieDetail.director": "Regista",
            "movieDetail.cast": "Cast",
            "movieDetail.similar": "A chi è piaciuto questo è piaciuto anche",
            
            // Filters
            "filter.all": "Tutti",
            "filter.movies": "Film",
            "filter.tvSeries": "Serie TV",
            
            // Sort
            "sort.dateAdded": "Data Aggiunta",
            "sort.title": "Titolo",
            "sort.releaseDate": "Data di Uscita",
            "sort.rating": "Valutazione",
            "sort.sortBy": "Ordina Per",
            
            // Platforms
            "platforms.title": "Piattaforme",
            "platforms.streaming": "Streaming",
            "platforms.rent": "Noleggio",
            "platforms.buy": "Acquisto",
            
            // Common
            "common.done": "Fatto",
            "common.cancel": "Annulla",
            "common.save": "Salva",
            "common.delete": "Elimina",
            "common.edit": "Modifica",
            "common.search": "Cerca",
            "common.year": "Anno",
            "common.loading": "Caricamento...",
            "common.items": "elementi",
            "common.item": "elemento",
            "common.or": "O",
            "common.reply": "Rispondi",
            "common.uploading": "Caricamento...",
            
            // Clips
            "clips.loadingClips": "Caricamento clip...",
            "clips.noClipsAvailable": "Nessuna Clip Disponibile",
            "clips.noClipsDescription": "Torna più tardi per scene emozionanti dai tuoi film e serie preferiti",
            "clips.comment": "Commento",
            "clips.comments": "Commenti",
            "clips.noComments": "Nessun commento",
            "clips.beFirstToComment": "Sii il primo a commentare",
            "clips.replyingTo": "Risposta a",
            "clips.reply": "Rispondi",
            "clips.replies": "risposte",
            "clips.viewReplies": "Mostra",
            "clips.hideReplies": "Nascondi",
            "clips.addToList": "Aggiungi a Lista",
            "clips.noListsYet": "Nessuna lista",
            "clips.createFirstList": "Crea la tua prima lista per salvare contenuti",
            "clips.createNewList": "Crea Nuova Lista",
            
            // Discovery
            "discovery.vibeWatch": "VibeWatch",

            "discovery.basedOnMood": "In Base al Tuo Umore",
            "discovery.forYou": "Per te",
            "discovery.trending": "Di tendenza",
            "discovery.tvShows": "Serie TV",
            
            // Search
            "search.placeholder": "Cerca film, serie TV...",
            "search.trendingSearches": "Ricerche di Tendenza",
            "search.noResultsFound": "Nessun risultato trovato",
            "search.results": "Risultati",
            
            // Auth
            "auth.welcomeBack": "Bentornato",
            "auth.signInContinue": "Accedi per continuare il tuo viaggio",
            "auth.forgotPassword": "Password Dimenticata?",
            "auth.signIn": "Accedi",
            "auth.dontHaveAccount": "Non hai un account?",
            "auth.signUp": "Registrati",
            "auth.createAccount": "Crea Account",
            "auth.joinVibeWatch": "Unisciti a VibeWatch e inizia a scoprire",
            "auth.invalidEmail": "Email non valida",
            "auth.invalidPassword": "Password non valida",
            "auth.passwordsDontMatch": "Le password non corrispondono",
            "auth.alreadyHaveAccount": "Hai già un account?",
            
            // Notifications
            "notifications.permissionRequired": "Permesso Notifiche Richiesto",
            "notifications.openSettings": "Apri Impostazioni",
            "notifications.enableInSettings": "Abilita le notifiche nelle Impostazioni per ricevere aggiornamenti su nuove uscite, cambi di prezzo e altro.",
            "notifications.disableConfirmation": "Disabilitare le Notifiche?",
            "notifications.disableMessage": "Non riceverai notifiche su nuove uscite, cambi di prezzo e raccomandazioni personalizzate.",
            "notifications.disableButton": "Disabilita Notifiche",
            
            // Misc
            "misc.somethingWrong": "Qualcosa non va?",
            "misc.letUsKnow": "Faccelo sapere",
            "misc.selected": "selezionati",
            "misc.of": "di",
        ]
        
        // Add more languages here (Spanish, French, German, etc.)
        // For now, adding Spanish as an example
        localizations["es"] = [
            "tab.discovery": "Descubrir",
            "tab.clips": "Clips",
            "tab.lists": "Listas",
            "tab.profile": "Perfil",
            "lists.myLists": "Mis Listas",
            "profile.settings": "Configuración",
            "settings.title": "Configuración",
            "settings.country": "País",
            "settings.language": "Idioma",
            "common.done": "Listo",
        ]
    }
}

// Helper extension for easy access to localized strings
extension String {
    var localized: String {
        LocalizationManager.shared.localized(self)
    }
}
