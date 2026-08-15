#!/usr/bin/env python3
"""Build Sources/AtlasCore/Resources/atlas.json from GeoNames + a curated list.

Output schema:
  {"version": 2, "places": [{"n": name, "k": kind, "c": cc, "f": fame, "a": [aliases],
                             "cn": country, "t": continent, "g": language,
                             "y": lat, "x": lon, "w": side}]}

fame is 0-100.  Bot difficulty and "is this famous enough" checks key off it.

Everything after "a" is there so the game can say a sentence about a place the
moment it is played — which country, which language, which corner of that
country — and so the card deck has something to make rules out of.  `w` is the
part of its country a place sits in ("north-west", "centre"), worked out by
placing it inside a box drawn round every GeoNames city of that country; for a
country itself it is the part of the continent instead.

Data: GeoNames (CC BY 4.0) — https://www.geonames.org/
"""

import io
import json
import math
import os
import re
import sys
import unicodedata
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "..", "Sources", "AtlasCore", "Resources", "atlas.json")

# The source files, fetched on demand.  They are 11 MB of tab-separated text
# that this script only ever reads, so they are not worth keeping in the
# repository — but a checkout that cannot rebuild the atlas is a checkout where
# the atlas may as well be a magic constant.
SOURCES = {
    "countryInfo.txt": "https://download.geonames.org/export/dump/countryInfo.txt",
    "cities15000.txt": "https://download.geonames.org/export/dump/cities15000.zip",
}


def source(name):
    """The path to a GeoNames file, downloading it the first time it is asked for."""
    path = os.path.join(DATA, name)
    if os.path.exists(path):
        return path
    url = SOURCES[name]
    os.makedirs(DATA, exist_ok=True)
    sys.stderr.write("fetching %s…\n" % url)
    with urllib.request.urlopen(url) as response:
        payload = response.read()
    if url.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            payload = archive.read(name)
    with open(path, "wb") as fh:
        fh.write(payload)
    return path

# ---------------------------------------------------------------- normalizing


def strip_accents(s):
    # Handle a few letters that NFD does not decompose.
    s = (s.replace("ø", "o").replace("Ø", "O").replace("đ", "d").replace("Đ", "D")
          .replace("ł", "l").replace("Ł", "L").replace("ß", "ss")
          .replace("æ", "ae").replace("Æ", "Ae").replace("œ", "oe").replace("Œ", "Oe")
          .replace("ð", "d").replace("Ð", "D").replace("þ", "th").replace("Þ", "Th"))
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if not unicodedata.combining(c))


def norm(s):
    """Lookup key: accent-free, lowercase, letters+digits only."""
    return re.sub(r"[^a-z0-9]", "", strip_accents(s).lower())


def is_clean_ascii(s):
    return bool(re.fullmatch(r"[A-Za-z][A-Za-z .'’-]*[A-Za-z.]", s))


# ------------------------------------------------------------------ geography

CONTINENT_NAMES = {
    "AF": "Africa", "AS": "Asia", "EU": "Europe", "NA": "North America",
    "SA": "South America", "OC": "Oceania", "AN": "Antarctica",
}

# Every language that turns up first in the GeoNames country table.
LANGUAGE_NAMES = {
    "aa": "Afar", "am": "Amharic", "ar": "Arabic", "az": "Azerbaijani",
    "be": "Belarusian", "bg": "Bulgarian", "bi": "Bislama", "bn": "Bengali",
    "bs": "Bosnian", "ca": "Catalan", "cmn": "Mandarin", "cs": "Czech",
    "cu": "Church Slavonic", "da": "Danish", "de": "German", "dv": "Dhivehi",
    "dz": "Dzongkha", "el": "Greek", "en": "English", "es": "Spanish",
    "et": "Estonian", "fa": "Persian", "fi": "Finnish", "fil": "Filipino",
    "fo": "Faroese", "fr": "French", "he": "Hebrew", "hi": "Hindi",
    "hr": "Croatian", "ht": "Haitian Creole", "hu": "Hungarian",
    "hy": "Armenian", "id": "Indonesian", "is": "Icelandic", "it": "Italian",
    "ja": "Japanese", "ka": "Georgian", "kk": "Kazakh", "kl": "Greenlandic",
    "km": "Khmer", "ko": "Korean", "ky": "Kyrgyz", "la": "Latin",
    "lb": "Luxembourgish", "lo": "Lao", "lt": "Lithuanian", "lv": "Latvian",
    "mh": "Marshallese", "mk": "Macedonian", "mn": "Mongolian", "ms": "Malay",
    "mt": "Maltese", "my": "Burmese", "na": "Nauruan", "ne": "Nepali",
    "niu": "Niuean", "nl": "Dutch", "no": "Norwegian", "ny": "Chichewa",
    "pau": "Palauan", "pl": "Polish", "pt": "Portuguese", "ro": "Romanian",
    "ru": "Russian", "rw": "Kinyarwanda", "si": "Sinhala", "sk": "Slovak",
    "sl": "Slovene", "sm": "Samoan", "so": "Somali", "sq": "Albanian",
    "sr": "Serbian", "sv": "Swedish", "sw": "Swahili", "ta": "Tamil",
    "tet": "Tetum", "tg": "Tajik", "th": "Thai", "tk": "Turkmen",
    "tkl": "Tokelauan", "tl": "Tagalog", "to": "Tongan", "tr": "Turkish",
    "tvl": "Tuvaluan", "uk": "Ukrainian", "ur": "Urdu", "uz": "Uzbek",
    "vi": "Vietnamese", "wls": "Wallisian", "zh": "Chinese", "zu": "Zulu",
}

# GeoNames lists whatever code comes first, which is not always the language a
# player would name.  These are the countries where the honest answer is a pair,
# or where the first code is a minority language of the place.
LANGUAGE_OVERRIDE = {
    "IN": "Hindi and English", "CH": "German, French and Italian",
    "BE": "Dutch and French", "CA": "English and French",
    "ZA": "English and Afrikaans", "SG": "English and Mandarin",
    "PK": "Urdu and English", "PH": "Filipino and English",
    "LK": "Sinhala and Tamil", "IE": "English and Irish",
    "PY": "Spanish and Guarani", "BO": "Spanish and Quechua",
    "PE": "Spanish and Quechua", "AF": "Dari and Pashto",
    "ET": "Amharic", "ER": "Tigrinya", "MA": "Arabic and Berber",
    "DZ": "Arabic and Berber", "IQ": "Arabic and Kurdish",
    "KE": "Swahili and English", "TZ": "Swahili", "NG": "English",
    "IL": "Hebrew and Arabic", "HK": "Cantonese and English",
    "MO": "Cantonese and Portuguese", "TW": "Mandarin", "CN": "Mandarin",
    "BY": "Belarusian and Russian", "FI": "Finnish and Swedish",
    "LU": "Luxembourgish, French and German", "MT": "Maltese and English",
    "PG": "Tok Pisin and English", "VU": "Bislama, English and French",
    "NZ": "English and Maori", "BT": "Dzongkha", "NP": "Nepali",
    "MM": "Burmese", "KZ": "Kazakh and Russian",
    "VA": "Italian and Latin", "AD": "Catalan", "GL": "Greenlandic",
    "PR": "Spanish and English", "BW": "Setswana and English",
    "ZW": "English and Shona", "ZM": "English", "UG": "English and Swahili",
    "RW": "Kinyarwanda, French and English", "CM": "French and English",
    "SD": "Arabic and English", "SS": "English",
}

