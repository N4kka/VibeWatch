import Foundation
import SwiftUI

class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @Published var currentCountry: Country
    @Published var currentLanguage: Language
    @Published var localeDidChange: Bool = false // Triggers refresh when locale changes
    
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
        // Initialize with saved values or device defaults
        let savedCountryCode = UserDefaults.standard.string(forKey: "selectedCountryCode")
        let savedLanguageCode = UserDefaults.standard.string(forKey: "selectedLanguageCode")
        
        // If no saved preferences, detect from device locale
        let deviceCountryCode: String
        let deviceLanguageCode: String
        
        if savedCountryCode == nil || savedLanguageCode == nil {
            let locale = Locale.current
            deviceCountryCode = locale.region?.identifier ?? "US"
            deviceLanguageCode = locale.language.languageCode?.identifier ?? "en"
            
            // Save detected preferences
            if savedCountryCode == nil {
                UserDefaults.standard.set(deviceCountryCode, forKey: "selectedCountryCode")
            }
            if savedLanguageCode == nil {
                UserDefaults.standard.set(deviceLanguageCode, forKey: "selectedLanguageCode")
            }
        } else {
            deviceCountryCode = savedCountryCode!
            deviceLanguageCode = savedLanguageCode!
        }
        
        self.currentCountry = Country.findByCode(deviceCountryCode) ?? Country.all[0]
        self.currentLanguage = Language.findByCode(deviceLanguageCode) ?? Language.all[0]
        
        loadLocalizations()
        
        print("🌍 Localization initialized: Country=\(currentCountry.name), Language=\(currentLanguage.name)")
    }
    
    func setCountry(_ country: Country) {
        currentCountry = country
        selectedCountryCode = country.id
        
        // Automatically switch to the native language of the selected country
        if let nativeLang = Language.findByCode(country.nativeLanguageCode) {
            currentLanguage = nativeLang
            selectedLanguageCode = nativeLang.id
            print("🌍 Language automatically changed to native: \(nativeLang.name)")
        }
        
        // Notify that locale changed to trigger content refresh
        localeDidChange.toggle()
        objectWillChange.send()
        
        print("🌍 Country changed to: \(country.name)")
    }
    
    func setLanguage(_ language: Language) {
        currentLanguage = language
        selectedLanguageCode = language.id
        
        // Notify that locale changed to trigger content refresh
        localeDidChange.toggle()
        objectWillChange.send()
        
        print("🌍 Language changed to: \(language.name)")
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
            
            // Onboarding
            "onboarding.page1.title": "Track & Save Your Favorites",
            "onboarding.page1.description": "Discover and save movies and TV series you love. Keep track of what you've watched and what you want to watch next.",
            "onboarding.page2.title": "Organize with Lists",
            "onboarding.page2.description": "Create custom lists to organize your content. From watchlists to mood-based collections, make it yours.",
            "onboarding.page3.title": "Discover Through Clips",
            "onboarding.page3.description": "Watch exciting clips from movies and TV shows. Join the community, comment, save to lists, and share with friends.",
            "onboarding.page4.title": "Ready to Start?",
            "onboarding.page4.description": "Create an account to sync your lists and preferences across all your devices.",
            "onboarding.page4.createAccount": "Create Account",
            "onboarding.page4.skip": "Skip for now",
            
            // Discovery
            "discovery.trending": "Trending Now",
            "discovery.popular": "Popular",
            "discovery.topRated": "Top Rated",
            "discovery.basedOnMood": "Picked Just for You",
            "discovery.vibeWatch": "VibeWatch",
            "discovery.upcoming": "Upcoming",
            "discovery.forYou": "For You",
            "discovery.tvShows": "TV Series",
            
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
            "lists.listNamePlaceholder": "New List",
            "lists.description": "Description (Optional)",
            "lists.descriptionPlaceholder": "Add a description... (Optional)",
            "lists.listDescriptionPlaceholder": "Add a description...",
            "lists.noItems": "No items yet",
            "lists.error.maxListsReached": "Maximum {limit} custom lists reached",
            "lists.error.maxItemsReached": "Maximum {limit} items reached for this list",
            "lists.error.listNotFound": "List not found",
            "lists.error.itemAlreadyInList": "Item already in this list",
            "lists.error.defaultImmutable": "This list can't be modified",
            "lists.error.invalidName": "Please enter a valid list name",
            "lists.error.authRequired": "You need to be signed in to create custom lists.",
            "lists.limitInfo": "{count}/{limit}",
            "lists.softLimitWarning": "\"{name}\" already has {limit} items. Consider starting another list to keep things organized.",
            "lists.searchPlaceholder": "Search this list",
            "lists.editList": "Edit List",
            "list.all": "All",
            "list.movies": "Movies",
            "list.tvShows": "TV",
            
            // Profile
            "profile.done": "Done",
            "profile.cancel": "Cancel",
            "profile.notifications": "Notifications",
            "profile.streamingServices": "Streaming Services",
            "profile.settings": "Settings",
            "profile.helpSupport": "Help & Support",
            "profile.logout": "Logout",
            "profile.signIn": "Sign In",
            "profile.createAccount": "Create Account",
            "profile.signInToVibeWatch": "Sign in to VibeWatch",
            "profile.signInDescription": "Create lists, save clips, and personalize your experience",
            "profile.userNamePlaceholder": "Email or Username",
            "profile.passwordPlaceholder": "Password",
            
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
            "movieDetail.ratings": "ratings",
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
            "sort.popularityDesc": "Popularity ↓",
            "sort.popularityAsc": "Popularity ↑",
            "sort.ratingDesc": "Rating ↓",
            "sort.ratingAsc": "Rating ↑",
            "sort.releaseDateDesc": "Release Date ↓",
            "sort.releaseDateAsc": "Release Date ↑",
            
            // Advanced Filters
            "filters.title": "Filters",
            "filters.reset": "Reset",
            "filters.apply": "Apply",
            "filters.runtime": "Runtime",
            "filters.minimumRating": "Minimum Rating",
            "filters.country": "Country",
            "filters.sortBy": "Sort By",
            "filters.anyCountry": "Any Country",
            "filters.runtimeAny": "Any",
            "filters.runtimeShort": "< 90 min",
            "filters.runtimeMedium": "90-120 min",
            "filters.runtimeLong": "> 120 min",
            "filters.ratingAny": "Any",
            "filters.ratingGood": "7.0+",
            "filters.ratingExcellent": "8.0+",
            "filters.ratingMasterpiece": "9.0+",
            
            // Browse
            "browse.title": "Browse",
            "browse.movies": "Movies",
            "browse.tvShows": "TV Shows",
            "browse.emptyMessage": "Tap the filter button to browse content",
            
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
            "common.loadMore": "Load More",
            
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
            "auth.emailPlaceholder": "Email",
            "auth.usernamePlaceholder": "Username",
            "auth.passwordPlaceholder": "Password",
            "auth.confirmPasswordPlaceholder": "Confirm Password",
            
            // Notifications
            "notifications.permissionRequired": "Notification Permission Required",
            "notifications.openSettings": "Open Settings",
            "notifications.enableInSettings": "Please enable notifications in Settings to receive updates about new releases, price changes, and more.",
            "notifications.disableConfirmation": "Disable Notifications?",
            "notifications.disableMessage": "You won't receive notifications about new releases, price changes, and personalized recommendations.",
            "notifications.disableButton": "Disable Notifications",
            
            // Misc
            "misc.language": "English",
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
            
            // Onboarding
            "onboarding.page1.title": "Traccia e Salva i Tuoi Preferiti",
            "onboarding.page1.description": "Scopri e salva film e serie TV che ami. Tieni traccia di ciò che hai visto e di ciò che vuoi vedere.",
            "onboarding.page2.title": "Organizza con le Liste",
            "onboarding.page2.description": "Crea liste personalizzate per organizzare i tuoi contenuti. Da liste di visione a collezioni basate sull'umore, rendilo tuo.",
            "onboarding.page3.title": "Scopri Attraverso i Clip",
            "onboarding.page3.description": "Guarda clip emozionanti da film e serie TV. Unisciti alla community, commenta, salva nelle liste e condividi con gli amici.",
            "onboarding.page4.title": "Pronto per Iniziare?",
            "onboarding.page4.description": "Crea un account per sincronizzare le tue liste e preferenze su tutti i tuoi dispositivi.",
            "onboarding.page4.createAccount": "Crea Account",
            "onboarding.page4.skip": "Salta per ora",
            
            // Discovery
            "discovery.trending": "Di Tendenza",
            "discovery.popular": "Popolari",
            "discovery.topRated": "Più Votati",
            "discovery.basedOnMood": "Scelti Apposta per Te",
            "discovery.vibeWatch": "VibeWatch",
            "discovery.upcoming": "In Arrivo",
            "discovery.forYou": "Per Te",
            "discovery.tvShows": "Serie TV",
            
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
            "lists.listNamePlaceholder": "Nuova Lista",
            "lists.description": "Descrizione (Opzionale)",
            "lists.descriptionPlaceholder": "Aggiungi una descrizione... (Opzionale)",
            "lists.listDescriptionPlaceholder": "Aggiungi una descrizione...",
            "lists.noItems": "Nessun elemento",
            "lists.error.maxListsReached": "Limite di {limit} liste personalizzate raggiunto",
            "lists.error.maxItemsReached": "Limite di {limit} elementi raggiunto per questa lista",
            "lists.error.listNotFound": "Lista non trovata",
            "lists.error.itemAlreadyInList": "Elemento già presente in questa lista",
            "lists.error.defaultImmutable": "Questa lista non può essere modificata",
            "lists.error.invalidName": "Inserisci un nome valido per la lista",
            "lists.error.authRequired": "Devi aver effettuato l'accesso per creare liste personalizzate.",
            "lists.limitInfo": "{count}/{limit}",
            "lists.softLimitWarning": "La lista \"{name}\" ha già {limit} elementi. Valuta di crearne una nuova per mantenere tutto ordinato.",
            "lists.searchPlaceholder": "Cerca in questa lista",
            "lists.editList": "Modifica Lista",
            "list.all": "Tutti",
            "list.movies": "Film",
            "list.tvShows": "Serie TV",
            
            // Profile
            "profile.done": "Fatto",
            "profile.cancel": "Annulla",
            "profile.notifications": "Notifiche",
            "profile.streamingServices": "Servizi di Streaming",
            "profile.settings": "Impostazioni",
            "profile.helpSupport": "Aiuto e Supporto",
            "profile.logout": "Esci",
            "profile.signIn": "Accedi",
            "profile.createAccount": "Crea Account",
            "profile.signInToVibeWatch": "Accedi a VibeWatch",
            "profile.signInDescription": "Crea liste, salva clip e personalizza la tua esperienza",
            "profile.userNamePlaceholder": "Email o Username",
            "profile.passwordPlaceholder": "Password",
            
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
            "movieDetail.ratings": "valutazioni",
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
            "sort.dateAdded": "Data di Aggiunta",
            "sort.title": "Titolo",
            "sort.releaseDate": "Data di Uscita",
            "sort.rating": "Valutazione",
            "sort.sortBy": "Ordina Per",
            "sort.popularityDesc": "Popolarità ↓",
            "sort.popularityAsc": "Popolarità ↑",
            "sort.ratingDesc": "Valutazione ↓",
            "sort.ratingAsc": "Valutazione ↑",
            "sort.releaseDateDesc": "Data Uscita ↓",
            "sort.releaseDateAsc": "Data Uscita ↑",
            
            // Advanced Filters
            "filters.title": "Filtri",
            "filters.reset": "Resetta",
            "filters.apply": "Applica",
            "filters.runtime": "Durata",
            "filters.minimumRating": "Valutazione Minima",
            "filters.country": "Paese",
            "filters.sortBy": "Ordina Per",
            "filters.anyCountry": "Qualsiasi Paese",
            "filters.runtimeAny": "Qualsiasi",
            "filters.runtimeShort": "< 90 min",
            "filters.runtimeMedium": "90-120 min",
            "filters.runtimeLong": "> 120 min",
            "filters.ratingAny": "Qualsiasi",
            "filters.ratingGood": "7.0+",
            "filters.ratingExcellent": "8.0+",
            "filters.ratingMasterpiece": "9.0+",
            
            // Browse
            "browse.title": "Sfoglia",
            "browse.movies": "Film",
            "browse.tvShows": "Serie TV",
            "browse.emptyMessage": "Tocca il pulsante filtro per sfogliare i contenuti",
            
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
            "common.loadMore": "Carica altro",
            
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
            
            // Search
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
            "auth.emailPlaceholder": "Email",
            "auth.usernamePlaceholder": "Nome utente",
            "auth.passwordPlaceholder": "Password",
            "auth.confirmPasswordPlaceholder": "Conferma Password",
            
            // Notifications
            "notifications.permissionRequired": "Permesso Notifiche Richiesto",
            "notifications.openSettings": "Apri Impostazioni",
            "notifications.enableInSettings": "Abilita le notifiche nelle Impostazioni per ricevere aggiornamenti su nuove uscite, cambi di prezzo e altro.",
            "notifications.disableConfirmation": "Disabilitare le Notifiche?",
            "notifications.disableMessage": "Non riceverai notifiche su nuove uscite, cambi di prezzo e raccomandazioni personalizzate.",
            "notifications.disableButton": "Disabilita Notifiche",
            
            // Misc
            "misc.language": "Italiano",
            "misc.somethingWrong": "Qualcosa non va?",
            "misc.letUsKnow": "Faccelo sapere",
            "misc.selected": "selezionati",
            "misc.of": "di"
        ]
        
        // Spanish (Español)
        localizations["es"] = [
            // Tab Bar
            "tab.discovery": "Descubrir",
            "tab.clips": "Clips",
            "tab.lists": "Listas",
            "tab.profile": "Perfil",
            
            // Onboarding
            "onboarding.page1.title": "Rastrea y Guarda Tus Favoritos",
            "onboarding.page1.description": "Descubre y guarda películas y series de TV que amas. Mantén un registro de lo que has visto y lo que quieres ver a continuación.",
            "onboarding.page2.title": "Organiza con Listas",
            "onboarding.page2.description": "Crea listas personalizadas para organizar tu contenido. Desde listas de reproducción hasta colecciones basadas en el estado de ánimo, hazlo tuyo.",
            "onboarding.page3.title": "Descubre a Través de Clips",
            "onboarding.page3.description": "Mira clips emocionantes de películas y programas de TV. Únete a la comunidad, comenta, guarda en listas y comparte con amigos.",
            "onboarding.page4.title": "¿Listo para Empezar?",
            "onboarding.page4.description": "Crea una cuenta para sincronizar tus listas y preferencias en todos tus dispositivos.",
            "onboarding.page4.createAccount": "Crear Cuenta",
            "onboarding.page4.skip": "Saltar por ahora",
            
            // Discovery
            "discovery.trending": "Tendencias Ahora",
            "discovery.popular": "Populares",
            "discovery.topRated": "Mejor Valoradas",
            "discovery.basedOnMood": "Elegidos Solo para Ti",
            "discovery.vibeWatch": "VibeWatch",
            "discovery.upcoming": "Próximamente",
            "discovery.forYou": "Para Ti",
            "discovery.tvShows": "Series de TV",
            
            // Lists
            "lists.myLists": "Mis Listas",
            "lists.watchlist": "Para Ver",
            "lists.seen": "Vistas",
            "lists.liked": "Me Gusta",
            "lists.disliked": "No Me Gusta",
            "lists.empty": "Sin Listas Aún",
            "lists.emptyDescription": "Crea tu primera lista para organizar tu contenido favorito",
            "lists.createList": "Crear Lista",
            "lists.listName": "Nombre de Lista",
            "lists.listNamePlaceholder": "Nueva Lista",
            "lists.description": "Descripción (Opcional)",
            "lists.descriptionPlaceholder": "Añade una descripción... (Opcional)",
            "lists.listDescriptionPlaceholder": "Añade una descripción...",
            "lists.noItems": "Sin elementos aún",
            "lists.error.maxListsReached": "Límite de {limit} listas personalizadas alcanzado",
            "lists.error.maxItemsReached": "Límite de {limit} elementos alcanzado para esta lista",
            "lists.error.listNotFound": "Lista no encontrada",
            "lists.error.itemAlreadyInList": "Elemento ya está en esta lista",
            "lists.error.defaultImmutable": "Esta lista no se puede modificar",
            "lists.error.invalidName": "Introduce un nombre de lista válido",
            "lists.error.authRequired": "Necesitas iniciar sesión para crear listas personalizadas.",
            "lists.limitInfo": "{count}/{limit}",
            "lists.softLimitWarning": "La lista \"{name}\" ya tiene {limit} elementos. Considera crear otra lista para mantener el orden.",
            "lists.searchPlaceholder": "Busca en esta lista",
            "lists.editList": "Editar lista",
            "list.all": "Todos",
            "list.movies": "Películas",
            "list.tvShows": "Series de TV",
            
            // Profile
            "profile.done": "Hecho",
            "profile.cancel": "Cancelar",
            "profile.notifications": "Notificaciones",
            "profile.streamingServices": "Servicios de Streaming",
            "profile.settings": "Configuración",
            "profile.helpSupport": "Ayuda y Soporte",
            "profile.logout": "Cerrar Sesión",
            "profile.signIn": "Iniciar Sesión",
            "profile.createAccount": "Crear Cuenta",
            "profile.signInToVibeWatch": "Inicia sesión en VibeWatch",
            "profile.signInDescription": "Crea listas, guarda clips y personaliza tu experiencia",
            "profile.userNamePlaceholder": "Email o Usuario",
            "profile.passwordPlaceholder": "Contraseña",
            
            // Settings
            "settings.title": "Configuración",
            "settings.country": "País",
            "settings.language": "Idioma",
            "settings.selectCountry": "Seleccionar País",
            "settings.selectLanguage": "Seleccionar Idioma",
            
            // Movie Detail
            "movieDetail.save": "Guardar",
            "movieDetail.seen": "Vista",
            "movieDetail.watchNow": "Ver Ahora",
            "movieDetail.trailer": "Tráiler",
            "movieDetail.information": "Información",
            "movieDetail.rating": "Valoración",
            "movieDetail.ratings": "valoraciones",
            "movieDetail.genres": "Géneros",
            "movieDetail.runtime": "Duración",
            "movieDetail.country": "País",
            "movieDetail.director": "Director",
            "movieDetail.cast": "Reparto",
            "movieDetail.similar": "A quienes les gustó esto también les gustó",
            
            // Filters
            "filter.all": "Todos",
            "filter.movies": "Películas",
            "filter.tvSeries": "Series de TV",
            
            // Sort
            "sort.dateAdded": "Fecha de Adición",
            "sort.title": "Título",
            "sort.releaseDate": "Fecha de Estreno",
            "sort.rating": "Valoración",
            "sort.sortBy": "Ordenar Por",
            "sort.popularityDesc": "Popularidad ↓",
            "sort.popularityAsc": "Popularidad ↑",
            "sort.ratingDesc": "Valoración ↓",
            "sort.ratingAsc": "Valoración ↑",
            "sort.releaseDateDesc": "Fecha Estreno ↓",
            "sort.releaseDateAsc": "Fecha Estreno ↑",
            
            // Advanced Filters
            "filters.title": "Filtros",
            "filters.reset": "Restablecer",
            "filters.apply": "Aplicar",
            "filters.runtime": "Duración",
            "filters.minimumRating": "Valoración Mínima",
            "filters.country": "País",
            "filters.sortBy": "Ordenar Por",
            "filters.anyCountry": "Cualquier País",
            "filters.runtimeAny": "Cualquiera",
            "filters.runtimeShort": "< 90 min",
            "filters.runtimeMedium": "90-120 min",
            "filters.runtimeLong": "> 120 min",
            "filters.ratingAny": "Cualquiera",
            "filters.ratingGood": "7.0+",
            "filters.ratingExcellent": "8.0+",
            "filters.ratingMasterpiece": "9.0+",
            
            // Browse
            "browse.title": "Explorar",
            "browse.movies": "Películas",
            "browse.tvShows": "Series de TV",
            "browse.emptyMessage": "Toca el botón de filtro para explorar contenido",
            
            // Platforms
            "platforms.title": "Plataformas",
            "platforms.streaming": "Streaming",
            "platforms.rent": "Alquiler",
            "platforms.buy": "Comprar",
            
            // Common
            "common.done": "Listo",
            "common.cancel": "Cancelar",
            "common.save": "Guardar",
            "common.delete": "Eliminar",
            "common.edit": "Editar",
            "common.search": "Buscar",
            "common.year": "Año",
            "common.loading": "Cargando...",
            "common.items": "elementos",
            "common.item": "elemento",
            "common.or": "O",
            "common.reply": "Responder",
            "common.uploading": "Subiendo...",
            "common.loadMore": "Cargar más",
            
            // Clips
            "clips.loadingClips": "Cargando clips...",
            "clips.noClipsAvailable": "No Hay Clips Disponibles",
            "clips.noClipsDescription": "Vuelve más tarde para ver escenas emocionantes de tus películas y series favoritas",
            "clips.comment": "Comentario",
            "clips.comments": "Comentarios",
            "clips.noComments": "Sin comentarios aún",
            "clips.beFirstToComment": "Sé el primero en comentar",
            "clips.replyingTo": "Respondiendo a",
            "clips.reply": "Responder",
            "clips.replies": "respuestas",
            "clips.viewReplies": "Ver",
            "clips.hideReplies": "Ocultar",
            "clips.addToList": "Añadir a Lista",
            "clips.noListsYet": "Sin listas aún",
            "clips.createFirstList": "Crea tu primera lista para guardar contenido",
            "clips.createNewList": "Crear Nueva Lista",
            
            // Search
            "search.trendingSearches": "Búsquedas Populares",
            "search.noResultsFound": "No se encontraron resultados",
            "search.results": "Resultados",
            
            // Auth
            "auth.welcomeBack": "Bienvenido de Nuevo",
            "auth.signInContinue": "Inicia sesión para continuar tu viaje",
            "auth.forgotPassword": "¿Olvidaste tu Contraseña?",
            "auth.signIn": "Iniciar Sesión",
            "auth.dontHaveAccount": "¿No tienes cuenta?",
            "auth.signUp": "Registrarse",
            "auth.createAccount": "Crear Cuenta",
            "auth.joinVibeWatch": "Únete a VibeWatch y empieza a descubrir",
            "auth.invalidEmail": "Email inválido",
            "auth.invalidPassword": "Contraseña inválida",
            "auth.passwordsDontMatch": "Las contraseñas no coinciden",
            "auth.alreadyHaveAccount": "¿Ya tienes cuenta?",
            "auth.emailPlaceholder": "Email",
            "auth.usernamePlaceholder": "Usuario",
            "auth.passwordPlaceholder": "Contraseña",
            "auth.confirmPasswordPlaceholder": "Confirmar Contraseña",
            
            // Notifications
            "notifications.permissionRequired": "Permiso de Notificaciones Requerido",
            "notifications.openSettings": "Abrir Configuración",
            "notifications.enableInSettings": "Habilita las notificaciones en Configuración para recibir actualizaciones sobre nuevos estrenos, cambios de precio y más.",
            "notifications.disableConfirmation": "¿Desactivar Notificaciones?",
            "notifications.disableMessage": "No recibirás notificaciones sobre nuevos estrenos, cambios de precio y recomendaciones personalizadas.",
            "notifications.disableButton": "Desactivar Notificaciones",
            
            // Misc
            "misc.language": "Español",
            "misc.somethingWrong": "¿Algo va mal?",
            "misc.letUsKnow": "Haznos saber",
            "misc.selected": "seleccionados",
            "misc.of": "de",
        ]
        
        // French (Français)
        localizations["fr"] = [
            // Tab Bar
            "tab.discovery": "Découvrir",
            "tab.clips": "Clips",
            "tab.lists": "Listes",
            "tab.profile": "Profil",
            
            // Onboarding
            "onboarding.page1.title": "Suivez et Sauvegardez Vos Favoris",
            "onboarding.page1.description": "Découvrez et sauvegardez les films et séries TV que vous aimez. Gardez une trace de ce que vous avez regardé et de ce que vous voulez regarder ensuite.",
            "onboarding.page2.title": "Organisez avec des Listes",
            "onboarding.page2.description": "Créez des listes personnalisées pour organiser votre contenu. Des listes de lecture aux collections basées sur l'humeur, faites-en le vôtre.",
            "onboarding.page3.title": "Découvrez à Travers les Clips",
            "onboarding.page3.description": "Regardez des clips passionnants de films et d'émissions de télévision. Rejoignez la communauté, commentez, enregistrez dans des listes et partagez avec des amis.",
            "onboarding.page4.title": "Prêt à Commencer?",
            "onboarding.page4.description": "Créez un compte pour synchroniser vos listes et préférences sur tous vos appareils.",
            "onboarding.page4.createAccount": "Créer un Compte",
            "onboarding.page4.skip": "Passer pour l'instant",
            
            // Discovery
            "discovery.trending": "Tendances Actuelles",
            "discovery.popular": "Populaires",
            "discovery.topRated": "Mieux Notés",
            "discovery.basedOnMood": "Choisis Rien Que Pour Vous",
            "discovery.vibeWatch": "VibeWatch",
            "discovery.upcoming": "À Venir",
            "discovery.forYou": "Pour Vous",
            "discovery.tvShows": "Séries TV",
            
            // Lists
            "lists.myLists": "Mes Listes",
            "lists.watchlist": "À Regarder",
            "lists.seen": "Vus",
            "lists.liked": "Aimés",
            "lists.disliked": "Non Aimés",
            "lists.empty": "Aucune Liste Encore",
            "lists.emptyDescription": "Créez votre première liste pour organiser votre contenu préféré",
            "lists.createList": "Créer une Liste",
            "lists.listName": "Nom de la Liste",
            "lists.listNamePlaceholder": "Nouvelle Liste",
            "lists.description": "Description (Optionnel)",
            "lists.descriptionPlaceholder": "Ajouter une description... (Optionnel)",
            "lists.listDescriptionPlaceholder": "Ajouter une description...",
            "lists.noItems": "Aucun élément encore",
            "lists.error.maxListsReached": "Limite de {limit} listes personnalisées atteinte",
            "lists.error.maxItemsReached": "Limite de {limit} éléments atteinte pour cette liste",
            "lists.error.listNotFound": "Liste non trouvée",
            "lists.error.itemAlreadyInList": "L'élément est déjà dans cette liste",
            "lists.error.defaultImmutable": "Cette liste ne peut pas être modifiée",
            "lists.error.invalidName": "Merci d'entrer un nom de liste valide",
            "lists.error.authRequired": "Vous devez être connecté pour créer des listes personnalisées.",
            "lists.limitInfo": "{count}/{limit}",
            "lists.softLimitWarning": "La liste \"{name}\" contient déjà {limit} éléments. Pense à créer une nouvelle liste pour rester organisé.",
            "lists.searchPlaceholder": "Chercher dans cette liste",
            "lists.editList": "Modifier la liste",
            "list.all": "Tous",
            "list.movies": "Films",
            "list.tvShows": "Séries TV",
            
            // Profile
            "profile.done": "Terminé",
            "profile.cancel": "Annuler",
            "profile.notifications": "Notifications",
            "profile.streamingServices": "Services de Streaming",
            "profile.settings": "Paramètres",
            "profile.helpSupport": "Aide et Support",
            "profile.logout": "Déconnexion",
            "profile.signIn": "Se Connecter",
            "profile.createAccount": "Créer un Compte",
            "profile.signInToVibeWatch": "Connectez-vous à VibeWatch",
            "profile.signInDescription": "Créez des listes, enregistrez des clips et personnalisez votre expérience",
            "profile.userNamePlaceholder": "Email ou Nom d'utilisateur",
            "profile.passwordPlaceholder": "Mot de passe",
            
            // Settings
            "settings.title": "Paramètres",
            "settings.country": "Pays",
            "settings.language": "Langue",
            "settings.selectCountry": "Sélectionner un Pays",
            "settings.selectLanguage": "Sélectionner une Langue",
            
            // Movie Detail
            "movieDetail.save": "Enregistrer",
            "movieDetail.seen": "Vu",
            "movieDetail.watchNow": "Regarder Maintenant",
            "movieDetail.trailer": "Bande-annonce",
            "movieDetail.information": "Informations",
            "movieDetail.rating": "Note",
            "movieDetail.ratings": "évaluations",
            "movieDetail.genres": "Genres",
            "movieDetail.runtime": "Durée",
            "movieDetail.country": "Pays",
            "movieDetail.director": "Réalisateur",
            "movieDetail.cast": "Distribution",
            "movieDetail.similar": "Ceux qui ont aimé ceci ont aussi aimé",
            
            // Filters
            "filter.all": "Tous",
            "filter.movies": "Films",
            "filter.tvSeries": "Séries TV",
            
            // Sort
            "sort.dateAdded": "Date d'Ajout",
            "sort.title": "Titre",
            "sort.releaseDate": "Date de Sortie",
            "sort.rating": "Note",
            "sort.sortBy": "Trier Par",
            "sort.popularityDesc": "Popularité ↓",
            "sort.popularityAsc": "Popularité ↑",
            "sort.ratingDesc": "Note ↓",
            "sort.ratingAsc": "Note ↑",
            "sort.releaseDateDesc": "Date Sortie ↓",
            "sort.releaseDateAsc": "Date Sortie ↑",
            
            // Advanced Filters
            "filters.title": "Filtres",
            "filters.reset": "Réinitialiser",
            "filters.apply": "Appliquer",
            "filters.runtime": "Durée",
            "filters.minimumRating": "Note Minimale",
            "filters.country": "Pays",
            "filters.sortBy": "Trier Par",
            "filters.anyCountry": "N'importe quel Pays",
            "filters.runtimeAny": "N'importe",
            "filters.runtimeShort": "< 90 min",
            "filters.runtimeMedium": "90-120 min",
            "filters.runtimeLong": "> 120 min",
            "filters.ratingAny": "N'importe",
            "filters.ratingGood": "7.0+",
            "filters.ratingExcellent": "8.0+",
            "filters.ratingMasterpiece": "9.0+",
            
            // Browse
            "browse.title": "Parcourir",
            "browse.movies": "Films",
            "browse.tvShows": "Séries TV",
            "browse.emptyMessage": "Appuyez sur le bouton de filtre pour parcourir le contenu",
            
            // Platforms
            "platforms.title": "Plateformes",
            "platforms.streaming": "Streaming",
            "platforms.rent": "Location",
            "platforms.buy": "Achat",
            
            // Common
            "common.done": "Terminé",
            "common.cancel": "Annuler",
            "common.save": "Enregistrer",
            "common.delete": "Supprimer",
            "common.edit": "Modifier",
            "common.search": "Rechercher",
            "common.year": "Année",
            "common.loading": "Chargement...",
            "common.items": "éléments",
            "common.item": "élément",
            "common.or": "OU",
            "common.reply": "Répondre",
            "common.uploading": "Téléchargement...",
            "common.loadMore": "Charger plus",
            
            // Clips
            "clips.loadingClips": "Chargement des clips...",
            "clips.noClipsAvailable": "Aucun Clip Disponible",
            "clips.noClipsDescription": "Revenez plus tard pour des scènes passionnantes de vos films et séries préférés",
            "clips.comment": "Commentaire",
            "clips.comments": "Commentaires",
            "clips.noComments": "Aucun commentaire encore",
            "clips.beFirstToComment": "Soyez le premier à commenter",
            "clips.replyingTo": "Répondre à",
            "clips.reply": "Répondre",
            "clips.replies": "réponses",
            "clips.viewReplies": "Voir",
            "clips.hideReplies": "Masquer",
            "clips.addToList": "Ajouter à la Liste",
            "clips.noListsYet": "Aucune liste encore",
            "clips.createFirstList": "Créez votre première liste pour sauvegarder du contenu",
            "clips.createNewList": "Créer une Nouvelle Liste",
            
            // Search
            "search.trendingSearches": "Recherches Populaires",
            "search.noResultsFound": "Aucun résultat trouvé",
            "search.results": "Résultats",
            
            // Auth
            "auth.welcomeBack": "Bon Retour",
            "auth.signInContinue": "Connectez-vous pour continuer votre voyage",
            "auth.forgotPassword": "Mot de Passe Oublié?",
            "auth.signIn": "Se Connecter",
            "auth.dontHaveAccount": "Pas de compte?",
            "auth.signUp": "S'Inscrire",
            "auth.createAccount": "Créer un Compte",
            "auth.joinVibeWatch": "Rejoignez VibeWatch et commencez à découvrir",
            "auth.invalidEmail": "Email invalide",
            "auth.invalidPassword": "Mot de passe invalide",
            "auth.passwordsDontMatch": "Les mots de passe ne correspondent pas",
            "auth.alreadyHaveAccount": "Vous avez déjà un compte?",
            "auth.emailPlaceholder": "Email",
            "auth.usernamePlaceholder": "Nom d'utilisateur",
            "auth.passwordPlaceholder": "Mot de passe",
            "auth.confirmPasswordPlaceholder": "Confirmer le Mot de Passe",
            
            // Notifications
            "notifications.permissionRequired": "Permission de Notification Requise",
            "notifications.openSettings": "Ouvrir les Paramètres",
            "notifications.enableInSettings": "Veuillez activer les notifications dans Paramètres pour recevoir des mises à jour sur les nouvelles sorties, changements de prix et plus.",
            "notifications.disableConfirmation": "Désactiver les Notifications?",
            "notifications.disableMessage": "Vous ne recevrez pas de notifications sur les nouvelles sorties, changements de prix et recommandations personnalisées.",
            "notifications.disableButton": "Désactiver les Notifications",
            
            // Misc
            "misc.language": "Français",
            "misc.somethingWrong": "Un problème?",
            "misc.letUsKnow": "Faites-nous savoir",
            "misc.selected": "sélectionnés",
            "misc.of": "de",
        ]
        
        // German (Deutsch)
        localizations["de"] = [
            // Tab Bar
            "tab.discovery": "Entdecken",
            "tab.clips": "Clips",
            "tab.lists": "Listen",
            "tab.profile": "Profil",
            
            // Onboarding
            "onboarding.page1.title": "Verfolgen & Speichern Sie Ihre Favoriten",
            "onboarding.page1.description": "Entdecken und speichern Sie Filme und TV-Serien, die Sie lieben. Behalten Sie den Überblick darüber, was Sie gesehen haben und was Sie als Nächstes sehen möchten.",
            "onboarding.page2.title": "Organisieren mit Listen",
            "onboarding.page2.description": "Erstellen Sie benutzerdefinierte Listen, um Ihre Inhalte zu organisieren. Von Watchlists bis hin zu stimmungsbasierten Sammlungen, machen Sie es zu Ihrem.",
            "onboarding.page3.title": "Entdecken Sie durch Clips",
            "onboarding.page3.description": "Sehen Sie aufregende Clips aus Filmen und TV-Sendungen. Treten Sie der Community bei, kommentieren Sie, speichern Sie in Listen und teilen Sie mit Freunden.",
            "onboarding.page4.title": "Bereit zu Starten?",
            "onboarding.page4.description": "Erstellen Sie ein Konto, um Ihre Listen und Einstellungen auf allen Ihren Geräten zu synchronisieren.",
            "onboarding.page4.createAccount": "Konto Erstellen",
            "onboarding.page4.skip": "Vorerst Überspringen",
            
            // Discovery
            "discovery.trending": "Aktuell im Trend",
            "discovery.popular": "Beliebt",
            "discovery.topRated": "Bestbewertet",
            "discovery.basedOnMood": "Nur für Dich Ausgewählt",
            "discovery.vibeWatch": "VibeWatch",
            "discovery.upcoming": "Demnächst",
            "discovery.forYou": "Für Sie",
            "discovery.tvShows": "Serien",
            
            // Lists
            "lists.myLists": "Meine Listen",
            "lists.watchlist": "Watchlist",
            "lists.seen": "Gesehen",
            "lists.liked": "Gefällt mir",
            "lists.disliked": "Gefällt mir nicht",
            "lists.empty": "Noch Keine Listen",
            "lists.emptyDescription": "Erstellen Sie Ihre erste Liste, um Ihre Lieblingsinhalte zu organisieren",
            "lists.createList": "Liste Erstellen",
            "lists.listName": "Listenname",
            "lists.listNamePlaceholder": "Neue Liste",
            "lists.description": "Beschreibung (Optional)",
            "lists.descriptionPlaceholder": "Beschreibung hinzufügen... (Optional)",
            "lists.listDescriptionPlaceholder": "Beschreibung hinzufügen...",
            "lists.noItems": "Noch keine Elemente",
            "lists.error.maxListsReached": "Maximum von {limit} benutzerdefinierten Listen erreicht",
            "lists.error.maxItemsReached": "Maximum von {limit} Elementen für diese Liste erreicht",
            "lists.error.listNotFound": "Liste nicht gefunden",
            "lists.error.itemAlreadyInList": "Element bereits in dieser Liste",
            "lists.error.defaultImmutable": "Diese Liste kann nicht geändert werden",
            "lists.error.invalidName": "Bitte gib einen gültigen Listennamen ein",
            "lists.error.authRequired": "Du musst angemeldet sein, um benutzerdefinierte Listen zu erstellen.",
            "lists.limitInfo": "{count}/{limit}",
            "lists.softLimitWarning": "Die Liste \"{name}\" enthält bereits {limit} Elemente. Erstelle am besten eine neue Liste, um den Überblick zu behalten.",
            "lists.searchPlaceholder": "Liste durchsuchen",
            "lists.editList": "Liste bearbeiten",
            "list.all": "Alle",
            "list.movies": "Filme",
            "list.tvShows": "Serien",
            
            // Profile
            "profile.done": "Fertig",
            "profile.cancel": "Abbrechen",
            "profile.notifications": "Benachrichtigungen",
            "profile.streamingServices": "Streaming-Dienste",
            "profile.settings": "Einstellungen",
            "profile.helpSupport": "Hilfe & Support",
            "profile.logout": "Abmelden",
            "profile.signIn": "Anmelden",
            "profile.createAccount": "Konto Erstellen",
            "profile.signInToVibeWatch": "Bei VibeWatch anmelden",
            "profile.signInDescription": "Listen erstellen, Clips speichern und Ihr Erlebnis personalisieren",
            "profile.userNamePlaceholder": "E-Mail oder Benutzername",
            "profile.passwordPlaceholder": "Passwort",
            
            // Settings
            "settings.title": "Einstellungen",
            "settings.country": "Land",
            "settings.language": "Sprache",
            "settings.selectCountry": "Land Wählen",
            "settings.selectLanguage": "Sprache Wählen",
            
            // Movie Detail
            "movieDetail.save": "Speichern",
            "movieDetail.seen": "Gesehen",
            "movieDetail.watchNow": "Jetzt Ansehen",
            "movieDetail.trailer": "Trailer",
            "movieDetail.information": "Informationen",
            "movieDetail.rating": "Bewertung",
            "movieDetail.ratings": "Bewertungen",
            "movieDetail.genres": "Genres",
            "movieDetail.runtime": "Laufzeit",
            "movieDetail.country": "Land",
            "movieDetail.director": "Regisseur",
            "movieDetail.cast": "Besetzung",
            "movieDetail.similar": "Wer dies mochte, mochte auch",
            
            // Filters
            "filter.all": "Alle",
            "filter.movies": "Filme",
            "filter.tvSeries": "Serien",
            
            // Sort
            "sort.dateAdded": "Hinzugefügt",
            "sort.title": "Titel",
            "sort.releaseDate": "Veröffentlichungsdatum",
            "sort.rating": "Bewertung",
            "sort.sortBy": "Sortieren Nach",
            "sort.popularityDesc": "Beliebtheit ↓",
            "sort.popularityAsc": "Beliebtheit ↑",
            "sort.ratingDesc": "Bewertung ↓",
            "sort.ratingAsc": "Bewertung ↑",
            "sort.releaseDateDesc": "Veröffentlichung ↓",
            "sort.releaseDateAsc": "Veröffentlichung ↑",
            
            // Advanced Filters
            "filters.title": "Filter",
            "filters.reset": "Zurücksetzen",
            "filters.apply": "Anwenden",
            "filters.runtime": "Laufzeit",
            "filters.minimumRating": "Mindestbewertung",
            "filters.country": "Land",
            "filters.sortBy": "Sortieren Nach",
            "filters.anyCountry": "Beliebiges Land",
            "filters.runtimeAny": "Beliebig",
            "filters.runtimeShort": "< 90 min",
            "filters.runtimeMedium": "90-120 min",
            "filters.runtimeLong": "> 120 min",
            "filters.ratingAny": "Beliebig",
            "filters.ratingGood": "7.0+",
            "filters.ratingExcellent": "8.0+",
            "filters.ratingMasterpiece": "9.0+",
            
            // Browse
            "browse.title": "Durchsuchen",
            "browse.movies": "Filme",
            "browse.tvShows": "Serien",
            "browse.emptyMessage": "Tippen Sie auf die Filtertaste, um Inhalte zu durchsuchen",
            
            // Platforms
            "platforms.title": "Plattformen",
            "platforms.streaming": "Streaming",
            "platforms.rent": "Ausleihen",
            "platforms.buy": "Kaufen",
            
            // Common
            "common.done": "Fertig",
            "common.cancel": "Abbrechen",
            "common.save": "Speichern",
            "common.delete": "Löschen",
            "common.edit": "Bearbeiten",
            "common.search": "Suchen",
            "common.year": "Jahr",
            "common.loading": "Laden...",
            "common.items": "Elemente",
            "common.item": "Element",
            "common.or": "ODER",
            "common.reply": "Antworten",
            "common.uploading": "Hochladen...",
            "common.loadMore": "Mehr laden",
            
            // Clips
            "clips.loadingClips": "Clips werden geladen...",
            "clips.noClipsAvailable": "Keine Clips Verfügbar",
            "clips.noClipsDescription": "Schauen Sie später vorbei für spannende Szenen aus Ihren Lieblingsfilmen und -serien",
            "clips.comment": "Kommentar",
            "clips.comments": "Kommentare",
            "clips.noComments": "Noch keine Kommentare",
            "clips.beFirstToComment": "Sei der Erste, der kommentiert",
            "clips.replyingTo": "Antworten an",
            "clips.reply": "Antworten",
            "clips.replies": "Antworten",
            "clips.viewReplies": "Anzeigen",
            "clips.hideReplies": "Verbergen",
            "clips.addToList": "Zur Liste Hinzufügen",
            "clips.noListsYet": "Noch keine Listen",
            "clips.createFirstList": "Erstellen Sie Ihre erste Liste, um Inhalte zu speichern",
            "clips.createNewList": "Neue Liste Erstellen",
            
            // Search
            "search.trendingSearches": "Beliebte Suchen",
            "search.noResultsFound": "Keine Ergebnisse gefunden",
            "search.results": "Ergebnisse",
            
            // Auth
            "auth.welcomeBack": "Willkommen Zurück",
            "auth.signInContinue": "Melden Sie sich an, um fortzufahren",
            "auth.forgotPassword": "Passwort Vergessen?",
            "auth.signIn": "Anmelden",
            "auth.dontHaveAccount": "Kein Konto?",
            "auth.signUp": "Registrieren",
            "auth.createAccount": "Konto Erstellen",
            "auth.joinVibeWatch": "Treten Sie VibeWatch bei und beginnen Sie zu entdecken",
            "auth.invalidEmail": "Ungültige E-Mail",
            "auth.invalidPassword": "Ungültiges Passwort",
            "auth.passwordsDontMatch": "Passwörter stimmen nicht überein",
            "auth.alreadyHaveAccount": "Schon ein Konto?",
            "auth.emailPlaceholder": "E-Mail",
            "auth.usernamePlaceholder": "Benutzername",
            "auth.passwordPlaceholder": "Passwort",
            "auth.confirmPasswordPlaceholder": "Passwort Bestätigen",
            
            // Notifications
            "notifications.permissionRequired": "Benachrichtigungserlaubnis Erforderlich",
            "notifications.openSettings": "Einstellungen Öffnen",
            "notifications.enableInSettings": "Bitte aktivieren Sie Benachrichtigungen in den Einstellungen, um Updates über neue Veröffentlichungen, Preisänderungen und mehr zu erhalten.",
            "notifications.disableConfirmation": "Benachrichtigungen Deaktivieren?",
            "notifications.disableMessage": "Sie erhalten keine Benachrichtigungen mehr über neue Veröffentlichungen, Preisänderungen und personalisierte Empfehlungen.",
            "notifications.disableButton": "Benachrichtigungen Deaktivieren",
            
            // Misc
            "misc.language": "Deutsch",
            "misc.somethingWrong": "Etwas stimmt nicht?",
            "misc.letUsKnow": "Sagen Sie uns Bescheid",
            "misc.selected": "ausgewählt",
            "misc.of": "von",
        ]
        
        // Portuguese (Português)
        localizations["pt"] = [
            // Tab Bar
            "tab.discovery": "Descobrir",
            "tab.clips": "Clips",
            "tab.lists": "Listas",
            "tab.profile": "Perfil",
            
            // Onboarding
            "onboarding.page1.title": "Rastreie e Salve Seus Favoritos",
            "onboarding.page1.description": "Descubra e salve filmes e séries de TV que você ama. Acompanhe o que você assistiu e o que deseja assistir a seguir.",
            "onboarding.page2.title": "Organize com Listas",
            "onboarding.page2.description": "Crie listas personalizadas para organizar seu conteúdo. De listas de observação a coleções baseadas em humor, faça do seu jeito.",
            "onboarding.page3.title": "Descubra Através de Clips",
            "onboarding.page3.description": "Assista a clips emocionantes de filmes e programas de TV. Junte-se à comunidade, comente, salve em listas e compartilhe com amigos.",
            "onboarding.page4.title": "Pronto para Começar?",
            "onboarding.page4.description": "Crie uma conta para sincronizar suas listas e preferências em todos os seus dispositivos.",
            "onboarding.page4.createAccount": "Criar Conta",
            "onboarding.page4.skip": "Pular por enquanto",
            
            // Discovery
            "discovery.trending": "Em Alta Agora",
            "discovery.popular": "Populares",
            "discovery.topRated": "Mais Bem Avaliados",
            "discovery.basedOnMood": "Escolhidos Especialmente para Você",
            "discovery.vibeWatch": "VibeWatch",
            "discovery.upcoming": "Em Breve",
            "discovery.forYou": "Para Você",
            "discovery.tvShows": "Séries de TV",
            
            // Lists
            "lists.myLists": "Minhas Listas",
            "lists.watchlist": "Para Assistir",
            "lists.seen": "Vistos",
            "lists.liked": "Gostei",
            "lists.disliked": "Não Gostei",
            "lists.empty": "Ainda Sem Listas",
            "lists.emptyDescription": "Crie sua primeira lista para organizar seu conteúdo favorito",
            "lists.createList": "Criar Lista",
            "lists.listName": "Nome da Lista",
            "lists.listNamePlaceholder": "Nova Lista",
            "lists.description": "Descrição (Opcional)",
            "lists.descriptionPlaceholder": "Adicionar uma descrição... (Opcional)",
            "lists.listDescriptionPlaceholder": "Adicionar uma descrição...",
            "lists.noItems": "Ainda sem itens",
            "lists.error.maxListsReached": "Limite de {limit} listas personalizadas atingido",
            "lists.error.maxItemsReached": "Limite de {limit} itens atingido para esta lista",
            "lists.error.listNotFound": "Lista não encontrada",
            "lists.error.itemAlreadyInList": "Item já está nesta lista",
            "lists.error.defaultImmutable": "Esta lista não pode ser modificada",
            "lists.error.invalidName": "Digite um nome de lista válido",
            "lists.error.authRequired": "Você precisa estar logado para criar listas personalizadas.",
            "lists.limitInfo": "{count}/{limit}",
            "lists.softLimitWarning": "A lista \"{name}\" já tem {limit} itens. Considere criar outra lista para manter tudo organizado.",
            "lists.searchPlaceholder": "Pesquisar nesta lista",
            "lists.editList": "Editar lista",
            "list.all": "Todos",
            "list.movies": "Filmes",
            "list.tvShows": "Séries de TV",
            
            // Profile
            "profile.done": "Concluído",
            "profile.cancel": "Cancelar",
            "profile.notifications": "Notificações",
            "profile.streamingServices": "Serviços de Streaming",
            "profile.settings": "Configurações",
            "profile.helpSupport": "Ajuda e Suporte",
            "profile.logout": "Sair",
            "profile.signIn": "Entrar",
            "profile.createAccount": "Criar Conta",
            "profile.signInToVibeWatch": "Entre no VibeWatch",
            "profile.signInDescription": "Crie listas, salve clips e personalize sua experiência",
            "profile.userNamePlaceholder": "Email ou Nome de usuário",
            "profile.passwordPlaceholder": "Senha",
            
            // Settings
            "settings.title": "Configurações",
            "settings.country": "País",
            "settings.language": "Idioma",
            "settings.selectCountry": "Selecionar País",
            "settings.selectLanguage": "Selecionar Idioma",
            
            // Movie Detail
            "movieDetail.save": "Salvar",
            "movieDetail.seen": "Visto",
            "movieDetail.watchNow": "Assistir Agora",
            "movieDetail.trailer": "Trailer",
            "movieDetail.information": "Informações",
            "movieDetail.rating": "Avaliação",
            "movieDetail.ratings": "avaliações",
            "movieDetail.genres": "Gêneros",
            "movieDetail.runtime": "Duração",
            "movieDetail.country": "País",
            "movieDetail.director": "Diretor",
            "movieDetail.cast": "Elenco",
            "movieDetail.similar": "Quem gostou disto também gostou",
            
            // Filters
            "filter.all": "Todos",
            "filter.movies": "Filmes",
            "filter.tvSeries": "Séries de TV",
            
            // Sort
            "sort.dateAdded": "Data de Adição",
            "sort.title": "Título",
            "sort.releaseDate": "Data de Lançamento",
            "sort.rating": "Avaliação",
            "sort.sortBy": "Ordenar Por",
            "sort.popularityDesc": "Popularidade ↓",
            "sort.popularityAsc": "Popularidade ↑",
            "sort.ratingDesc": "Avaliação ↓",
            "sort.ratingAsc": "Avaliação ↑",
            "sort.releaseDateDesc": "Data Lançamento ↓",
            "sort.releaseDateAsc": "Data Lançamento ↑",
            
            // Advanced Filters
            "filters.title": "Filtros",
            "filters.reset": "Redefinir",
            "filters.apply": "Aplicar",
            "filters.runtime": "Duração",
            "filters.minimumRating": "Avaliação Mínima",
            "filters.country": "País",
            "filters.sortBy": "Ordenar Por",
            "filters.anyCountry": "Qualquer País",
            "filters.runtimeAny": "Qualquer",
            "filters.runtimeShort": "< 90 min",
            "filters.runtimeMedium": "90-120 min",
            "filters.runtimeLong": "> 120 min",
            "filters.ratingAny": "Qualquer",
            "filters.ratingGood": "7.0+",
            "filters.ratingExcellent": "8.0+",
            "filters.ratingMasterpiece": "9.0+",
            
            // Browse
            "browse.title": "Navegar",
            "browse.movies": "Filmes",
            "browse.tvShows": "Séries de TV",
            "browse.emptyMessage": "Toque no botão de filtro para navegar pelo conteúdo",
            
            // Platforms
            "platforms.title": "Plataformas",
            "platforms.streaming": "Streaming",
            "platforms.rent": "Aluguel",
            "platforms.buy": "Comprar",
            
            // Common
            "common.done": "Concluído",
            "common.cancel": "Cancelar",
            "common.save": "Salvar",
            "common.delete": "Excluir",
            "common.edit": "Editar",
            "common.search": "Pesquisar",
            "common.year": "Ano",
            "common.loading": "Carregando...",
            "common.items": "itens",
            "common.item": "item",
            "common.or": "OU",
            "common.reply": "Responder",
            "common.uploading": "Enviando...",
            "common.loadMore": "Carregar mais",
            
            // Clips
            "clips.loadingClips": "Carregando clips...",
            "clips.noClipsAvailable": "Nenhum Clip Disponível",
            "clips.noClipsDescription": "Volte mais tarde para cenas emocionantes dos seus filmes e séries favoritos",
            "clips.comment": "Comentário",
            "clips.comments": "Comentários",
            "clips.noComments": "Ainda sem comentários",
            "clips.beFirstToComment": "Seja o primeiro a comentar",
            "clips.replyingTo": "Respondendo a",
            "clips.reply": "Responder",
            "clips.replies": "respostas",
            "clips.viewReplies": "Ver",
            "clips.hideReplies": "Ocultar",
            "clips.addToList": "Adicionar à Lista",
            "clips.noListsYet": "Ainda sem listas",
            "clips.createFirstList": "Crie sua primeira lista para salvar conteúdo",
            "clips.createNewList": "Criar Nova Lista",
            
            // Search
            "search.trendingSearches": "Pesquisas Populares",
            "search.noResultsFound": "Nenhum resultado encontrado",
            "search.results": "Resultados",
            
            // Auth
            "auth.welcomeBack": "Bem-Vindo de Volta",
            "auth.signInContinue": "Entre para continuar sua jornada",
            "auth.forgotPassword": "Esqueceu a Senha?",
            "auth.signIn": "Entrar",
            "auth.dontHaveAccount": "Não tem conta?",
            "auth.signUp": "Registrar",
            "auth.createAccount": "Criar Conta",
            "auth.joinVibeWatch": "Junte-se ao VibeWatch e comece a descobrir",
            "auth.invalidEmail": "Email inválido",
            "auth.invalidPassword": "Senha inválida",
            "auth.passwordsDontMatch": "As senhas não coincidem",
            "auth.alreadyHaveAccount": "Já tem uma conta?",
            "auth.emailPlaceholder": "Email",
            "auth.usernamePlaceholder": "Nome de usuário",
            "auth.passwordPlaceholder": "Senha",
            "auth.confirmPasswordPlaceholder": "Confirmar Senha",
            
            // Notifications
            "notifications.permissionRequired": "Permissão de Notificação Necessária",
            "notifications.openSettings": "Abrir Configurações",
            "notifications.enableInSettings": "Por favor, ative as notificações nas Configurações para receber atualizações sobre novos lançamentos, mudanças de preço e mais.",
            "notifications.disableConfirmation": "Desativar Notificações?",
            "notifications.disableMessage": "Você não receberá notificações sobre novos lançamentos, mudanças de preço e recomendações personalizadas.",
            "notifications.disableButton": "Desativar Notificações",
            
            // Misc
            "misc.language": "Português",
            "misc.somethingWrong": "Algo errado?",
            "misc.letUsKnow": "Nos avise",
            "misc.selected": "selecionados",
            "misc.of": "de",
        ]
    }
}

// Helper extension for easy access to localized strings
extension String {
    var localized: String {
        LocalizationManager.shared.localized(self)
    }
}