# The curated features are not in GeoNames, so their geography is written down
# here: (continent, country code).  An empty country means the thing spans more
# than one — the Danube, the Andes, the Atlantic.
FEATURE_PLACE = {
    # rivers
    "Amazon": ("SA", ""), "Nile": ("AF", ""), "Yangtze": ("AS", "CN"),
    "Mississippi": ("NA", "US"), "Danube": ("EU", ""), "Ganges": ("AS", "IN"),
    "Volga": ("EU", "RU"), "Rhine": ("EU", ""), "Seine": ("EU", "FR"),
    "Thames": ("EU", "GB"), "Congo River": ("AF", ""), "Mekong": ("AS", ""),
    "Niger River": ("AF", ""), "Euphrates": ("AS", ""), "Tigris": ("AS", ""),
    "Indus": ("AS", "PK"), "Brahmaputra": ("AS", ""), "Yukon": ("NA", ""),
    "Colorado River": ("NA", "US"), "Rio Grande": ("NA", ""),
    "Zambezi": ("AF", ""), "Orinoco": ("SA", "VE"), "Loire": ("EU", "FR"),
    "Elbe": ("EU", ""), "Tiber": ("EU", "IT"), "Jordan River": ("AS", ""),
    "Yamuna": ("AS", "IN"), "Godavari": ("AS", "IN"), "Irrawaddy": ("AS", "MM"),
    "Ob": ("AS", "RU"), "Lena": ("AS", "RU"), "Yenisei": ("AS", "RU"),
    "Amur": ("AS", ""), "Po": ("EU", "IT"), "Ebro": ("EU", "ES"),
    "Tagus": ("EU", ""), "Douro": ("EU", ""), "Shannon": ("EU", "IE"),
    "Severn": ("EU", "GB"), "Clyde": ("EU", "GB"), "Hudson": ("NA", "US"),
    "Potomac": ("NA", "US"), "Ohio River": ("NA", "US"),
    "Murray": ("OC", "AU"), "Darling": ("OC", "AU"),
    # mountains & ranges
    "Everest": ("AS", ""), "Kilimanjaro": ("AF", "TZ"), "Fuji": ("AS", "JP"),
    "Matterhorn": ("EU", ""), "Denali": ("NA", "US"), "Aconcagua": ("SA", "AR"),
    "Elbrus": ("EU", "RU"), "Vesuvius": ("EU", "IT"), "Etna": ("EU", "IT"),
    "Olympus": ("EU", "GR"), "Kosciuszko": ("OC", "AU"), "Ararat": ("AS", "TR"),
    "Sinai": ("AF", "EG"), "Rushmore": ("NA", "US"), "Himalayas": ("AS", ""),
    "Andes": ("SA", ""), "Alps": ("EU", ""), "Rockies": ("NA", ""),
    "Pyrenees": ("EU", ""), "Urals": ("EU", "RU"), "Carpathians": ("EU", ""),
    "Appalachians": ("NA", "US"), "Atlas Mountains": ("AF", ""),
    "Sierra Nevada": ("NA", "US"), "Caucasus": ("EU", ""), "Balkans": ("EU", ""),
    "Ural": ("EU", "RU"), "Vosges": ("EU", "FR"), "Jura": ("EU", ""),
    "Zagros": ("AS", "IR"), "Hindu Kush": ("AS", ""), "Karakoram": ("AS", ""),
    "Uluru": ("OC", "AU"),
    # deserts
    "Sahara": ("AF", ""), "Gobi": ("AS", ""), "Kalahari": ("AF", ""),
    "Mojave": ("NA", "US"), "Atacama": ("SA", "CL"), "Namib": ("AF", "NA"),
    "Sonoran": ("NA", ""), "Arabian Desert": ("AS", ""), "Thar": ("AS", ""),
    # water
    "Pacific Ocean": ("", ""), "Atlantic Ocean": ("", ""),
    "Indian Ocean": ("", ""), "Arctic Ocean": ("", ""),
    "Mediterranean": ("", ""), "Caribbean": ("NA", ""),
    "Baltic Sea": ("EU", ""), "Black Sea": ("EU", ""), "Red Sea": ("AF", ""),
    "Dead Sea": ("AS", ""), "Caspian Sea": ("AS", ""), "Aegean Sea": ("EU", ""),
    "North Sea": ("EU", ""), "Bering Strait": ("", ""),
    "Persian Gulf": ("AS", ""), "Gulf of Mexico": ("NA", ""),
    "Bay of Bengal": ("AS", ""), "Coral Sea": ("OC", ""),
    "Lake Victoria": ("AF", ""), "Lake Baikal": ("AS", "RU"),
    "Lake Superior": ("NA", ""), "Lake Michigan": ("NA", "US"),
    "Lake Titicaca": ("SA", ""), "Lake Tahoe": ("NA", "US"),
    "Lake Como": ("EU", "IT"), "Loch Ness": ("EU", "GB"),
    "Great Lakes": ("NA", ""), "Lake Geneva": ("EU", ""),
    # islands
    "Greenland": ("NA", "GL"), "Madagascar": ("AF", "MG"), "Borneo": ("AS", ""),
    "Sumatra": ("AS", "ID"), "Java": ("AS", "ID"), "Bali": ("AS", "ID"),
    "Sicily": ("EU", "IT"), "Sardinia": ("EU", "IT"), "Corsica": ("EU", "FR"),
    "Crete": ("EU", "GR"), "Cyprus": ("EU", "CY"), "Tasmania": ("OC", "AU"),
    "Hawaii": ("OC", "US"), "Maui": ("OC", "US"), "Bermuda": ("NA", "BM"),
    "Galapagos": ("SA", "EC"), "Zanzibar": ("AF", "TZ"),
    "Santorini": ("EU", "GR"), "Mykonos": ("EU", "GR"), "Ibiza": ("EU", "ES"),
    "Majorca": ("EU", "ES"), "Tenerife": ("AF", "ES"), "Bora Bora": ("OC", "PF"),
    "Easter Island": ("OC", "CL"), "Falkland Islands": ("SA", "FK"),
    "Svalbard": ("EU", "NO"), "Newfoundland": ("NA", "CA"),
    "Vancouver Island": ("NA", "CA"), "Manhattan": ("NA", "US"),
    "Staten Island": ("NA", "US"), "Long Island": ("NA", "US"),
    "Isle of Man": ("EU", "IM"), "Sri Lanka": ("AS", "LK"),
    # regions
    "Siberia": ("AS", "RU"), "Scandinavia": ("EU", ""), "Tibet": ("AS", "CN"),
    "Bavaria": ("EU", "DE"), "Tuscany": ("EU", "IT"), "Catalonia": ("EU", "ES"),
    "Andalusia": ("EU", "ES"), "Provence": ("EU", "FR"),
    "Normandy": ("EU", "FR"), "Brittany": ("EU", "FR"), "Wales": ("EU", "GB"),
    "Scotland": ("EU", "GB"), "England": ("EU", "GB"),
    "Northern Ireland": ("EU", "GB"), "Bohemia": ("EU", "CZ"),
    "Transylvania": ("EU", "RO"), "Anatolia": ("AS", "TR"),
    "Mesopotamia": ("AS", "IQ"), "Punjab": ("AS", ""), "Kashmir": ("AS", ""),
    "Kerala": ("AS", "IN"), "Goa": ("AS", "IN"), "Rajasthan": ("AS", "IN"),
    "Gujarat": ("AS", "IN"), "Bengal": ("AS", ""), "Assam": ("AS", "IN"),
    "Queensland": ("OC", "AU"), "Ontario": ("NA", "CA"), "Alberta": ("NA", "CA"),
    "Nova Scotia": ("NA", "CA"), "Saskatchewan": ("NA", "CA"),
    "Manitoba": ("NA", "CA"), "New Brunswick": ("NA", "CA"),
    "California": ("NA", "US"), "Texas": ("NA", "US"), "Florida": ("NA", "US"),
    "Alaska": ("NA", "US"), "Nevada": ("NA", "US"), "Arizona": ("NA", "US"),
    "Oregon": ("NA", "US"), "Utah": ("NA", "US"), "Colorado": ("NA", "US"),
    "Montana": ("NA", "US"), "Idaho": ("NA", "US"), "Wyoming": ("NA", "US"),
    "Kansas": ("NA", "US"), "Nebraska": ("NA", "US"), "Iowa": ("NA", "US"),
    "Missouri": ("NA", "US"), "Arkansas": ("NA", "US"),
    "Louisiana": ("NA", "US"), "Alabama": ("NA", "US"),
    "Virginia": ("NA", "US"), "Maryland": ("NA", "US"),
    "Delaware": ("NA", "US"), "Pennsylvania": ("NA", "US"),
    "Ohio": ("NA", "US"), "Michigan": ("NA", "US"), "Indiana": ("NA", "US"),
    "Illinois": ("NA", "US"), "Wisconsin": ("NA", "US"),
    "Minnesota": ("NA", "US"), "Kentucky": ("NA", "US"),
    "Tennessee": ("NA", "US"), "Oklahoma": ("NA", "US"), "Maine": ("NA", "US"),
    "Vermont": ("NA", "US"), "Connecticut": ("NA", "US"),
    "Massachusetts": ("NA", "US"), "New Hampshire": ("NA", "US"),
    "Rhode Island": ("NA", "US"), "West Virginia": ("NA", "US"),
    "South Dakota": ("NA", "US"), "North Dakota": ("NA", "US"),
    "New Mexico": ("NA", "US"), "Amazonia": ("SA", ""), "Sahel": ("AF", ""),
    "Iberia": ("EU", ""), "Patagonia": ("SA", ""),
    "Xanadu": ("AS", "CN"), "Yellowstone": ("NA", "US"),
    "Yosemite": ("NA", "US"), "Zion": ("NA", "US"), "Everglades": ("NA", "US"),
    "Serengeti": ("AF", "TZ"), "Kruger": ("AF", "ZA"), "Outback": ("OC", "AU"),
    "Gibraltar": ("EU", "GI"), "Jutland": ("EU", "DK"),
    "Iceland Region": ("EU", "IS"), "Ozarks": ("NA", "US"),
    "Klondike": ("NA", "CA"),
    # continents
    "Africa": ("AF", ""), "Asia": ("AS", ""), "Europe": ("EU", ""),
    "Antarctica": ("AN", ""), "North America": ("NA", ""),
    "South America": ("SA", ""), "Oceania": ("OC", ""), "Eurasia": ("", ""),
}


# GeoNames files a country under one continent, which leaves Vladivostok in
# Europe and Sinai in Africa.  For the countries that straddle, the longitude
# decides: (threshold, west of it, east of it).
CONTINENT_SPLITS = {
    "RU": (60.0, "EU", "AS"), "KZ": (52.0, "EU", "AS"),
    "TR": (29.0, "EU", "AS"), "EG": (33.5, "AF", "AS"),
    "ID": (130.0, "AS", "OC"),
}


def continent_at(cc, lon, default):
    split = CONTINENT_SPLITS.get(cc)
    if not split or lon is None:
        return default
    threshold, west, east = split
    return west if lon < threshold else east


def side_of(value, span, low_word, high_word):
    """Which third of `span` a value falls in, or None for the middle."""
    lo, hi = span
    if hi - lo < 1e-9:
        return None
    t = (value - lo) / (hi - lo)
    if t < 0.37:
        return low_word
    if t > 0.63:
        return high_word
    return None


def compass(lat, lon, box):
    """A place's corner of its box: "north-west", "south", "centre"…

    A box under a degree and a half across is a city-state or an island; saying
    which end of Singapore something is in helps nobody, so those get nothing.
    """
    if not box:
        return ""
    lat_span, lon_span = box
    if lat_span[1] - lat_span[0] < 1.5 and lon_span[1] - lon_span[0] < 1.5:
        return ""
    ns = side_of(lat, lat_span, "south", "north")
    ew = side_of(lon, lon_span, "west", "east")
    if ns and ew:
        return f"{ns}-{ew}"
    return ns or ew or "centre"


def percentile_box(points):
    """A bounding box with the outliers trimmed off.

    Plain min/max would stretch the United States over Hawaii and Alaska and
    then report Chicago as being in the south-east.
    """
    if len(points) < 3:
        return None
    lats = sorted(p[0] for p in points)
    lons = sorted(p[1] for p in points)

    def band(values):
        lo = values[int(0.02 * (len(values) - 1))]
        hi = values[int(0.98 * (len(values) - 1))]
        return (lo, hi)

    return (band(lats), band(lons))


# ---------------------------------------------------------------- curated data

# Countries whose cities are more likely to be recognised by an English speaker.
# Used only to nudge fame so the "famous" tier is not 90% one country.
COUNTRY_PROMINENCE = {
    "US": 1.00, "GB": 0.98, "FR": 0.95, "IT": 0.94, "ES": 0.93, "DE": 0.93,
    "JP": 0.92, "CA": 0.92, "AU": 0.92, "CN": 0.88, "IN": 0.88, "RU": 0.88,
    "BR": 0.86, "MX": 0.85, "NL": 0.85, "CH": 0.84, "GR": 0.84, "EG": 0.84,
    "TR": 0.83, "ZA": 0.83, "AR": 0.82, "PT": 0.82, "IE": 0.82, "SE": 0.81,
    "NO": 0.81, "DK": 0.81, "AT": 0.81, "BE": 0.81, "PL": 0.79, "TH": 0.79,
    "KR": 0.79, "SG": 0.79, "NZ": 0.79, "IL": 0.78, "AE": 0.78, "CZ": 0.77,
    "HU": 0.76, "FI": 0.76, "MA": 0.75, "KE": 0.75, "NG": 0.75, "VN": 0.75,
    "ID": 0.74, "PH": 0.74, "PK": 0.73, "CU": 0.73, "PE": 0.73, "CL": 0.73,
    "CO": 0.72, "MY": 0.72, "SA": 0.72, "IR": 0.72, "IQ": 0.72, "UA": 0.72,
    "RO": 0.70, "HR": 0.70, "IS": 0.70, "JM": 0.70, "NP": 0.70, "LK": 0.68,
}
DEFAULT_PROMINENCE = 0.60

# English exonyms / historical names / abbreviations.  These are *playable
# surface forms*: the chain uses the letters of whatever the player typed, but
# the place can only be used once under any of its names.
ALIASES = {
    "United States": ["USA", "America", "United States of America", "US"],
    "United Kingdom": ["UK", "Britain", "Great Britain"],
    "United Arab Emirates": ["UAE"],
    "Netherlands": ["Holland", "The Netherlands"],
    "Czechia": ["Czech Republic"],
    "Myanmar": ["Burma"],
    "Côte d'Ivoire": ["Ivory Coast", "Cote d'Ivoire"],
    "Cabo Verde": ["Cape Verde"],
    "Eswatini": ["Swaziland"],
    "Timor-Leste": ["East Timor"],
    "North Macedonia": ["Macedonia"],
    "Türkiye": ["Turkey", "Turkiye"],
    "Congo": ["Republic of the Congo"],
    "DR Congo": ["Democratic Republic of the Congo", "Zaire", "Congo-Kinshasa"],
    "Vatican City": ["Vatican"],
    "Russia": ["Russian Federation"],
    "South Korea": ["Korea", "Republic of Korea"],
    "North Korea": ["DPRK"],
    "Mumbai": ["Bombay"],
    "Kolkata": ["Calcutta"],
    "Chennai": ["Madras"],
    "Bengaluru": ["Bangalore"],
    "Puducherry": ["Pondicherry"],
    "Kochi": ["Cochin"],
    "Thiruvananthapuram": ["Trivandrum"],
    "Varanasi": ["Benares"],
    # GeoNames still files Goa's capital under the Portuguese spelling.
    "Panaji": ["Panjim"],
    "Beijing": ["Peking"],
    "Guangzhou": ["Canton"],
    "Ho Chi Minh City": ["Saigon"],
    "Yangon": ["Rangoon"],
    "Istanbul": ["Constantinople"],
    "Saint Petersburg": ["St Petersburg", "St. Petersburg", "Petersburg", "Leningrad"],
    "Volgograd": ["Stalingrad"],
    "Nizhny Novgorod": ["Gorky"],
    "Almaty": ["Alma-Ata"],
    "Astana": ["Nur-Sultan", "Akmola"],
    "Chisinau": ["Kishinev"],
    "Bratislava": ["Pressburg"],
    "Gdansk": ["Danzig"],
    "Wroclaw": ["Breslau"],
    "Kyiv": ["Kiev"],
    "Odesa": ["Odessa"],
    "Kharkiv": ["Kharkov"],
    "Lviv": ["Lvov", "Lemberg"],
    "Bangkok": ["Krung Thep"],
    "Florence": ["Firenze"],
    "Venice": ["Venezia"],
    "Naples": ["Napoli"],
    "Rome": ["Roma"],
    "Milan": ["Milano"],
    "Turin": ["Torino"],
    "Genoa": ["Genova"],
    "Munich": ["Muenchen", "München"],
    "Cologne": ["Koeln", "Köln"],
    "Nuremberg": ["Nurnberg", "Nürnberg"],
    "Vienna": ["Wien"],
    "Prague": ["Praha"],
    "Warsaw": ["Warszawa"],
    "Copenhagen": ["Kobenhavn", "København"],
    "Gothenburg": ["Goteborg", "Göteborg"],
    "Lisbon": ["Lisboa"],
    "Seville": ["Sevilla"],
    "Zaragoza": ["Saragossa"],
    "The Hague": ["Den Haag", "Hague"],
    "Antwerp": ["Antwerpen"],
    "Bruges": ["Brugge"],
    "Ghent": ["Gent"],
    "Geneva": ["Geneve", "Genève"],
    "Zurich": ["Zürich"],
    "Basel": ["Basle"],
    "Athens": ["Athina"],
    "Thessaloniki": ["Salonica"],
    "Bucharest": ["Bucuresti"],
    "Belgrade": ["Beograd"],
    "Cairo": ["Al Qahirah"],
    "Alexandria": ["Iskandariyah"],
    "Casablanca": ["Dar el Beida"],
    "Marrakesh": ["Marrakech"],
    "Damascus": ["Dimashq"],
    "Aleppo": ["Halab"],
    "Baghdad": ["Bagdad"],
    "Mecca": ["Makkah"],
    "Medina": ["Madinah"],
    "Tehran": ["Teheran"],
    "Jerusalem": ["Yerushalayim"],
    "Tel Aviv": ["Tel Aviv-Yafo"],
    "Tokyo": ["Tokio", "Edo"],
    "Osaka": ["Ōsaka"],
    "Kyoto": ["Kioto"],
    "Seoul": ["Soul"],
    "Busan": ["Pusan"],
    "Taipei": ["Taibei"],
    "Hanoi": ["Ha Noi"],
    "Phnom Penh": ["Phnompenh"],
    "Vientiane": ["Viangchan"],
    "Kathmandu": ["Katmandu"],
    "Colombo": ["Kolamba"],
    "Karachi": [],
    "Nairobi": [],
    "Timbuktu": ["Tombouctou"],
    "New York City": ["New York", "NYC"],
    "Los Angeles": ["LA"],
    "San Francisco": ["Frisco"],
    "Washington, D.C.": ["Washington DC", "Washington", "Washington D.C."],
    "Honolulu": [],
    "Montreal": ["Montréal"],
    "Quebec City": ["Quebec"],
    "Mexico City": ["Ciudad de Mexico", "CDMX"],
    "Sao Paulo": ["São Paulo"],
    "Brasilia": ["Brasília"],
    "Bogota": ["Bogotá"],
    "Asuncion": ["Asunción"],
    "Cancun": ["Cancún"],
    "Reykjavik": ["Reykjavík"],
    "Malmo": ["Malmö"],
    "Tromso": ["Tromsø"],
    "Duesseldorf": ["Dusseldorf", "Düsseldorf"],
    "Wuerzburg": ["Wurzburg", "Würzburg"],

    # Landmarks are far more often said with their title than without it, and
    # the title changes the starting letter, so both forms have to be playable.
    "Everest": ["Mount Everest", "Sagarmatha"],
    "Kilimanjaro": ["Mount Kilimanjaro"],
    "Fuji": ["Mount Fuji", "Fujiyama", "Fujisan"],
    "Vesuvius": ["Mount Vesuvius"],
    "Etna": ["Mount Etna"],
    "Olympus": ["Mount Olympus"],
    "Sinai": ["Mount Sinai"],
    "Ararat": ["Mount Ararat"],
    "Rushmore": ["Mount Rushmore"],
    "Elbrus": ["Mount Elbrus"],
    "Kosciuszko": ["Mount Kosciuszko"],
    "Denali": ["Mount McKinley"],
    "Uluru": ["Ayers Rock"],
    "Aconcagua": ["Mount Aconcagua"],
    "Rockies": ["Rocky Mountains"],
    "Himalayas": ["Himalaya"],
}

# Non-city places: seas, rivers, mountains, deserts, islands, regions, states.
# (name, kind, fame)
FEATURES = [
    # --- rivers
    ("Amazon", "river", 92), ("Nile", "river", 95), ("Yangtze", "river", 88),
    ("Mississippi", "river", 90), ("Danube", "river", 86), ("Ganges", "river", 88),
    ("Volga", "river", 82), ("Rhine", "river", 85), ("Seine", "river", 84),
    ("Thames", "river", 88), ("Congo River", "river", 76), ("Mekong", "river", 82),
    ("Niger River", "river", 74), ("Euphrates", "river", 82), ("Tigris", "river", 82),
    ("Indus", "river", 82), ("Brahmaputra", "river", 76), ("Yukon", "river", 74),
    ("Colorado River", "river", 78), ("Rio Grande", "river", 78),
    ("Zambezi", "river", 74), ("Orinoco", "river", 70), ("Loire", "river", 70),
    ("Elbe", "river", 70), ("Tiber", "river", 74), ("Jordan River", "river", 72),
    ("Yamuna", "river", 70), ("Godavari", "river", 66), ("Irrawaddy", "river", 66),
    ("Ob", "river", 62), ("Lena", "river", 62), ("Yenisei", "river", 62),
    ("Amur", "river", 66), ("Po", "river", 66), ("Ebro", "river", 62),
    ("Tagus", "river", 62), ("Douro", "river", 62), ("Shannon", "river", 66),
    ("Severn", "river", 64), ("Clyde", "river", 64), ("Hudson", "river", 74),
    ("Potomac", "river", 70), ("Ohio River", "river", 70),
    ("Murray", "river", 68), ("Darling", "river", 62),
    # --- mountains & ranges
    ("Everest", "mountain", 96), ("Kilimanjaro", "mountain", 90),
    ("Fuji", "mountain", 88), ("Matterhorn", "mountain", 82),
    ("Denali", "mountain", 76), ("Aconcagua", "mountain", 74),
    ("Elbrus", "mountain", 70), ("Vesuvius", "mountain", 84),
    ("Etna", "mountain", 82), ("Olympus", "mountain", 82),
    ("Kosciuszko", "mountain", 66), ("Ararat", "mountain", 74),
    ("Sinai", "mountain", 78), ("Rushmore", "mountain", 74),
    ("Himalayas", "range", 92), ("Andes", "range", 90), ("Alps", "range", 92),
    ("Rockies", "range", 84), ("Pyrenees", "range", 80), ("Urals", "range", 78),
    ("Carpathians", "range", 70), ("Appalachians", "range", 74),
    ("Atlas Mountains", "range", 76), ("Sierra Nevada", "range", 74),
    ("Caucasus", "range", 76), ("Balkans", "range", 76),
    # --- deserts
    ("Sahara", "desert", 94), ("Gobi", "desert", 86), ("Kalahari", "desert", 82),
    ("Mojave", "desert", 76), ("Atacama", "desert", 76), ("Namib", "desert", 72),
    ("Sonoran", "desert", 68), ("Arabian Desert", "desert", 70),
    ("Thar", "desert", 68), ("Patagonia", "region", 78),
    # --- seas, oceans, lakes, straits
    ("Pacific Ocean", "sea", 94), ("Atlantic Ocean", "sea", 94),
    ("Indian Ocean", "sea", 90), ("Arctic Ocean", "sea", 86),
    ("Mediterranean", "sea", 92), ("Caribbean", "sea", 88),
    ("Baltic Sea", "sea", 80), ("Black Sea", "sea", 84), ("Red Sea", "sea", 86),
    ("Dead Sea", "sea", 88), ("Caspian Sea", "sea", 82), ("Aegean Sea", "sea", 80),
    ("North Sea", "sea", 80), ("Bering Strait", "sea", 76),
    ("Persian Gulf", "sea", 80), ("Gulf of Mexico", "sea", 82),
    ("Bay of Bengal", "sea", 80), ("Coral Sea", "sea", 70),
    ("Lake Victoria", "lake", 82), ("Lake Baikal", "lake", 78),
    ("Lake Superior", "lake", 78), ("Lake Michigan", "lake", 78),
    ("Lake Titicaca", "lake", 76), ("Lake Tahoe", "lake", 72),
    ("Lake Como", "lake", 74), ("Loch Ness", "lake", 82),
    ("Great Lakes", "lake", 78), ("Lake Geneva", "lake", 72),
    # --- islands & archipelagos
    ("Greenland", "island", 90), ("Madagascar", "island", 88),
    ("Borneo", "island", 82), ("Sumatra", "island", 78), ("Java", "island", 82),
    ("Bali", "island", 88), ("Sicily", "island", 86), ("Sardinia", "island", 80),
    ("Corsica", "island", 78), ("Crete", "island", 84), ("Cyprus", "island", 84),
    ("Tasmania", "island", 80), ("Hawaii", "island", 92), ("Maui", "island", 76),
    ("Bermuda", "island", 82), ("Galapagos", "island", 82),
    ("Zanzibar", "island", 78), ("Santorini", "island", 84),
    ("Mykonos", "island", 78), ("Ibiza", "island", 84), ("Majorca", "island", 80),
    ("Tenerife", "island", 78), ("Bora Bora", "island", 78),
    ("Easter Island", "island", 80), ("Falkland Islands", "island", 74),
    ("Svalbard", "island", 70), ("Newfoundland", "island", 74),
    ("Vancouver Island", "island", 72), ("Manhattan", "island", 90),
    ("Staten Island", "island", 72), ("Long Island", "island", 76),
    ("Isle of Man", "island", 74), ("Sri Lanka", "island", 88),
    # --- regions, states, provinces
    ("Siberia", "region", 88), ("Scandinavia", "region", 84),
    ("Tibet", "region", 86), ("Bavaria", "region", 78), ("Tuscany", "region", 84),
    ("Catalonia", "region", 80), ("Andalusia", "region", 78),
    ("Provence", "region", 78), ("Normandy", "region", 82),
    ("Brittany", "region", 74), ("Wales", "region", 88),
    ("Scotland", "region", 92), ("England", "region", 94),
    ("Northern Ireland", "region", 82), ("Bohemia", "region", 72),
    ("Transylvania", "region", 80), ("Anatolia", "region", 72),
    ("Mesopotamia", "region", 78), ("Punjab", "region", 78),
    ("Kashmir", "region", 80), ("Kerala", "region", 76), ("Goa", "region", 82),
    ("Rajasthan", "region", 76), ("Gujarat", "region", 72),
    ("Bengal", "region", 74), ("Assam", "region", 70),
    ("Queensland", "region", 76),
    ("Ontario", "region", 80), ("Alberta", "region", 74),
    ("Nova Scotia", "region", 74), ("Saskatchewan", "region", 72),
    ("Manitoba", "region", 72), ("New Brunswick", "region", 68),
    ("California", "region", 92), ("Texas", "region", 90), ("Florida", "region", 90),
    ("Alaska", "region", 88), ("Nevada", "region", 82), ("Arizona", "region", 84),
    ("Oregon", "region", 80), ("Utah", "region", 80), ("Colorado", "region", 82),
    ("Montana", "region", 78), ("Idaho", "region", 74), ("Wyoming", "region", 76),
    ("Kansas", "region", 78), ("Nebraska", "region", 74), ("Iowa", "region", 74),
    ("Missouri", "region", 76), ("Arkansas", "region", 74),
    ("Louisiana", "region", 80),
    ("Alabama", "region", 80),
    ("Virginia", "region", 80), ("Maryland", "region", 78),
    ("Delaware", "region", 74), ("Pennsylvania", "region", 82),
    ("Ohio", "region", 80), ("Michigan", "region", 80), ("Indiana", "region", 78),
    ("Illinois", "region", 80), ("Wisconsin", "region", 78),
    ("Minnesota", "region", 78), ("Kentucky", "region", 78),
    ("Tennessee", "region", 80), ("Oklahoma", "region", 76),
    ("Maine", "region", 78), ("Vermont", "region", 76),
    ("Connecticut", "region", 76), ("Massachusetts", "region", 82),
    ("New Hampshire", "region", 74), ("Rhode Island", "region", 74),
    ("West Virginia", "region", 72), ("South Dakota", "region", 72),
    ("North Dakota", "region", 72), ("New Mexico", "region", 78),
    ("Amazonia", "region", 76), ("Sahel", "region", 66),
    ("Iberia", "region", 74),
    # --- continents
    ("Africa", "continent", 96), ("Asia", "continent", 96),
    ("Europe", "continent", 96), ("Antarctica", "continent", 94),
    ("North America", "continent", 94), ("South America", "continent", 94),
    ("Oceania", "continent", 82), ("Eurasia", "continent", 76),
    # --- rare-letter helpers (verified real places)
    ("Xanadu", "region", 66), ("Yellowstone", "region", 86),
    ("Yosemite", "region", 84), ("Zion", "region", 76),
    ("Everglades", "region", 78), ("Serengeti", "region", 86),
    ("Kruger", "region", 76), ("Uluru", "mountain", 82),
    ("Outback", "region", 76), ("Gibraltar", "region", 84),
    ("Jutland", "region", 68), ("Iceland Region", "region", 55),
    ("Ozarks", "region", 66), ("Klondike", "region", 68),
    ("Ural", "range", 62), ("Vosges", "range", 58),
    ("Jura", "range", 62), ("Zagros", "range", 64),
    ("Hindu Kush", "range", 72), ("Karakoram", "range", 72),
]

# Famous places that fall outside the top-N city cut but that any player would
# expect to be legal.  (name, kind, cc, fame)
EXTRA_PLACES = [
    ("Venice", "city", "IT", 90), ("Florence", "city", "IT", 88),
    ("Pisa", "city", "IT", 80), ("Verona", "city", "IT", 76),
    ("Bologna", "city", "IT", 76), ("Siena", "city", "IT", 72),
    ("Pompeii", "city", "IT", 82), ("Monaco", "city", "MC", 88),
    ("Geneva", "city", "CH", 86), ("Zurich", "city", "CH", 86),
    ("Basel", "city", "CH", 76), ("Lucerne", "city", "CH", 76),
    ("Bern", "capital", "CH", 82), ("Davos", "city", "CH", 72),
    ("Zermatt", "city", "CH", 70), ("Interlaken", "city", "CH", 68),
    ("Cologne", "city", "DE", 84), ("Nuremberg", "city", "DE", 78),
    ("Heidelberg", "city", "DE", 78), ("Dresden", "city", "DE", 78),
    ("Leipzig", "city", "DE", 74), ("Bonn", "city", "DE", 74),
    ("Salzburg", "city", "AT", 80), ("Innsbruck", "city", "AT", 74),
    ("Antwerp", "city", "BE", 78), ("Bruges", "city", "BE", 80),
    ("Ghent", "city", "BE", 72), ("The Hague", "city", "NL", 82),
    ("Rotterdam", "city", "NL", 80), ("Utrecht", "city", "NL", 74),
    ("Eindhoven", "city", "NL", 70), ("Seville", "city", "ES", 84),
    ("Granada", "city", "ES", 82), ("Cordoba", "city", "ES", 78),
    ("Toledo", "city", "ES", 76), ("Salamanca", "city", "ES", 72),
    ("San Sebastian", "city", "ES", 72), ("Porto", "city", "PT", 82),
    ("Sintra", "city", "PT", 70), ("Nice", "city", "FR", 84),
    ("Cannes", "city", "FR", 82), ("Avignon", "city", "FR", 72),
    ("Versailles", "city", "FR", 80), ("Biarritz", "city", "FR", 70),
    ("Chamonix", "city", "FR", 70), ("Oxford", "city", "GB", 88),
    ("Cambridge", "city", "GB", 86), ("Bath", "city", "GB", 80),
    ("York", "city", "GB", 82), ("Dover", "city", "GB", 78),
    ("Brighton", "city", "GB", 76), ("Canterbury", "city", "GB", 76),
    ("Windsor", "city", "GB", 74), ("Galway", "city", "IE", 74),
    ("Thessaloniki", "city", "GR", 76), ("Delphi", "city", "GR", 74),
    ("Sparta", "city", "GR", 80), ("Olympia", "city", "GR", 76),
    ("Troy", "city", "TR", 80), ("Ephesus", "city", "TR", 74),
    ("Cappadocia", "region", "TR", 78), ("Bodrum", "city", "TR", 70),
    ("Mecca", "city", "SA", 90), ("Medina", "city", "SA", 84),
    ("Petra", "city", "JO", 84), ("Tel Aviv", "city", "IL", 84),
    ("Nazareth", "city", "IL", 78), ("Bethlehem", "city", "PS", 82),
    ("Babylon", "city", "IQ", 82), ("Persepolis", "city", "IR", 74),
    ("Samarkand", "city", "UZ", 78), ("Bukhara", "city", "UZ", 72),
    ("Timbuktu", "city", "ML", 80), ("Luxor", "city", "EG", 80),
    ("Giza", "city", "EG", 84), ("Aswan", "city", "EG", 72),
    ("Fez", "city", "MA", 76), ("Marrakesh", "city", "MA", 84),
    ("Carthage", "city", "TN", 78), ("Zanzibar City", "city", "TZ", 70),
    ("Machu Picchu", "region", "PE", 86), ("Cusco", "city", "PE", 78),
    ("Quebec City", "city", "CA", 80), ("Banff", "city", "CA", 74),
    ("Whistler", "city", "CA", 70), ("Niagara Falls", "region", "CA", 88),
    ("Washington, D.C.", "capital", "US", 92), ("Boston", "city", "US", 88),
    ("Seattle", "city", "US", 86), ("Miami", "city", "US", 88),
    ("Atlanta", "city", "US", 84), ("Denver", "city", "US", 82),
    ("Nashville", "city", "US", 80), ("Orlando", "city", "US", 82),
    ("Portland", "city", "US", 78), ("Anchorage", "city", "US", 74),
    ("Aspen", "city", "US", 72), ("Salem", "city", "US", 72),
    ("Kyoto", "city", "JP", 88), ("Nara", "city", "JP", 74),
    ("Hiroshima", "city", "JP", 86), ("Nagasaki", "city", "JP", 82),
    ("Kobe", "city", "JP", 76), ("Okinawa", "region", "JP", 76),
    ("Macau", "city", "MO", 82), ("Lhasa", "city", "CN", 76),
    ("Agra", "city", "IN", 82), ("Jodhpur", "city", "IN", 74),
    ("Udaipur", "city", "IN", 74), ("Shimla", "city", "IN", 70),
    ("Darjeeling", "city", "IN", 74), ("Mysore", "city", "IN", 74),
    ("Rishikesh", "city", "IN", 70), ("Leh", "city", "IN", 68),
    ("Pokhara", "city", "NP", 72), ("Thimphu", "capital", "BT", 74),
    ("Malmo", "city", "SE", 74), ("Uppsala", "city", "SE", 70),
    ("Tromso", "city", "NO", 70), ("Bergen", "city", "NO", 76),
    ("Trondheim", "city", "NO", 70), ("Odense", "city", "DK", 70),
    ("Tampere", "city", "FI", 68), ("Turku", "city", "FI", 68),
    ("Tallinn", "capital", "EE", 78), ("Riga", "capital", "LV", 78),
    ("Vilnius", "capital", "LT", 78), ("Gdansk", "city", "PL", 76),
    ("Krakow", "city", "PL", 82), ("Dubrovnik", "city", "HR", 82),
    ("Split", "city", "HR", 76), ("Ljubljana", "capital", "SI", 76),
    ("Sarajevo", "capital", "BA", 80), ("Mostar", "city", "BA", 70),
    ("Kotor", "city", "ME", 70), ("Nizhny Novgorod", "city", "RU", 72),
    ("Sochi", "city", "RU", 74), ("Vladivostok", "city", "RU", 76),
    ("Kochi", "city", "IN", 74), ("Queenstown", "city", "NZ", 76),
    ("Rotorua", "city", "NZ", 70), ("Cairns", "city", "AU", 74),
    ("Darwin", "city", "AU", 76), ("Hobart", "city", "AU", 74),
    ("Ushuaia", "city", "AR", 72), ("Valparaiso", "city", "CL", 74),
    ("Havana", "capital", "CU", 88), ("Nassau", "capital", "BS", 78),
    ("Kingston", "capital", "JM", 80), ("Vatican City", "country", "VA", 90),
    ("Wuerzburg", "city", "DE", 66),
    # A seat of government too small for the 15,000-population file: Dispur is
    # a neighbourhood of Guwahati that happens to govern 35 million people.
    ("Dispur", "city", "IN", 55), ("Amaravati", "city", "IN", 55),
]

# Kinds that should never enter the atlas from GeoNames (defensive).  The digits
# matter more than they look: GeoNames lists Paris's arrondissements as separate
# populated places, so without this the book holds "Paris 13 Gobelins" and five
# of its neighbours, and a player could spend six turns playing Paris.
BAD_NAME_RE = re.compile(
    r"\b(unnamed|unknown|arrondissement|sector)\b|[0-9]", re.I)


def tidy_name(name):
    """The name a player would say, plus the spellings they might say instead.

    GeoNames writes a few entries the way a post office does rather than the way
    anyone speaks: bilingual regions get both names round a slash, and a German
    city gets its river in brackets to tell it from its namesake.  Neither is
    typeable on a phone, so the plain name is what the book shows and the full
    form becomes an alias.
    """
    extra = []
    if "/" in name:
        parts = [p.strip() for p in name.split("/") if p.strip()]
        if len(parts) == 2:
            # The half after the slash is the one the wider world uses:
            # "Donostia / San Sebastián", "Gasteiz / Vitoria".
            extra.append(parts[0])
            name = parts[1]
    if "(" in name:
        extra.append(name)
        name = re.sub(r"\s*\([^)]*\)", "", name).strip()
    return name, extra


# ---------------------------------------------------------------- load sources


# The ISO country table carries a few entries that no player would call a
# country, and whichever source names a place first decides how the game
# labels it — so Antarctica was announced as a country on the board.  It is
# added below as a continent instead.
NOT_REALLY_COUNTRIES = {"AQ"}


def load_countries():
    rows = []
    with open(source("countryInfo.txt"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) < 9:
                continue
            iso, name, capital, pop = f[0], f[4], f[5], f[7]
            try:
                pop = int(pop)
            except ValueError:
                pop = 0
            continent = f[8] if len(f) > 8 else ""
            codes = f[15].split(",") if len(f) > 15 and f[15] else []
            first = codes[0].split("-")[0] if codes else ""
            language = LANGUAGE_OVERRIDE.get(iso) or LANGUAGE_NAMES.get(first, "")
            rows.append({"iso": iso, "name": name, "capital": capital, "pop": pop,
                         "continent": continent, "language": language})
    return rows


def load_cities():
    rows = []
    with open(source("cities15000.txt"), encoding="utf-8") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 15:
                continue
            name, ascii_name, cc, fcode = f[1], f[2], f[8], f[7]
            try:
                pop = int(f[14])
                lat, lon = float(f[4]), float(f[5])
            except ValueError:
                continue
            if pop <= 0 or BAD_NAME_RE.search(name):
                continue
            rows.append({"name": name, "ascii": ascii_name, "cc": cc,
                         "fcode": fcode, "pop": pop, "lat": lat, "lon": lon})
    return rows


# ---------------------------------------------------------------- fame scoring


def city_fame(pop, cc, fcode):
    # log-population mapped onto 0..1 (15k -> 0, 40M -> 1)
    lp = (math.log10(max(pop, 15000)) - math.log10(15000)) / (
        math.log10(40_000_000) - math.log10(15000))
    lp = max(0.0, min(1.0, lp))
    prom = COUNTRY_PROMINENCE.get(cc, DEFAULT_PROMINENCE)
    capital_bonus = 0.22 if fcode == "PPLC" else (0.10 if fcode == "PPLA" else 0.0)
    score = 0.62 * lp + 0.30 * prom + capital_bonus
    fame = max(1, min(99, round(score * 100)))
    # A seat of government is known to everyone who lives under it, whatever its
    # population says: Itanagar has 60,000 people and a whole state's paperwork.
    # Without this floor the small ones sit below every fame gate in the game —
    # in the book, but never reachable by a bot or countable by a card.
    if fcode == "PPLC":
        fame = max(fame, 55)
    elif fcode == "PPLA":
        fame = max(fame, 38)
    return fame


# ---------------------------------------------------------------- build


def build(city_limit=3200, per_country=8):
    places = []
    seen_keys = {}   # norm key -> index into places

    def add(name, kind, cc, fame, aliases=(), lat=None, lon=None, continent=""):
        key = norm(name)
        if not key or not key[0].isalpha():
            return None
        if key in seen_keys:
            idx = seen_keys[key]
            if fame > places[idx]["f"]:
                places[idx]["f"] = fame
            return idx
        entry = {"n": name, "k": kind, "c": cc, "f": fame, "a": []}
        if lat is not None:
            entry["y"], entry["x"] = round(lat, 3), round(lon, 3)
        if continent:
            entry["t"] = continent
        places.append(entry)
        idx = len(places) - 1
        seen_keys[key] = idx
        for a in aliases:
            add_alias(idx, a)
        return idx

    def add_alias(idx, alias):
        if not is_clean_ascii(strip_accents(alias)):
            return
        key = norm(alias)
        if not key or key in seen_keys:
            return
        seen_keys[key] = idx
        if alias not in places[idx]["a"]:
            places[idx]["a"].append(alias)

    # 0. geography --------------------------------------------------------
    cities = load_cities()
    countries = load_countries()
    # A box round every GeoNames city of a country is a better outline than any
    # figure we could hard-code, and it is free.
    by_country = {}
    for c in cities:
        by_country.setdefault(c["cc"], []).append((c["lat"], c["lon"]))
    country_boxes = {cc: percentile_box(pts) for cc, pts in by_country.items()}
    country_centres = {
        cc: (sorted(p[0] for p in pts)[len(pts) // 2],
             sorted(p[1] for p in pts)[len(pts) // 2])
        for cc, pts in by_country.items()
    }
    continent_of = {c["iso"]: c["continent"] for c in countries}
    by_continent = {}
    for cc, centre in country_centres.items():
        if continent_of.get(cc):
            by_continent.setdefault(continent_of[cc], []).append(centre)
    continent_boxes = {k: percentile_box(v) for k, v in by_continent.items()}
    # Cities are looked up by name and country so the curated entries below can
    # borrow the coordinates GeoNames already knows.
    city_index = {}
    for c in cities:
        for surface in (c["name"], c["ascii"]):
            city_index.setdefault((norm(surface), c["cc"]), c)

    def coords_for(name, cc):
        row = city_index.get((norm(name), cc))
        return (row["lat"], row["lon"]) if row else (None, None)

    # 1. countries -------------------------------------------------------
    for c in countries:
        if not c["name"] or c["iso"] in NOT_REALLY_COUNTRIES:
            continue
        fame = 99 if c["pop"] > 20_000_000 else (96 if c["pop"] > 2_000_000 else 90)
        centre = country_centres.get(c["iso"], (None, None))
        add(c["name"], "country", c["iso"], fame,
            lat=centre[0], lon=centre[1], continent=c["continent"])

    # 2. curated features ------------------------------------------------
    for name, kind, fame in FEATURES:
        continent, cc = FEATURE_PLACE.get(name, ("", ""))
        lat, lon = coords_for(name, cc) if cc else (None, None)
        add(name, kind, cc, fame, lat=lat, lon=lon, continent=continent)

    # 3. cities ----------------------------------------------------------
    #
    # Three passes, not one.  A pure population ranking is what made the book
    # lopsided: it is a list of the biggest cities on earth, so China, India and
    # the United States eat it and whole regions go missing — Aizawl and Imphal
    # are state capitals of a million-strong states and were nowhere.  So the
    # famous cities are joined by every seat of government on the planet, and
    # then by a floor for each country, which is what makes the atlas uniform
    # across the world rather than merely bigger.
    scored = []
    for c in cities:
        scored.append((city_fame(c["pop"], c["cc"], c["fcode"]), c))
    scored.sort(key=lambda t: (-t[0], -t[1]["pop"], t[1]["name"]))

    chosen = list(scored[:city_limit])
    taken = {id(c) for _, c in chosen}

    # Every national and first-order administrative capital: a state capital is
    # known to everyone in the state, which no population figure captures.
    for fame, c in scored:
        if c["fcode"] in ("PPLC", "PPLA") and id(c) not in taken:
            chosen.append((fame, c))
            taken.add(id(c))

    # …and the largest few of every country, so a small country is not
    # represented by nothing at all.
    per = {}
    for fame, c in scored:
        seen = per.setdefault(c["cc"], 0)
        if seen >= per_country:
            continue
        per[c["cc"]] = seen + 1
        if id(c) not in taken:
            chosen.append((fame, c))
            taken.add(id(c))

    for fame, c in chosen:
        kind = "capital" if c["fcode"] == "PPLC" else "city"
        name, spellings = tidy_name(c["name"])
        idx = add(name, kind, c["cc"], fame, lat=c["lat"], lon=c["lon"],
                  continent=continent_at(c["cc"], c["lon"],
                                         continent_of.get(c["cc"], "")))
        if idx is None:
            continue
        # Names collide across the world — the Basque Vitoria normalizes onto
        # the Brazilian Vitória — and the survivor keeps the entry.  An alias
        # must not then be hung on a city in another country, or the game will
        # cheerfully report that Gasteiz is in Brazil.
        if places[idx]["c"] != c["cc"]:
            continue
        for spelling in spellings:
            add_alias(idx, spelling)
        if c["ascii"] and c["ascii"] != name:
            add_alias(idx, tidy_name(c["ascii"])[0])

    # 4. famous places that missed the population cut --------------------
    for name, kind, cc, fame in EXTRA_PLACES:
        lat, lon = coords_for(name, cc)
        add(name, kind, cc, fame, lat=lat, lon=lon,
            continent=continent_at(cc, lon, continent_of.get(cc, "")))

    # 5. curated aliases -------------------------------------------------
    # Resolve by the canonical name, else by any of its aliases (this is how
    # "Cologne" finds the GeoNames entry "Köln").  When resolved by an alias,
    # the English exonym becomes the display name and the old name an alias.
    unresolved = []
    for canonical, alist in ALIASES.items():
        idx = seen_keys.get(norm(canonical))
        if idx is None:
            for a in alist:
                idx = seen_keys.get(norm(a))
                if idx is not None:
                    break
        if idx is None:
            unresolved.append(canonical)
            continue
        if norm(places[idx]["n"]) != norm(canonical):
            old = places[idx]["n"]
            places[idx]["n"] = canonical
            seen_keys[norm(canonical)] = idx
            if old not in places[idx]["a"]:
                places[idx]["a"].append(old)
        for a in alist:
            add_alias(idx, a)
    if unresolved:
        print("WARNING unresolved alias groups:", unresolved, file=sys.stderr)

    # 6. Saint/St equivalence -------------------------------------------
    for idx, p in enumerate(list(places)):
        for surface in [p["n"]] + list(p["a"]):
            low = strip_accents(surface)
            if re.match(r"^(St\.?|Saint)\s", low, re.I):
                other = re.sub(r"^(St\.?|Saint)\s", "Saint ", low, flags=re.I)
                add_alias(idx, other)
                add_alias(idx, re.sub(r"^Saint\s", "St ", other))

    # 7. the sentence the game says when a place is played ---------------
    country_names = {c["iso"]: c["name"] for c in countries}
    languages = {c["iso"]: c["language"] for c in countries}
    for p in places:
        cc = p["c"]
        if cc and p["k"] != "country" and country_names.get(cc):
            p["cn"] = country_names[cc]
        if languages.get(cc):
            p["g"] = languages[cc]
        if "y" in p:
            # A country is placed within its continent, everything else within
            # its country — "Kenya is in east Africa", "Lyon is in eastern France".
            box = (continent_boxes.get(p.get("t", ""))
                   if p["k"] == "country" else country_boxes.get(cc))
            where = compass(p["y"], p["x"], box)
            if where:
                p["w"] = where
        for field in ("y", "x"):
            if field in p and p[field] is None:
                del p[field]

    return places


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 3200
    places = build(limit)
    places.sort(key=lambda p: (-p["f"], p["n"]))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump({"version": 2, "places": places}, fh,
                  ensure_ascii=False, separators=(",", ":"))
        fh.write("\n")

    # -------- report
    surfaces = 0
    starts, ends = {}, {}
    for p in places:
        for s in [p["n"]] + p["a"]:
            surfaces += 1
            letters = re.sub(r"[^a-z]", "", strip_accents(s).lower())
            if not letters:
                continue
            starts[letters[0]] = starts.get(letters[0], 0) + 1
            ends[letters[-1]] = ends.get(letters[-1], 0) + 1
    print(f"places={len(places)} surfaces={surfaces} -> {os.path.relpath(OUT)}")
    print(f"size={os.path.getsize(OUT)/1024:.0f} KiB")
    have = lambda field: sum(1 for p in places if p.get(field))
    print(f"geography: continent={have('t')} language={have('g')} "
          f"country={have('cn')} coords={have('y')} side={have('w')}")

    # How evenly the book covers the world, which is the thing a bare count
    # hides: 5000 places can still be four countries deep.
    per_country = {}
    for p in places:
        if p["c"]:
            per_country[p["c"]] = per_country.get(p["c"], 0) + 1
    biggest = sorted(per_country.items(), key=lambda kv: -kv[1])[:8]
    print(f"spread: {len(per_country)} countries, "
          + ", ".join(f"{cc} {n}" for cc, n in biggest))
    bands = [(88, "household"), (70, "well known"), (50, "known"),
             (30, "local"), (0, "obscure")]
    counts = []
    for floor, label in bands:
        counts.append(f"{label} {sum(1 for p in places if p['f'] >= floor)}")
    print("fame (cumulative): " + ", ".join(counts))
    print("\nletter  starts  ends   (a place ending in X needs places starting with X)")
    for ch in "abcdefghijklmnopqrstuvwxyz":
        s, e = starts.get(ch, 0), ends.get(ch, 0)
        flag = "  <-- DEAD END" if s == 0 and e > 0 else ("  <-- thin" if 0 < s < 5 and e > 0 else "")
        print(f"  {ch}    {s:6d} {e:6d}{flag}")


if __name__ == "__main__":
    main()
